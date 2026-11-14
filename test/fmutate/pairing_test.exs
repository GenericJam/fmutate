defmodule FMutate.PairingTest do
  # End to end on this machine: FMutate's side (MobPair.Pairings, FMutate.Dist and FMutate.Pairing, as
  # FMutate.Supervisor starts them) runs in a second BEAM that starts its node the way the app does
  # (fmutate_<inst>@127.0.0.1, no EPMD, loopback listener); this test VM is the sibling, pairing with
  # mob_pair's joining client and connecting with mob_pair's transport, like Humdinger. The player's Allow is
  # a stand-in screen that answers every request. These tests make this VM a distributed node, so they run
  # alone.
  use ExUnit.Case, async: false

  alias FMutate.Pairing
  alias MobPair.{Cert, Client, Epmd, Link, Record, Transport}

  @moduletag :capture_log

  # instance "z": port 9175 and TLS 9275, clear of a real FMutate's adb forwards
  @inst "z"

  # the Pair screen's stand-in, in FMutate's BEAM: opens pairing and allows what it is asked
  @screen """
  defmodule PairingTestScreen do
    def start(answer) do
      parent = self()
      pid = spawn(fn -> init(parent, answer) end)
      receive do: ({:opened, ^pid, info} -> {:ok, pid, info})
    end

    def events(pid) do
      send(pid, {:events, self()})
      receive do: ({:events, events} -> events)
    end

    defp init(parent, answer) do
      {:ok, info} = FMutate.Pairing.open(self())
      send(parent, {:opened, self(), info})
      loop(answer, [])
    end

    defp loop(answer, events) do
      receive do
        {:pairing, {:request, ref, _request}} = event ->
          :ok = FMutate.Pairing.decide(ref, answer)
          loop(answer, [event | events])

        {:pairing, _} = event ->
          loop(answer, [event | events])

        {:events, from} ->
          send(from, {:events, Enum.reverse(events)})
          loop(answer, events)
      end
    end
  end

  defmodule PairingTestBoot do
    # what FMutate.Supervisor starts for pairing; `wifi` stands in for the phone's Wi-Fi address
    def start(inst, data, wifi) do
      addresses = if wifi, do: [{~c"en0", [flags: [:up, :running], addr: wifi]}], else: []
      store = {MobPair.Pairings.FileStore, path: Path.join(data, "pairings.json")}

      children = [
        {MobPair.Pairings, default_cookie: :keep, allow_list: :auto, store: store},
        {FMutate.Dist, instance: inst, delay: 0},
        {FMutate.Pairing, instance: inst, advertise: false, addresses: fn -> addresses end}
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one, name: PairingTestSup)
      Process.unlink(sup)
      {:ok, sup}
    end
  end
  """

  setup do
    :ok = Transport.setup()

    on_exit(fn ->
      if Node.alive?(), do: :net_kernel.stop()
      :application.unset_env(:kernel, :dist_auto_connect)
      :persistent_term.erase({Epmd, :routes})
    end)

    :ok
  end

  # FMutate in a :peer BEAM, started without distribution (FMutate.Dist starts it); `wifi` is the address
  # FMutate.Pairing sees as its Wi-Fi interface (nil: none); `data` its data directory (a new one by default)
  defp start_fmutate(wifi, data \\ nil) do
    data =
      data || Path.join(System.tmp_dir!(), "fmutate_peer_#{System.unique_integer([:positive])}")

    File.mkdir_p!(data)
    on_exit(fn -> File.rm_rf(data) end)

    {:ok, peer, :nonode@nohost} =
      :peer.start(%{
        connection: :standard_io,
        args: [~c"-start_epmd", ~c"false" | Enum.flat_map(:code.get_path(), &[~c"-pa", &1])],
        env: [{~c"MOB_DATA_DIR", String.to_charlist(data)}, {~c"HOME", String.to_charlist(data)}]
      })

    on_exit(fn -> if Process.alive?(peer), do: :peer.stop(peer) end)

    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:elixir])
    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:ssl])
    :peer.call(peer, Code, :compile_string, [@screen])

    {:ok, _} = :peer.call(peer, PairingTestBoot, :start, [@inst, data, wifi])
    node = FMutate.Dist.node_name(@inst)
    wait(fn -> :peer.call(peer, Node, :self, []) == node end)
    %{peer: peer, node: node, data: data}
  end

  defp open(fmutate, answer) do
    {:ok, screen, info} = :peer.call(fmutate.peer, PairingTestScreen, :start, [answer])
    {:ok, link} = Link.parse(info.link)
    {screen, link}
  end

  defp identity do
    %{
      app_id: "com.genericjam.humdinger",
      app_name: "Humdinger",
      device_name: "test phone",
      node: Transport.random_node_name("humdinger"),
      cert: Cert.self_signed("Humdinger")
    }
  end

  defp target(link),
    do: %{service: "fmutate", host: link.host, port: link.port, inst: link.inst, fp: link.fp}

  defp app(fmutate, node) do
    apps = :peer.call(fmutate.peer, FMutate.Dist, :info, []).apps
    Enum.find(apps, &(&1.node == node))
  end

  defp wait(check, tries \\ 100) do
    cond do
      check.() -> :ok
      tries == 0 -> flunk("timed out")
      true -> Process.sleep(50) && wait(check, tries - 1)
    end
  end

  test "a sibling on this phone pairs with the link, is allowed at once and connects; Disconnect unpairs it" do
    fmutate = start_fmutate(nil)
    {screen, link} = open(fmutate, :allow)
    assert link.node == "fmutate_z"
    assert link.host == "127.0.0.1"

    me = identity()
    assert {:ok, %Record{} = record} = Client.pair(target(link), {:token, link.token}, me)

    assert {record.node, record.host, record.dist_port, record.dist_proto} ==
             {"fmutate_z@127.0.0.1", "127.0.0.1", 9175, :inet_tcp}

    me_node = String.to_atom(me.node)
    wait(fn -> app(fmutate, me_node) != nil end)

    assert %{state: :allowed, paired: %{app_name: "Humdinger", remote: false}} =
             app(fmutate, me_node)

    assert {:ok, conn} = Transport.connect(record, self())
    assert conn.node == fmutate.node
    assert :erpc.call(fmutate.node, Node, :self, []) == fmutate.node
    wait(fn -> app(fmutate, me_node).state == :connected end)

    # a stale Allow tap in I/O doesn't give the paired app the sibling cookie
    assert :peer.call(fmutate.peer, FMutate.Dist, :allow, [me_node]) == {:error, :paired}

    assert :peer.call(fmutate.peer, :erlang, :get_cookie, [me_node]) ==
             String.to_atom(record.cookie)

    events = :peer.call(fmutate.peer, PairingTestScreen, :events, [screen])

    assert [{:request, _, %{app_name: "Humdinger"}}] =
             for({:pairing, {:request, _, _} = e} <- events, do: e)

    assert [{:paired, %{app_name: "Humdinger"}}] =
             for({:pairing, {:paired, _} = e} <- events, do: e)

    # Disconnect on the I/O screen revokes the pairing: cut off, and the old cookie no longer opens it
    Node.monitor(fmutate.node, true)
    :ok = :peer.call(fmutate.peer, FMutate.Dist, :disconnect, [me_node])
    assert_receive {:nodedown, _}, 5_000
    assert app(fmutate, me_node) == nil
    Transport.disconnect(conn)
    assert {:error, _} = Transport.connect(record, self())
  end

  test "Don't allow pairs nothing; the node stays unknown" do
    fmutate = start_fmutate(nil)
    {_screen, link} = open(fmutate, :deny)
    me = identity()
    assert Client.pair(target(link), {:token, link.token}, me) == {:error, :denied}
    assert :peer.call(fmutate.peer, MobPair.Pairings, :list, []) == []
    assert app(fmutate, String.to_atom(me.node)) == nil
  end

  test "pairings survive FMutate restarting: the stored cookie gets the sibling back in" do
    fmutate = start_fmutate(nil)
    {_screen, link} = open(fmutate, :allow)
    {:ok, record} = Client.pair(target(link), {:token, link.token}, identity())

    # the registry and Dist restart and load the pairing back (the app relaunching, short of a new BEAM)
    for child <- [FMutate.Dist, MobPair.Pairings],
        do: :ok = :peer.call(fmutate.peer, Supervisor, :terminate_child, [PairingTestSup, child])

    for child <- [MobPair.Pairings, FMutate.Dist],
        do:
          {:ok, _} = :peer.call(fmutate.peer, Supervisor, :restart_child, [PairingTestSup, child])

    assert {:ok, conn} = Transport.connect(record, self())
    assert :erpc.call(fmutate.node, Node, :self, []) == fmutate.node

    # a new BEAM: the pairings load before the node is up, and get their cookies once it is
    Transport.disconnect(conn)
    :peer.stop(fmutate.peer)
    fmutate = start_fmutate(nil, fmutate.data)
    wait(fn -> match?({:ok, _}, Transport.connect(record, self())) end)
    assert :erpc.call(fmutate.node, Node, :self, []) == fmutate.node
  end

  # The distribution flags OTP 26+ requires of a connecting hidden node (as in mob_pair's dist_test).
  @dist_flags Enum.reduce(
                [0x04, 0x10, 0x80, 0x100, 0x200, 0x400, 0x800, 0x10000, 0x20000, 0x40000],
                0x1000000 + 0x2000000 + 0x04 * 0x100000000,
                &(&1 + &2)
              )

  # The first message of a distribution handshake under `name`, and FMutate's answer.
  defp handshake(name) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", FMutate.Dist.port(@inst), [
        :binary,
        active: false,
        packet: 2
      ])

    :ok = :gen_tcp.send(socket, <<?N, @dist_flags::64, 1::32, byte_size(name)::16, name::binary>>)
    answer = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
    answer
  end

  defp atom_on?(peer, name) do
    _ = :peer.call(peer, :erlang, :binary_to_existing_atom, [name])
    true
  rescue
    _ -> false
  end

  # Any app on the phone can reach 127.0.0.1:9150; OTP's handshake would make an atom of every name it declares.
  test "a flood of unknown node names makes no atoms in FMutate, which stays up" do
    fmutate = start_fmutate(nil)
    wait(fn -> :peer.call(fmutate.peer, FMutate.Dist, :info, []).status == :running end)
    atoms = fn -> :peer.call(fmutate.peer, :erlang, :system_info, [:atom_count]) end
    prefix = "intruder#{System.unique_integer([:positive])}x"

    # the first refusals load the code that reports them
    for i <- 1..20, do: assert({:ok, "snot_allowed"} = handshake("#{prefix}#{i}@127.0.0.1"))
    before = atoms.()
    for i <- 21..1_020, do: assert({:ok, "snot_allowed"} = handshake("#{prefix}#{i}@127.0.0.1"))

    # (1000 names: a VM making their atoms grows by 1000; FMutate's own work meanwhile adds a few dozen)
    assert atoms.() - before < 200
    refute Enum.any?(1..1_020, &atom_on?(fmutate.peer, "#{prefix}#{&1}@127.0.0.1"))
    assert :peer.call(fmutate.peer, FMutate.Dist, :info, []).status == :running
  end

  # what FMutateSiblingProvider does for `call(…, "register", name)` from an app signed with FMutate's key
  defp register(fmutate, name) do
    dir = Path.join([fmutate.data, "dist", "requests"])
    File.mkdir_p!(dir)
    File.touch!(Path.join(dir, name))
  end

  defp sibling_connect(fmutate, name) do
    cookie = File.read!(Path.join([fmutate.data, "dist", "sibling_cookie"]))
    :ok = Transport.start_node(name)
    :ok = Epmd.put_route(fmutate.node, {{127, 0, 0, 1}, FMutate.Dist.port(@inst)})
    Node.set_cookie(fmutate.node, String.to_atom(cookie))
    :net_kernel.hidden_connect_node(fmutate.node)
  end

  test "a signed sibling registers its name, the player allows it, it connects; Disconnect cuts it" do
    fmutate = start_fmutate(nil)
    wait(fn -> :peer.call(fmutate.peer, FMutate.Dist, :info, []).status == :running end)
    name = "voice_#{System.unique_integer([:positive])}@127.0.0.1"

    # the sibling cookie alone doesn't get a name in that nobody registered, nor lists it
    refute sibling_connect(fmutate, name)
    refute atom_on?(fmutate.peer, name)
    assert :peer.call(fmutate.peer, FMutate.Dist, :info, []).apps == []

    register(fmutate, name)
    node = String.to_atom(name)
    wait(fn -> match?(%{state: :pending}, app(fmutate, node)) end)
    refute :net_kernel.hidden_connect_node(fmutate.node)

    :ok = :peer.call(fmutate.peer, FMutate.Dist, :allow, [node])
    assert :net_kernel.hidden_connect_node(fmutate.node)
    assert :erpc.call(fmutate.node, Node, :self, []) == fmutate.node
    wait(fn -> app(fmutate, node).state == :connected end)

    Node.monitor(fmutate.node, true)
    :ok = :peer.call(fmutate.peer, FMutate.Dist, :disconnect, [node])
    assert_receive {:nodedown, _}, 5_000
    refute :net_kernel.hidden_connect_node(fmutate.node)
  end

  test "a Disconnect that can't be saved says so, holds, and is saved once the disk allows it" do
    fmutate = start_fmutate(nil)
    wait(fn -> :peer.call(fmutate.peer, FMutate.Dist, :info, []).status == :running end)
    name = "voice_#{System.unique_integer([:positive])}@127.0.0.1"
    node = String.to_atom(name)
    register(fmutate, name)
    wait(fn -> app(fmutate, node) != nil end)
    :ok = :peer.call(fmutate.peer, FMutate.Dist, :allow, [node])

    dist_dir = Path.join(fmutate.data, "dist")
    File.chmod!(dist_dir, 0o500)
    on_exit(fn -> File.chmod(dist_dir, 0o700) end)

    assert :peer.call(fmutate.peer, FMutate.Dist, :disconnect, [node]) == {:error, :not_saved}
    refute :peer.call(fmutate.peer, FMutate.Dist, :permitted?, [node])
    assert :peer.call(fmutate.peer, FMutate.Dist, :info, []).unsaved
    refute sibling_connect(fmutate, name)

    File.chmod!(dist_dir, 0o700)

    wait(
      fn ->
        {:ok, bin} = File.read(Path.join(dist_dir, "allowed.term"))
        :erlang.binary_to_term(bin) == []
      end,
      200
    )

    refute :peer.call(fmutate.peer, FMutate.Dist, :info, []).unsaved

    # a new BEAM: the app is still out
    :peer.stop(fmutate.peer)
    fmutate = start_fmutate(nil, fmutate.data)
    wait(fn -> :peer.call(fmutate.peer, FMutate.Dist, :info, []).status == :running end)
    refute :peer.call(fmutate.peer, FMutate.Dist, :permitted?, [node])
  end

  @tag :lan
  test "a sibling on another phone gets TLS distribution through FMutate's front, bound to its name" do
    case lan_address() do
      nil ->
        :ok

      wifi ->
        fmutate = start_fmutate(wifi)
        {_screen, link} = open(fmutate, :allow)
        assert link.host == :inet.ntoa(wifi) |> List.to_string()

        me = identity()

        assert {:ok, %Record{dist_proto: :inet_tls, dist_port: 9275} = record} =
                 Client.pair(target(link), {:token, link.token}, me)

        me_node = String.to_atom(me.node)
        wait(fn -> match?(%{paired: %{remote: true}}, app(fmutate, me_node)) end)
        wait(fn -> :peer.call(fmutate.peer, Pairing, :front_port, []) == 9275 end)

        assert {:ok, %{tunnel: tunnel}} = Transport.connect(record, self())
        assert is_pid(tunnel)
        assert :erpc.call(fmutate.node, Node, :self, []) == fmutate.node
        wait(fn -> app(fmutate, me_node).state == :connected end)
    end
  end

  # this machine's LAN address, standing in for FMutate's Wi-Fi address
  defp lan_address do
    {:ok, ifaddrs} = :inet.getifaddrs()

    case Pairing.wifi_address(ifaddrs) do
      nil -> nil
      ip -> ip |> String.to_charlist() |> :inet.parse_strict_address() |> elem(1)
    end
  end
end
