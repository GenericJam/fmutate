defmodule FMutate.Pairing do
  @moduledoc """
  FMutate's side of pairing (protocol.md §1, built on `mob_pair`): what the Pair screen (`FMutate.PairScreen`)
  shows and what an Allow does.

  ## While the Pair screen is open

  `open/1` starts a `MobPair.Host` (the pairing endpoint) owned by the screen: one secret shown as a QR code
  (the link) and a typed code, single use, 5 minutes, 5 wrong attempts (`MobPair.Host`). It listens on
  loopback (apps on this phone) and on the Wi-Fi address (other phones), never on mobile data, and advertises
  `_fmutate._tcp` over mDNS where it can; when the Wi-Fi address changes it starts again on the new one (a
  new secret). A node name `FMutate.Dist` already knows from the sibling cookie can't be paired
  (`FMutate.Dist.claimed?/1`). A sibling that proves the secret is put to the player: the screen gets
  `{:pairing, {:request, ref, request}}` and answers with `decide/2`. Allow adds the app to
  `MobPair.Pairings` (its own cookie, its client certificate pinned), which `FMutate.Dist` follows: the app
  is allowed at once and connects. The screen closing (or `close/0`) stops pairing.

  Grants (`MobPair.Host` `:loopback_dist`, `:dist_*`):

    * an app on this phone (the pairing connection came from 127.0.0.1): plain distribution to
      `127.0.0.1:9150`, FMutate's node (`FMutate.Dist`), which only listens on loopback;
    * an app on another phone: TLS distribution to this phone's Wi-Fi address on `tls_port/1` (a: #{9250}),
      served by `MobPair.Front` (FMutate's node runs plain distribution, started at runtime, so TLS is a
      front that checks the pinned client certificate and the paired node name, then forwards to the
      loopback listener). Without a Wi-Fi address only apps on this phone can pair (`loopback_only`).

  ## The TLS front

  Runs while FMutate's node is up, a Wi-Fi address exists and at least one pairing uses TLS (protocol §2:
  listen on Wi-Fi only while a remote app is paired), bound to the Wi-Fi address only (never mobile data);
  checked again on every pairing change and every #{div(30_000, 1000)} s, so it follows a new address.

  ## Identity

  FMutate's certificate (ECDSA P-256, self-signed; its SHA-256 is the `fp` in the QR code) and its key are
  made once and kept in `Paths.dist_dir()/pair_cert.json` (0600, app-private storage, like the sibling
  cookie, written with `MobPair.Pairings.write_private/2`); the pairings in `pairings.json` next to it
  (`MobPair.Pairings.FileStore`, 0600). Reinstalling FMutate makes a new certificate, so siblings must pair
  again (protocol §1.4); so does a certificate file that doesn't decode (it is replaced). One that can't be
  read turns pairing off: `open/1` answers `{:error, {:certificate, reason}}`.
  """

  use GenServer

  require Logger

  alias FMutate.{Dist, Firmware, Instance, Paths}

  @service "fmutate"
  @tls_base_port 9250
  @check_ms 30_000
  @getprop "/system/bin/getprop"

  @doc """
  Starts the pairing service. Options: `:instance` (default `"a"`), `:dir` (where the certificate lives,
  default `Paths.dist_dir()`), `:addresses` (a 0-arity function returning `:inet.getifaddrs/0`'s result,
  for tests), `:tls_port`, `:node` (FMutate's node name, default `FMutate.Dist.node_name/1`),
  `:dist_port` (default `FMutate.Dist.port/1`), `:advertise` (mDNS, default true), `:copy_safe` (whether
  the screen may put the secret on the clipboard, default `copy_safe?/0`), `:host_opts` (more
  `MobPair.Host` options, e.g. `ttl:` in tests), `:name`.
  """
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The TLS distribution port of an instance (`\"a\"` → #{@tls_base_port})."
  def tls_port(<<c>>) when c in ?a..?z, do: @tls_base_port + (c - ?a)

  @doc """
  Opens pairing for `owner` (the Pair screen): `{:ok, info}` (see `info/1`) or `{:error, reason}`
  (`{:certificate, reason}` when FMutate's certificate can't be read). An owner that opens again gets the
  same secret; another owner takes it over. `owner` gets `{:pairing, event}`: `{:request, ref, request}`
  (the Allow sheet; `request` is `MobPair.Host`'s), `{:withdrawn, ref}`, `{:secret, status}` (a failed
  attempt, used, too many attempts), `{:paired, pairing}` (without its cookie) after an Allow, and
  `:restarted` (a new Wi-Fi address: a new endpoint and secret; a request being asked about is gone).
  """
  def open(owner \\ self(), server \\ __MODULE__), do: GenServer.call(server, {:open, owner})

  @doc """
  What the screen shows: `%{code, link, local_link, status, attempts_left, expires_in, advertising, host,
  wifi, copy_safe}` (`host` the address in the link, `local_link` the same link to 127.0.0.1 for an app on
  this phone; `wifi` false when only apps on this phone can pair; `copy_safe` false where the clipboard
  isn't private enough to offer Copy, see `copy_safe?/0`), or nil when closed.
  """
  def info(server \\ __MODULE__), do: GenServer.call(server, :info)

  @doc "New code: a fresh secret."
  def renew(server \\ __MODULE__), do: GenServer.call(server, :renew)

  @doc "The player's answer to a `{:request, ref, request}`."
  def decide(ref, decision, server \\ __MODULE__) when decision in [:allow, :deny],
    do: GenServer.call(server, {:decide, ref, decision})

  @doc "Stops pairing (the screen closed)."
  def close(server \\ __MODULE__), do: GenServer.call(server, :close)

  @doc "The port the TLS front listens on, or nil when it isn't running."
  def front_port(server \\ __MODULE__), do: GenServer.call(server, :front_port)

  @doc """
  The address siblings on other phones reach: the first up IPv4 address of a Wi-Fi or Ethernet interface
  (`wlan*`, `en*`, `eth*`), never loopback, link-local or a mobile-data interface. nil when there is none.
  """
  def wifi_address(ifaddrs) do
    candidates =
      for {name, opts} <- ifaddrs,
          name = List.to_string(name),
          lan_interface?(name),
          :up in Keyword.get(opts, :flags, []),
          {a, b, _, _} = ip <- Keyword.get_values(opts, :addr),
          a != 127 and not (a == 169 and b == 254),
          do: {name, ip}

    case Enum.sort_by(candidates, fn {name, _} -> not String.starts_with?(name, "wlan") end) do
      [{_name, ip} | _] -> ip |> :inet.ntoa() |> List.to_string()
      [] -> nil
    end
  end

  defp lan_interface?(name), do: Enum.any?(["wlan", "en", "eth"], &String.starts_with?(name, &1))

  ## Server

  @impl true
  def init(opts) do
    # the endpoint and the front are linked: their exits arrive as messages
    Process.flag(:trap_exit, true)
    instance = Keyword.get(opts, :instance, "a")
    dir = Keyword.get_lazy(opts, :dir, &Paths.dist_dir/0)

    # without a certificate FMutate still runs, with pairing off (open/1 says why)
    {cert, cert_error} =
      case load_cert(Path.join(dir, "pair_cert.json")) do
        {:ok, cert} ->
          {cert, nil}

        {:error, reason} ->
          Logger.error("pairing: no certificate, pairing is off: #{inspect(reason)}")
          {nil, reason}
      end

    if Process.whereis(MobPair.Pairings), do: MobPair.Pairings.subscribe(self())
    Process.send_after(self(), :check_front, 5_000)

    {:ok,
     %{
       instance: instance,
       cert: cert,
       cert_error: cert_error,
       addresses: Keyword.get(opts, :addresses, &getifaddrs/0),
       tls_port: Keyword.get(opts, :tls_port, tls_port(instance)),
       node: Keyword.get(opts, :node, Dist.node_name(instance)),
       dist_port: Keyword.get(opts, :dist_port, Dist.port(instance)),
       advertise: Keyword.get(opts, :advertise, true),
       host_opts: Keyword.get(opts, :host_opts, []),
       copy_safe: Keyword.get_lazy(opts, :copy_safe, &copy_safe?/0),
       owner: nil,
       owner_ref: nil,
       host: nil,
       host_address: nil,
       front: nil,
       front_ip: nil
     }}
  end

  @impl true
  def handle_call({:open, _owner}, _from, %{cert: nil} = state),
    do: {:reply, {:error, {:certificate, state.cert_error}}, state}

  def handle_call({:open, owner}, _from, %{owner: owner, host: host} = state) when host != nil,
    do: {:reply, {:ok, host_info(state)}, state}

  def handle_call({:open, owner}, _from, state) do
    state = state |> stop_host() |> own(owner)

    case start_host(state) do
      {:ok, state} -> {:reply, {:ok, host_info(state)}, state}
      {:error, reason} -> {:reply, {:error, reason}, disown(state)}
    end
  end

  def handle_call(:info, _from, %{host: nil} = state), do: {:reply, nil, state}
  def handle_call(:info, _from, state), do: {:reply, host_info(state), state}

  def handle_call(:renew, _from, %{host: nil} = state), do: {:reply, {:error, :closed}, state}
  def handle_call(:renew, _from, state), do: {:reply, MobPair.Host.renew(state.host), state}

  def handle_call({:decide, _ref, _decision}, _from, %{host: nil} = state),
    do: {:reply, {:error, :closed}, state}

  def handle_call({:decide, ref, decision}, _from, state),
    do: {:reply, MobPair.Host.decide(state.host, ref, decision), state}

  def handle_call(:close, _from, state), do: {:reply, :ok, state |> stop_host() |> disown()}

  def handle_call(:front_port, _from, %{front: nil} = state), do: {:reply, nil, state}
  def handle_call(:front_port, _from, state), do: {:reply, MobPair.Front.port(state.front), state}

  @impl true
  def handle_info({:mob_pair_request, host, ref, request}, %{host: host} = state),
    do: {:noreply, tell(state, {:request, ref, request})}

  def handle_info({:mob_pair_withdrawn, host, ref}, %{host: host} = state),
    do: {:noreply, tell(state, {:withdrawn, ref})}

  def handle_info({:mob_pair_secret, host, status}, %{host: host} = state),
    do: {:noreply, tell(state, {:secret, status})}

  # the screen gets the pairing without its cookie (a secret it has no use for)
  def handle_info({:mob_pair_pairings, :added, pairing}, state),
    do: {:noreply, state |> tell({:paired, Map.delete(pairing, :cookie)}) |> check_front()}

  def handle_info({:mob_pair_pairings, :revoked, _pairing}, state),
    do: {:noreply, check_front(state)}

  def handle_info(:check_front, state) do
    Process.send_after(self(), :check_front, @check_ms)
    {:noreply, state |> check_host() |> check_front()}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:noreply, state |> stop_host() |> disown()}

  def handle_info({:EXIT, pid, reason}, %{host: pid} = state) do
    Logger.warning("pairing: the pairing endpoint stopped: #{inspect(reason)}")
    {:noreply, %{state | host: nil}}
  end

  def handle_info({:EXIT, pid, reason}, %{front: pid} = state) do
    Logger.warning("pairing: the TLS front stopped: #{inspect(reason)}")
    {:noreply, %{state | front: nil, front_ip: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## The pairing endpoint

  # Listens on loopback and the Wi-Fi address (MobPair.Host's default for `host`), never on mobile data
  defp start_host(state) do
    wifi = wifi_address(state.addresses.())
    host = wifi || "127.0.0.1"

    opts = [
      service: @service,
      cert: state.cert,
      inst: state.instance,
      name: "FMutate #{String.upcase(state.instance)}",
      device: device_name(),
      firmware: firmware_name(state.instance),
      node: Atom.to_string(state.node),
      host: host,
      # no Wi-Fi: plain loopback distribution only, so apps on other phones get loopback_only
      dist_host: host,
      dist_port: if(wifi, do: state.tls_port, else: state.dist_port),
      dist_proto: if(wifi, do: :inet_tls, else: :inet_tcp),
      loopback_dist: %{port: state.dist_port, proto: :inet_tcp},
      # a sibling-cookie app's name (FMutate.Dist knows it) can't be taken over by pairing
      reserved: &Dist.claimed?/1,
      approve: {:ask, self()},
      notify: self(),
      advertise: if(wifi && state.advertise, do: [], else: false)
    ]

    case MobPair.Host.start_link(Keyword.merge(opts, state.host_opts)) do
      {:ok, pid} -> {:ok, %{state | host: pid, host_address: host}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The Wi-Fi address changed while the screen is open: pair on the new one (a new secret; the screen
  # redraws the QR code on its next refresh). A request the old endpoint was asking about is gone with it:
  # the owner hears `:restarted`.
  defp check_host(%{host: nil} = state), do: state

  defp check_host(state) do
    if (wifi_address(state.addresses.()) || "127.0.0.1") == state.host_address do
      state
    else
      state |> stop_host() |> restart_host() |> tell(:restarted)
    end
  end

  defp restart_host(state) do
    case start_host(state) do
      {:ok, state} ->
        Logger.info("pairing: the address changed, pairing on #{state.host_address}")
        state

      {:error, reason} ->
        Logger.warning("pairing: the pairing endpoint can't restart: #{inspect(reason)}")
        state
    end
  end

  defp stop_host(%{host: nil} = state), do: state

  defp stop_host(state) do
    Process.unlink(state.host)
    GenServer.stop(state.host, :normal)
    %{state | host: nil, host_address: nil}
  catch
    :exit, _ -> %{state | host: nil, host_address: nil}
  end

  defp host_info(state) do
    state.host
    |> MobPair.Host.info()
    |> Map.merge(%{
      host: state.host_address,
      wifi: state.host_address != "127.0.0.1",
      copy_safe: state.copy_safe
    })
  end

  defp own(state, owner), do: %{state | owner: owner, owner_ref: Process.monitor(owner)}

  defp disown(%{owner_ref: nil} = state), do: state

  defp disown(state) do
    Process.demonitor(state.owner_ref, [:flush])
    %{state | owner: nil, owner_ref: nil}
  end

  defp tell(%{owner: nil} = state, _event), do: state

  defp tell(state, event) do
    send(state.owner, {:pairing, event})
    state
  end

  ## The TLS front

  defp check_front(state) do
    ip = wifi_address(state.addresses.())
    wanted? = ip != nil and state.cert != nil and Node.self() == state.node and tls_paired?()

    cond do
      wanted? and state.front != nil and state.front_ip == ip -> state
      wanted? -> state |> stop_front() |> start_front(ip)
      true -> stop_front(state)
    end
  end

  defp tls_paired? do
    Process.whereis(MobPair.Pairings) != nil and
      Enum.any?(MobPair.Pairings.list(), &(&1[:dist_proto] == :inet_tls))
  end

  defp start_front(state, ip) do
    {:ok, address} = :inet.parse_strict_address(String.to_charlist(ip))

    opts = [
      cert: state.cert,
      ip: address,
      port: state.tls_port,
      target: {{127, 0, 0, 1}, state.dist_port}
    ]

    case MobPair.Front.start_link(opts) do
      {:ok, pid} ->
        Logger.info("pairing: TLS distribution on #{ip}:#{state.tls_port}")
        %{state | front: pid, front_ip: ip}

      {:error, reason} ->
        Logger.warning(
          "pairing: TLS distribution can't listen on #{ip}:#{state.tls_port}: #{inspect(reason)}"
        )

        state
    end
  end

  defp stop_front(%{front: nil} = state), do: state

  defp stop_front(state) do
    Process.unlink(state.front)
    MobPair.Front.stop(state.front)
    %{state | front: nil, front_ip: nil}
  catch
    :exit, _ -> %{state | front: nil, front_ip: nil}
  end

  ## Identity

  # FMutate's certificate and key, made once (JSON: base64url DER, the file 0600). A file that doesn't decode
  # (cut short by a power loss) is replaced: paired apps must pair again.
  defp load_cert(path) do
    case File.read(path) do
      {:ok, json} ->
        with :error <- decode_cert(json) do
          Logger.warning(
            "pairing: #{path} is corrupt, making a new certificate (paired apps pair again)"
          )

          new_cert(path)
        end

      {:error, :enoent} ->
        new_cert(path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_cert(json) do
    with {:ok, %{"cert" => cert, "key" => key}} when is_binary(cert) and is_binary(key) <-
           JSON.decode(json),
         {:ok, cert} <- Base.url_decode64(cert, padding: false),
         {:ok, key} <- Base.url_decode64(key, padding: false) do
      {:ok, %{cert: cert, key: key, fp: MobPair.Cert.fingerprint(cert)}}
    else
      _ -> :error
    end
  end

  defp new_cert(path) do
    cert = MobPair.Cert.self_signed("FMutate")

    json =
      JSON.encode!(%{
        "cert" => Base.url_encode64(cert.cert, padding: false),
        "key" => Base.url_encode64(cert.key, padding: false)
      })

    with :ok <- MobPair.Pairings.write_private(path, json), do: {:ok, cert}
  end

  # what the sibling's screen shows ("FMutate A on moto e"): Mob.Device.model/0 answers "Android" on Android,
  # the system property is readable by any app
  defp device_name do
    with true <- File.exists?(@getprop),
         {model, 0} <- System.cmd(@getprop, ["ro.product.model"]),
         model = String.trim(model),
         true <- model != "" do
      model
    else
      _ -> hostname()
    end
  end

  @doc """
  Whether putting the secret on the clipboard is safe enough to offer Copy code / Copy link: false on
  Android 9 and older (API < 29), where any app in the background can listen for clipboard changes and
  read the secret the moment it is copied; true on Android 10+, and off Android (no `getprop`).
  """
  def copy_safe? do
    with true <- File.exists?(@getprop),
         {sdk, 0} <- System.cmd(@getprop, ["ro.build.version.sdk"]),
         {level, ""} <- sdk |> String.trim() |> Integer.parse() do
      level >= 29
    else
      _ -> true
    end
  end

  defp hostname do
    {:ok, name} = :inet.gethostname()
    List.to_string(name)
  end

  # the running firmware's name for the sibling's screen ("FMutate A · X0X"); nil while no instance runs
  defp firmware_name(instance) do
    with pid when pid != nil <- Process.whereis(FMutate.Registry),
         %{firmware: id} when is_binary(id) <- Instance.view(instance),
         %{name: name} <- Firmware.get(id) do
      name
    else
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp getifaddrs do
    case :inet.getifaddrs() do
      {:ok, addresses} -> addresses
      {:error, _} -> []
    end
  end
end
