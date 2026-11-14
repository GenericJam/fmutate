defmodule FMutate.Dist do
  @moduledoc """
  Erlang distribution for sibling apps (protocol.md): this app's node, who may connect, and the player's
  Allow / Disconnect (the I/O screen).

  ## The node

  The app is node `fmutate_<instance>@127.0.0.1` (v1: `fmutate_a@127.0.0.1`), listening on 127.0.0.1 only,
  on a fixed port per instance (`port/1`: a → #{9150}), with **no EPMD**: Android has no EPMD daemon, and a
  fixed port is all a sibling needs to know. (OTP's `erl_epmd` with `erl_epmd_node_listen_port` set does
  this: it registers with an EPMD when one answers on 4369 and runs without one otherwise.) Started a few
  seconds after launch, like Mob's development node: starting distribution while Android's UI starts can
  abort the app (see `Mob.Dist`). This replaces `Mob.Dist.ensure_started/1`; development tools reach the
  node the same way (`tools/rpc.exs`).

  A sibling connects with no EPMD either:

      erl -name voice@127.0.0.1 -setcookie <cookie> -start_epmd false -erl_epmd_port 9150 -dist_listen false

  (`-dist_listen false` makes it a hidden node that only connects out, so it needs no port of its own.)

  ## Cookies and Allow

  Three cookies:

    * the **sibling cookie**: random per install, never shown. Sibling apps signed with FMutate's key read
      it, with the node name and port, from the content provider `content://com.genericjam.fmutate.siblings`
      (protected by a signature permission, so Android checks the signing certificate: protocol.md §5).
      It is written to `Paths.dist_dir()/sibling` for that provider.
    * the **default cookie** of this node: the mob_dev development cookie in builds deployed by mob_dev
      (`$MOB_BEAMS_DIR/mob_dist_cookie`, so the developer's tools get in), else a random cookie nobody has.
    * per allowed node, `Node.set_cookie(node, sibling_cookie)`.

  A sibling first registers its node name through the same provider (`FMutate.Dist.Requests`); this process
  picks the registration up within a second and lists the app as pending. Allow sets its cookie and adds it
  to the `net_kernel` allow list: its next attempt connects (siblings retry). Disconnect sets a throwaway
  cookie and cuts the connection. Allowed nodes are kept across restarts. The state machine is
  `FMutate.Dist.Access`.

  The allow list: OTP's handshake makes an atom of the name a connecting node declares (before the cookie
  check) unless the allow list refuses it, and any app on the phone can reach the loopback port. So release
  builds set a non-empty allow list (a placeholder name, the allowed names, and `MobPair.Pairings` adds the
  paired ones) right after the node starts, and any other name is refused with no atom made. Development
  builds (mob_dev's cookie) leave it open, because their tools connect under names chosen per run.

  ## Paired apps

  Apps paired on the Pair screen (`FMutate.Pairing`, protocol.md §1: QR code or typed code, the player's
  Allow) are kept by `MobPair.Pairings` with a cookie of their own, set for exactly the node name they
  declared; this process follows it (`MobPair.Pairings.subscribe/1`): a new pairing is allowed at once, and
  Disconnect (or the app's `{:unpair, node}`) revokes the pairing, which drops the node until it pairs again.
  Paired names never get the sibling cookie (an I/O Allow for one answers `{:error, :paired}`) and aren't
  written to `allowed.term`; a name the player already let in with the sibling cookie can't be paired
  (`claimed?/1`). `MobPair.Pairings` sets the paired nodes' cookies once the node is up
  (`MobPair.Pairings.distribution_started/0`). A paired app on another phone arrives through
  `MobPair.Front` (TLS) as a loopback connection under its paired name.

  Subscribers get `{:dist, info}` (see `info/0`) on every change.
  """

  use GenServer
  require Logger

  alias FMutate.Dist.{Access, Requests}
  alias FMutate.Paths

  @base_port 9150
  @start_delay_ms 3_000
  # the allow list is enforced only once it is non-empty: a name that never connects keeps it so
  @nobody :nobody@invalid
  # how often registrations (FMutate.Dist.Requests) are picked up, and a failed allowed.term write retried
  @requests_ms 1_000
  @save_retry_ms 5_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The node name of an instance (`\"a\"` → `:\"fmutate_a@127.0.0.1\"`)."
  def node_name(instance), do: :"fmutate_#{instance}@127.0.0.1"

  @doc "The distribution port of an instance's node (`\"a\"` → #{@base_port})."
  def port(<<c>>) when c in ?a..?z, do: @base_port + (c - ?a)

  @doc """
  `%{node, port, status, apps, dev_tools, driven, unsaved}`: `status` is `:starting | :running | {:error,
  reason}`; `apps` is `FMutate.Dist.Access.list/1`, each with `paired` (nil, or `%{app_name, device_name,
  remote}` for an app paired on the Pair screen); `driven` the instances that got remote input in the last 2 s
  (protocol.md §2; inputs are casts, so they can't be told apart by app); `unsaved` true while a change to
  the allowed or paired apps isn't stored yet (retried; in force here meanwhile).
  """
  def info, do: GenServer.call(__MODULE__, :info)

  @doc "Subscribe the caller to `{:dist, info}`; returns the current info."
  def subscribe, do: GenServer.call(__MODULE__, {:subscribe, self()})

  @doc """
  The player allows a pending app (one that registered, `FMutate.Dist.Requests`). A paired app isn't the
  sibling cookie's: `{:error, :paired}`.
  """
  def allow(node), do: GenServer.call(__MODULE__, {:allow, node})

  @doc """
  The player cuts an app off. A paired app's pairing is revoked (it has to pair again);
  `{:error, :not_saved}` when the revocation couldn't be stored.
  """
  def disconnect(node), do: GenServer.call(__MODULE__, {:disconnect, node})

  @doc """
  Whether this build was deployed by mob_dev (its development cookie is there): development tools connect
  under any name, so the node keeps no allow list.
  """
  def dev_build?, do: dev_cookie() != nil

  @doc "A paired app forgets its pairing (`{:unpair, node}`, protocol §1.5): revoked like Disconnect."
  def unpair(node), do: GenServer.call(__MODULE__, {:unpair, node})

  @doc "Whether calls from `node` are served: this node, or an allowed app."
  def permitted?(node) when node == node(), do: true
  def permitted?(node), do: GenServer.call(__MODULE__, {:permitted?, node})

  @doc """
  Whether the node name `name` (as a sibling declares it) belongs to a sibling-cookie app the player let in
  (allowed, connected or disconnected in `FMutate.Dist.Access`, not paired). Pairing refuses such names, so
  it can't take one over. A pending name isn't claimed: any signed sibling can register any name. Makes no
  atom (a name never seen is unknown); false when this process isn't running.
  """
  @spec claimed?(String.t()) :: boolean()
  def claimed?(name) when is_binary(name) do
    node = String.to_existing_atom(name)
    Process.whereis(__MODULE__) != nil and GenServer.call(__MODULE__, {:claimed?, node})
  rescue
    ArgumentError -> false
  end

  @doc "An instance got remote input (`FMutate.Remote`): it counts as driven from outside for 2 s."
  def driving(instance), do: GenServer.cast(__MODULE__, {:driving, instance})

  ## Server

  @impl true
  def init(opts) do
    instance = Keyword.get(opts, :instance, "a")
    dev_cookie = dev_cookie()
    sibling = sibling_cookie()
    paired = paired_apps()
    remembered = Access.new(load_allowed() -- Map.keys(paired), dev: dev_cookie != nil)
    access = Enum.reduce(Map.keys(paired), remembered, &Access.pair(&2, &1, 0))

    state = %{
      instance: instance,
      node: node_name(instance),
      port: port(instance),
      sibling: sibling,
      default: dev_cookie || random_cookie(),
      access: access,
      paired: paired,
      status: :starting,
      driving: %{},
      # allowed.term couldn't be written: retried until it is (save_allowed/1)
      unsaved: false,
      pairings_unsaved: false,
      subscribers: %{}
    }

    write_sibling_file(state)

    if Keyword.get(opts, :start, true),
      do: Process.send_after(self(), :start, Keyword.get(opts, :delay, @start_delay_ms))

    {:ok, state}
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, info_of(state), state}

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, info_of(state), %{state | subscribers: Map.put(state.subscribers, pid, ref)}}
  end

  # a stale Allow tap (I/O) on an app that has paired meanwhile: its cookie is the pairing's. MobPair.Pairings
  # is asked too: its :added event may still be on its way here.
  def handle_call({:allow, node}, _from, state) do
    with false <- paired?(state, node),
         {:ok, access} <- Access.allow(state.access, node, now()) do
      if Node.alive?() do
        Node.set_cookie(node, state.sibling)
        if not state.access.dev, do: :net_kernel.allow([node])
      end

      state = save_allowed(%{state | access: access})
      {:reply, :ok, notify(state)}
    else
      true -> {:reply, {:error, :paired}, state}
      error -> {:reply, error, state}
    end
  end

  # a paired app's Disconnect revokes its pairing; the :revoked event drops it (handle_info below)
  def handle_call({:disconnect, node}, _from, state) when is_map_key(state.paired, node),
    do: revoke(node, state)

  def handle_call({:disconnect, node}, _from, state) do
    case Access.disconnect(state.access, node, now()) do
      {:ok, access} ->
        if is_atom(node) and Node.alive?() do
          Node.set_cookie(node, random_cookie())
          Node.disconnect(node)
        end

        state = save_allowed(%{state | access: access})
        {:reply, if(state.unsaved, do: {:error, :not_saved}, else: :ok), notify(state)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:unpair, node}, _from, state) when is_map_key(state.paired, node),
    do: revoke(node, state)

  def handle_call({:unpair, _node}, _from, state), do: {:reply, {:error, :not_paired}, state}

  def handle_call({:permitted?, node}, _from, state),
    do: {:reply, Access.permitted?(state.access, node), state}

  def handle_call({:claimed?, node}, _from, state) do
    known? = Access.state(state.access, node) in [:allowed, :connected, :disconnected]
    {:reply, known? and not is_map_key(state.paired, node), state}
  end

  @impl true
  def handle_cast({:driving, instance}, state) do
    first = not Map.has_key?(state.driving, instance)
    if first, do: Process.send_after(self(), {:driving_check, instance}, 2_000)
    state = put_in(state.driving[instance], now())
    {:noreply, if(first, do: notify(state), else: state)}
  end

  @impl true
  def handle_info(:start, state), do: {:noreply, notify(start(state))}

  def handle_info({:nodeup, node, _info}, state) do
    {verdict, access} = Access.nodeup(state.access, node, now())

    case verdict do
      :accept ->
        Logger.info("dist: #{node} connected")

      :dev ->
        Logger.info("dist: development tool #{node} connected")

      :refuse ->
        Logger.warning("dist: refusing #{node}")
        Node.disconnect(node)
    end

    {:noreply, notify(%{state | access: access})}
  end

  def handle_info({:nodedown, node, _info}, state) do
    access = Access.nodedown(state.access, node, now())
    {:noreply, notify(%{state | access: access})}
  end

  # siblings that registered through the provider since the last look: pending until the player's Allow;
  # and whether MobPair.Pairings' store caught up after a failed save
  def handle_info(:requests, state) do
    Process.send_after(self(), :requests, @requests_ms)

    access =
      Enum.reduce(Requests.take(requests_dir()), state.access, fn name, access ->
        access |> Access.knock(String.to_atom(name), now()) |> elem(1)
      end)

    new = %{state | access: access, pairings_unsaved: pairings_unsaved?()}
    {:noreply, if(new == state, do: state, else: notify(new))}
  end

  def handle_info({:driving_check, instance}, state) do
    case state.driving do
      %{^instance => t} ->
        if now() - t >= 2_000 do
          {:noreply, notify(%{state | driving: Map.delete(state.driving, instance)})}
        else
          Process.send_after(self(), {:driving_check, instance}, 2_000 - (now() - t))
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  # MobPair.Pairings (subscribed in paired_apps/0): the Pair screen's Allow, and revocations. Pairings sets the
  # paired node's cookie itself; it is set again here in case an I/O Allow (sibling cookie) raced the pairing,
  # and a connection the name had as a sibling-cookie app is cut (it reconnects as the paired app).
  def handle_info({:mob_pair_pairings, :added, pairing}, state) do
    node = String.to_atom(pairing.node)

    sibling? =
      Access.state(state.access, node) == :connected and not is_map_key(state.paired, node)

    if Node.alive?() do
      Node.set_cookie(node, String.to_atom(pairing.cookie))
      if sibling?, do: Node.disconnect(node)
    end

    access = if sibling?, do: Access.forget(state.access, node), else: state.access
    access = Access.pair(access, node, now())
    paired = Map.put(state.paired, node, summary(pairing))
    {:noreply, notify(save_allowed(%{state | access: access, paired: paired}))}
  end

  def handle_info(:save_allowed, state),
    do: {:noreply, if(state.unsaved, do: save_allowed(%{state | unsaved: false}), else: state)}

  def handle_info({:mob_pair_pairings, :revoked, pairing}, state) do
    node = String.to_atom(pairing.node)

    {:noreply,
     notify(%{
       state
       | access: Access.forget(state.access, node),
         paired: Map.delete(state.paired, node)
     })}
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

  def handle_info(_msg, state), do: {:noreply, state}

  # the cookies stay out of crash reports and :sys.get_status/1
  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %{sibling: _, default: _} = state -> %{state | sibling: :redacted, default: :redacted}
      other -> other
    end)
  end

  ## Internals

  defp start(state) do
    cond do
      # this process restarted: the node is ours already
      Node.self() == state.node ->
        configure(state)

      Node.alive?() ->
        %{state | status: {:error, {:already_alive, Node.self()}}}

      true ->
        :application.set_env(:kernel, :erl_epmd_node_listen_port, state.port)
        :application.set_env(:kernel, :inet_dist_use_interface, {127, 0, 0, 1})
        # OTP keeps the cookie file under HOME; make sure it can
        File.mkdir_p(Path.join(System.get_env("HOME") || Paths.data_dir(), ".config/erlang"))

        case Node.start(state.node, :longnames) do
          {:ok, _} ->
            Logger.info("dist: #{state.node} on 127.0.0.1:#{state.port}")
            configure(state)

          {:error, reason} ->
            Logger.error("dist: #{state.node} did not start: #{inspect(reason)}")
            %{state | status: {:error, reason}}
        end
    end
  end

  # Release builds: a non-empty allow list first, so OTP refuses any other name before its handshake makes
  # an atom of it (any app on the phone can connect to the loopback port). MobPair.Pairings adds the paired
  # names; Allow adds a sibling-cookie name. Development builds (mob_dev's cookie) keep it open: their tools
  # connect under any name.
  defp configure(state) do
    allowed =
      for node <- Access.allowed(state.access), not is_map_key(state.paired, node), do: node

    if not state.access.dev, do: :ok = :net_kernel.allow([@nobody | allowed])
    Node.set_cookie(state.default)
    for node <- allowed, do: Node.set_cookie(node, state.sibling)

    # MobPair.Pairings sets the paired nodes' cookies (and adds them to the allow list), and guards revoked
    # names, once the node is up
    if Process.whereis(MobPair.Pairings), do: MobPair.Pairings.distribution_started()

    :ok = :net_kernel.monitor_nodes(true, node_type: :all)
    if state.status != :running, do: send(self(), :requests)
    %{state | status: :running}
  end

  defp requests_dir, do: Path.join(Paths.dist_dir(), "requests")

  defp info_of(state) do
    %{
      node: state.node,
      port: state.port,
      status: state.status,
      apps:
        for(app <- Access.list(state.access), do: Map.put(app, :paired, state.paired[app.node])),
      driven: state.driving |> Map.keys() |> Enum.sort(),
      dev_tools: state.access.dev_nodes |> MapSet.to_list() |> Enum.sort(),
      unsaved: state.unsaved or state.pairings_unsaved
    }
  end

  defp notify(state) do
    info = info_of(state)
    for {pid, _} <- state.subscribers, do: send(pid, {:dist, info})
    state
  end

  # ── cookies ──

  # mob_dev writes 32 random bytes as lowercase hex to $MOB_BEAMS_DIR/mob_dist_cookie when it deploys
  defp dev_cookie do
    with dir when dir not in [nil, ""] <- System.get_env("MOB_BEAMS_DIR"),
         {:ok, raw} <- File.read(Path.join(dir, "mob_dist_cookie")),
         cookie = String.trim(raw),
         true <- cookie =~ ~r/\A[0-9a-f]{64}\z/ do
      String.to_atom(cookie)
    else
      _ -> nil
    end
  end

  defp sibling_cookie do
    path = Path.join(Paths.dist_dir(), "sibling_cookie")

    case File.read(path) do
      {:ok, raw} when byte_size(raw) == 64 ->
        String.to_atom(raw)

      _ ->
        cookie = random_cookie()
        :ok = MobPair.Pairings.write_private(path, Atom.to_string(cookie))
        cookie
    end
  end

  defp random_cookie,
    do: 32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower) |> String.to_atom()

  # what the Android provider hands to signed siblings: one `key=value` per line (0600, written whole)
  defp write_sibling_file(state) do
    path = Path.join(Paths.dist_dir(), "sibling")
    body = "node=#{state.node}\nport=#{state.port}\ncookie=#{state.sibling}\nprotocol=1\n"
    :ok = MobPair.Pairings.write_private(path, body)
  end

  # node names as text: they are atoms this VM hasn't seen yet, which binary_to_term(:safe) won't create
  defp load_allowed do
    case File.read(allowed_path()) do
      {:ok, bin} ->
        for name <- :erlang.binary_to_term(bin, [:safe]),
            Requests.valid?(name),
            do: String.to_atom(name)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  # Paired names are MobPair.Pairings' (with their own cookies), never the sibling cookie's. Written whole (a
  # temporary file, synced, renamed), so a crash keeps the old list or the new one. Fails closed: when it
  # can't be written the file is deleted (a disconnected app mustn't come back at the next start; the allowed
  # ones need Allow again then), the state is kept here and the write retried every few seconds.
  defp save_allowed(state) do
    names =
      for node <- Access.allowed(state.access),
          not is_map_key(state.paired, node),
          do: Atom.to_string(node)

    case MobPair.Pairings.write_private(allowed_path(), :erlang.term_to_binary(names)) do
      :ok ->
        %{state | unsaved: false}

      {:error, reason} ->
        Logger.error("dist: allowed apps not saved (#{inspect(reason)}); retrying")
        File.rm(allowed_path())
        if not state.unsaved, do: Process.send_after(self(), :save_allowed, @save_retry_ms)
        %{state | unsaved: true}
    end
  end

  defp allowed_path, do: Path.join(Paths.dist_dir(), "allowed.term")

  # ── pairings (MobPair.Pairings; absent in tests that run Dist alone) ──

  defp paired_apps do
    if Process.whereis(MobPair.Pairings) do
      MobPair.Pairings.subscribe(self())
      Map.new(pairings(), &{String.to_atom(&1.node), summary(&1)})
    else
      %{}
    end
  end

  defp pairings, do: if(Process.whereis(MobPair.Pairings), do: MobPair.Pairings.list(), else: [])

  defp paired?(state, node) do
    is_map_key(state.paired, node) or
      (Process.whereis(MobPair.Pairings) != nil and MobPair.Pairings.get(to_string(node)) != nil)
  end

  # The pairing is revoked at once whatever the store says; `{:error, :not_saved}` (and I/O says so) when
  # MobPair.Pairings couldn't save it yet (it retries; :requests notices when it caught up).
  defp revoke(node, state) do
    case MobPair.Pairings.revoke(node) do
      :ok ->
        {:reply, :ok, state}

      error ->
        Logger.error("dist: revoking #{node} wasn't saved: #{inspect(error)}")
        {:reply, {:error, :not_saved}, notify(%{state | pairings_unsaved: true})}
    end
  end

  defp pairings_unsaved?,
    do: Process.whereis(MobPair.Pairings) != nil and not MobPair.Pairings.saved?()

  defp summary(pairing),
    do: %{
      app_name: pairing.app_name,
      device_name: pairing.device_name,
      remote: pairing[:dist_proto] == :inet_tls
    }

  defp now, do: System.monotonic_time(:millisecond)
end
