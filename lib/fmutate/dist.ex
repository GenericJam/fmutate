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

  So an app that isn't allowed is refused at the handshake (no message of its reaches the node);
  `FMutate.Dist.Knock` hears the refusal and the app is listed as pending. Allow sets its cookie: its next
  attempt connects (siblings retry). Disconnect sets a throwaway cookie and cuts the connection. Allowed
  nodes are kept across restarts. The state machine is `FMutate.Dist.Access`.

  Subscribers get `{:dist, info}` (see `info/0`) on every change.
  """

  use GenServer
  require Logger

  alias FMutate.Dist.{Access, Knock}
  alias FMutate.Paths

  @base_port 9150
  @start_delay_ms 3_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The node name of an instance (`\"a\"` → `:\"fmutate_a@127.0.0.1\"`)."
  def node_name(instance), do: :"fmutate_#{instance}@127.0.0.1"

  @doc "The distribution port of an instance's node (`\"a\"` → #{@base_port})."
  def port(<<c>>) when c in ?a..?z, do: @base_port + (c - ?a)

  @doc """
  `%{node, port, status, apps, dev_tools, driven}`: `status` is `:starting | :running | {:error, reason}`;
  `apps` is `FMutate.Dist.Access.list/1`; `driven` the instances that got remote input in the last 2 s
  (protocol.md §2; inputs are casts, so they can't be told apart by app).
  """
  def info, do: GenServer.call(__MODULE__, :info)

  @doc "Subscribe the caller to `{:dist, info}`; returns the current info."
  def subscribe, do: GenServer.call(__MODULE__, {:subscribe, self()})

  @doc "The player allows a pending app."
  def allow(node), do: GenServer.call(__MODULE__, {:allow, node})

  @doc "The player cuts an app off."
  def disconnect(node), do: GenServer.call(__MODULE__, {:disconnect, node})

  @doc "Whether calls from `node` are served: this node, or an allowed app."
  def permitted?(node) when node == node(), do: true
  def permitted?(node), do: GenServer.call(__MODULE__, {:permitted?, node})

  @doc "An instance got remote input (`FMutate.Remote`): it counts as driven from outside for 2 s."
  def driving(instance), do: GenServer.cast(__MODULE__, {:driving, instance})

  ## Server

  @impl true
  def init(opts) do
    instance = Keyword.get(opts, :instance, "a")
    dev_cookie = dev_cookie()
    sibling = sibling_cookie()

    state = %{
      instance: instance,
      node: node_name(instance),
      port: port(instance),
      sibling: sibling,
      default: dev_cookie || random_cookie(),
      access: Access.new(load_allowed(), dev: dev_cookie != nil),
      status: :starting,
      driving: %{},
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

  def handle_call({:allow, node}, _from, state) do
    case Access.allow(state.access, node, now()) do
      {:ok, access} ->
        Node.set_cookie(node, state.sibling)
        save_allowed(access)
        {:reply, :ok, notify(%{state | access: access})}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:disconnect, node}, _from, state) do
    case Access.disconnect(state.access, node, now()) do
      {:ok, access} ->
        Node.set_cookie(node, random_cookie())
        Node.disconnect(node)
        save_allowed(access)
        {:reply, :ok, notify(%{state | access: access})}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:permitted?, node}, _from, state),
    do: {:reply, Access.permitted?(state.access, node), state}

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

  def handle_info({:knock, node}, state) do
    case Access.knock(state.access, node, now()) do
      {:pending, access} -> {:noreply, notify(%{state | access: access})}
      {:ignored, _} -> {:noreply, state}
    end
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

  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

  def handle_info(_msg, state), do: {:noreply, state}

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

  defp configure(state) do
    Node.set_cookie(state.default)
    for node <- Access.allowed(state.access), do: Node.set_cookie(node, state.sibling)
    :ok = :net_kernel.monitor_nodes(true, node_type: :all)
    Knock.install(self())
    %{state | status: :running}
  end

  defp info_of(state) do
    %{
      node: state.node,
      port: state.port,
      status: state.status,
      apps: Access.list(state.access),
      driven: state.driving |> Map.keys() |> Enum.sort(),
      dev_tools: state.access.dev_nodes |> MapSet.to_list() |> Enum.sort()
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
        File.write!(path, Atom.to_string(cookie))
        File.chmod(path, 0o600)
        cookie
    end
  end

  defp random_cookie,
    do: 32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower) |> String.to_atom()

  # what the Android provider hands to signed siblings: one `key=value` per line
  defp write_sibling_file(state) do
    path = Path.join(Paths.dist_dir(), "sibling")
    body = "node=#{state.node}\nport=#{state.port}\ncookie=#{state.sibling}\nprotocol=1\n"
    File.write!(path, body)
    File.chmod(path, 0o600)
  end

  # node names as text: they are atoms this VM hasn't seen yet, which binary_to_term(:safe) won't create
  defp load_allowed do
    case File.read(Path.join(Paths.dist_dir(), "allowed.term")) do
      {:ok, bin} -> bin |> :erlang.binary_to_term([:safe]) |> Enum.map(&String.to_atom/1)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp save_allowed(access) do
    names = access |> Access.allowed() |> Enum.map(&Atom.to_string/1)
    File.write!(Path.join(Paths.dist_dir(), "allowed.term"), :erlang.term_to_binary(names))
  end

  defp now, do: System.monotonic_time(:millisecond)
end
