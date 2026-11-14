defmodule FMutate.PairScreenTest do
  # The Pair screen against a real pairing endpoint (FMutate.Pairing → MobPair.Host on loopback) and a real
  # joining client (MobPair.Client, as Humdinger runs it): what the player sees and what each answer does.
  use Mob.ScreenCase, async: false

  alias FMutate.{Dist, Pairing, PairScreen}
  alias MobPair.{Cert, Client, Code, Link, Pairings, Transport}

  @moduletag :capture_log

  defmodule FakeClipboard do
    # Mob.Clipboard's stand-in (it calls the NIF): the clipboard is the test process's dictionary
    def put(socket, text) do
      Process.put(:clipboard, text)
      socket
    end

    def get(_socket) do
      case Process.get(:clipboard) do
        nil -> {:clipboard, :empty}
        text -> {:clipboard, :ok, text}
      end
    end
  end

  # Tags: `host_opts` (more MobPair.Host options), `wifi` (the Wi-Fi address FMutate.Pairing sees at first),
  # `cert` (pair_cert.json before FMutate.Pairing starts: its contents, :unreadable or :mismatched),
  # `paired` (an app paired before FMutate.Pairing starts), `allowed` (node names FMutate.Dist allowed with
  # the sibling cookie in an earlier run: starts FMutate.Dist), `copy_safe` (FMutate.Pairing's option;
  # without it, this machine's answer: no getprop, so true)
  setup context do
    dir = Path.join(System.tmp_dir!(), "fmutate_pair_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    write_cert(dir, context[:cert])

    start_supervised!({Pairings, default_cookie: :keep, allow_list: false})
    if context[:paired], do: {:ok, _} = Pairings.add(pairing("humdinger_old@127.0.0.1"))
    if allowed = context[:allowed], do: start_dist(allowed)

    wifi = if ip = context[:wifi], do: [{~c"wlan0", [flags: [:up, :running], addr: ip]}], else: []
    addresses = start_supervised!({Agent, fn -> wifi end})

    copy_safe = if Map.has_key?(context, :copy_safe), do: [copy_safe: context.copy_safe], else: []

    start_supervised!(
      {Pairing,
       [
         dir: dir,
         addresses: fn -> Agent.get(addresses, & &1) end,
         advertise: false,
         node: :"fmutate_a@127.0.0.1",
         dist_port: 9150,
         host_opts: Map.get(context, :host_opts, [])
       ] ++ copy_safe}
    )

    %{dir: dir, addresses: addresses}
  end

  defp write_cert(_dir, nil), do: :ok

  defp write_cert(dir, :unreadable) do
    path = Path.join(dir, "pair_cert.json")
    File.write!(path, "{}")
    File.chmod!(path, 0o000)
  end

  # a certificate and the key of another one: both decode (a copy in mismatched.json, for the test)
  defp write_cert(dir, :mismatched) do
    {cert, other} = {Cert.self_signed("FMutate"), Cert.self_signed("FMutate")}
    encode = &Base.url_encode64(&1, padding: false)
    json = JSON.encode!(%{"cert" => encode.(cert.cert), "key" => encode.(other.key)})
    File.write!(Path.join(dir, "pair_cert.json"), json)
    File.write!(Path.join(dir, "mismatched.json"), json)
  end

  defp write_cert(dir, contents), do: File.write!(Path.join(dir, "pair_cert.json"), contents)

  # what the Host gives MobPair.Pairings.add/1 on Allow
  defp pairing(node) do
    %{
      node: node,
      app_id: "com.genericjam.humdinger",
      app_name: "Humdinger",
      device_name: "moto e",
      client_fp: :crypto.strong_rand_bytes(32),
      dist_proto: :inet_tcp
    }
  end

  # FMutate.Dist without distribution; its files are in the data directory Mob.ScreenCase sets up
  defp start_dist(allowed) do
    dir = FMutate.Paths.dist_dir()

    files =
      for name <- ["allowed.term", "sibling", "sibling_cookie", "requests"],
          do: Path.join(dir, name)

    on_exit(fn -> Enum.each(files, &File.rm_rf/1) end)
    File.write!(Path.join(dir, "allowed.term"), :erlang.term_to_binary(allowed))
    start_supervised!({Dist, start: false})
  end

  # what the content provider does for a sibling that registers its name, and FMutate.Dist's next look
  defp register(node) do
    dir = Path.join(FMutate.Paths.dist_dir(), "requests")
    File.mkdir_p!(dir)
    File.touch!(Path.join(dir, Atom.to_string(node)))
    send(Dist, :requests)
  end

  defp mount, do: mount_screen(PairScreen, %{}, %{clipboard: FakeClipboard})
  defp clipboard, do: Process.get(:clipboard)

  defp identity(name \\ "Humdinger") do
    %{
      app_id: "com.genericjam.humdinger",
      app_name: name,
      device_name: "moto e",
      node: Transport.random_node_name("humdinger"),
      cert: Cert.self_signed(name)
    }
  end

  defp target(view, fp \\ :link) do
    {:ok, link} = Link.parse(assigns(view).info.link)

    %{
      service: "fmutate",
      host: "127.0.0.1",
      port: link.port,
      inst: "a",
      fp: if(fp == :link, do: link.fp, else: fp)
    }
  end

  defp token(view) do
    {:ok, link} = Link.parse(assigns(view).info.link)
    {:token, link.token}
  end

  # a sibling pairing with the screen's link, in its own process (it waits for the player's answer)
  defp ask(view, name \\ "Humdinger") do
    {target, auth, me} = {target(view), token(view), identity(name)}
    task = Task.async(fn -> Client.pair(target, auth, me) end)
    assert_receive {:pairing, {:request, _ref, _request}} = msg, 5_000
    {task, render_info(view, msg)}
  end

  test "shows the QR code and the typed code, with the countdown" do
    view = mount_screen(PairScreen)
    info = Pairing.info()

    assert assigns(view).info.code == info.code
    assert {:ok, _} = Code.normalize(info.code)
    assert find(view, :canvas, id: "pair_qr")
    assert text(view) =~ info.code
    assert text(view) =~ ~r/expires in [45]:\d\d/
    assert text(view) =~ "No Wi-Fi: only apps on this phone can pair."
    # off Android (and on Android 10+) the secret may go on the clipboard
    assert info.copy_safe
    assert find(view, :button, text: "Copy code")
    assert find(view, :button, text: "Copy link")
    assert text(view) =~ "On this phone, Copy link and paste it there."
    assert_renderable(view)
  end

  @tag copy_safe: false
  test "where other apps can watch the clipboard (Android 9) there is no Copy: the code is typed" do
    view = mount()
    refute find(view, :button, text: "Copy code")
    refute find(view, :button, text: "Copy link")
    assert text(view) =~ "On this phone, type the code in the other app."
    refute text(view) =~ "Copy link"
    assert find(view, :canvas, id: "pair_qr")
    assert_renderable(view)

    # a stale tap copies nothing
    view = view |> render_info({:tap, :copy_code}) |> render_info({:tap, :copy_link})
    assert clipboard() == nil
    assert assigns(view).copied == nil
  end

  test "Copy is offered off Android and from Android 10, and not when the Android version can't be read" do
    dir = Path.join(System.tmp_dir!(), "getprop_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    getprop = fn name, script ->
      path = Path.join(dir, name)
      File.write!(path, "#!/bin/sh\n" <> script <> "\n")
      File.chmod!(path, 0o755)
      path
    end

    assert FMutate.Pairing.copy_safe?(Path.join(dir, "none"))
    assert FMutate.Pairing.copy_safe?(getprop.("q", "echo 29"))
    refute FMutate.Pairing.copy_safe?(getprop.("p", "echo 28"))
    refute FMutate.Pairing.copy_safe?(getprop.("broken", "exit 1"))
    refute FMutate.Pairing.copy_safe?(getprop.("garbled", "echo unknown"))
    refute FMutate.Pairing.copy_safe?(Path.join(dir, "notexec") |> tap(&File.write!(&1, "x")))
  end

  test "Allow pairs the app on this phone: plain distribution to FMutate's loopback node, its own cookie" do
    view = mount_screen(PairScreen)
    {task, view} = ask(view)

    # any app can send any name: on this phone too, the sheet says it is a claim
    assert text(view) =~ "An app on this phone says it is Humdinger"
    refute text(view) =~ "Humdinger wants to connect"
    assert text(view) =~ "this phone · on moto e"

    view = render_info(view, {:tap, {:decide, :allow}})
    assert {:ok, record} = Task.await(task)
    assert {record.dist_proto, record.host, record.dist_port} == {:inet_tcp, "127.0.0.1", 9150}
    assert record.node == "fmutate_a@127.0.0.1"
    assert %{app_name: "Humdinger", cookie: cookie} = Pairings.get(record.self_node)
    assert cookie == record.cookie
    # the screen hears of the pairing, without its cookie
    assert_receive {:pairing, {:paired, %{app_name: "Humdinger"} = paired}}, 1_000
    refute Map.has_key?(paired, :cookie)

    refute find(view, :sheet, id: "pair_request")
    assert text(view) =~ "Humdinger is paired"
    # the code is used up: the screen offers a new one
    assert text(view) =~ "This code was used"
  end

  test "Don't allow (or swiping the sheet away) refuses the app and pairs nothing" do
    view = mount_screen(PairScreen)
    {task, view} = ask(view)
    view = render_info(view, {:tap, {:decide, :deny}})
    assert Task.await(task) == {:error, :denied}
    assert Pairings.list() == []
    assert text(view) =~ "Humdinger wasn't allowed."

    view = render_info(view, {:tap, :renew})
    {task, view} = ask(view, "Magpie")
    view = render_info(view, {:dismiss, :request})
    assert Task.await(task) == {:error, :denied}
    assert Pairings.list() == []
    refute find(view, :sheet, id: "pair_request")
  end

  test "an app that hangs up while the player reads the sheet is withdrawn" do
    view = mount_screen(PairScreen)
    {task, view} = ask(view)
    Task.shutdown(task, :brutal_kill)

    assert_receive {:pairing, {:withdrawn, _ref}} = msg, 5_000
    view = render_info(view, msg)
    refute find(view, :sheet, id: "pair_request")
    assert text(view) =~ "Humdinger stopped asking."
  end

  test "five wrong codes kill the code until New code" do
    view = mount_screen(PairScreen)
    target = target(view, nil)
    wrong = if assigns(view).info.code == "AAAA-AAAA", do: "BBBBBBBB", else: "AAAAAAAA"

    results = for _ <- 1..5, do: Client.pair(target, {:code, wrong}, identity())
    assert List.last(results) == {:error, :too_many_attempts}
    assert {:error, {:wrong_code, 4}} = hd(results)

    view = render_info(view, :tick)
    assert text(view) =~ "Too many wrong codes"
    refute find(view, :canvas, id: "pair_qr")

    # the right code doesn't work any more either
    {:ok, right} = Code.normalize(assigns(view).info.code)
    assert Client.pair(target, {:code, right}, identity()) == {:error, :too_many_attempts}

    old = assigns(view).info.code
    view = render_info(view, {:tap, :renew})
    assert assigns(view).info.status == :open
    assert assigns(view).info.code != old
    assert find(view, :canvas, id: "pair_qr")
  end

  test "the right typed code pairs (SRP), and shows how many tries are left after a wrong one" do
    view = mount_screen(PairScreen)
    target = target(view, nil)
    {:ok, right} = Code.normalize(assigns(view).info.code)
    wrong = if right == "AAAAAAAA", do: "BBBBBBBB", else: "AAAAAAAA"
    assert {:error, {:wrong_code, 4}} = Client.pair(target, {:code, wrong}, identity())
    assert text(render_info(view, :tick)) =~ "4 tries left"
    me = identity()
    task = Task.async(fn -> Client.pair(target, {:code, right}, me) end)
    assert_receive {:pairing, {:request, _, _}} = msg, 5_000
    view = view |> render_info(msg) |> render_info({:tap, {:decide, :allow}})
    assert {:ok, %{fp: fp}} = Task.await(task)
    # SRP proved FMutate's certificate without the QR's fingerprint
    {:ok, link} = Link.parse(assigns(view).info.link)
    assert fp == link.fp
  end

  @tag host_opts: [ttl: 1_000]
  test "an expired code can't pair; New code makes a fresh one" do
    view = mount()
    {target, auth} = {target(view), token(view)}
    view = render_info(view, {:tap, :copy_code})
    Process.sleep(1_100)

    view = render_info(view, :tick)
    assert text(view) =~ "This code has expired"
    assert Client.pair(target, auth, identity()) == {:error, :expired}
    # the expired code is taken off the clipboard
    assert clipboard() == ""

    view = render_info(view, {:tap, :renew})
    assert text(view) =~ ~r/expires in 0:0[01]/
  end

  # the Host listens on loopback only here: 10.9.8.7 isn't this machine's
  @tag wifi: {10, 9, 8, 7}, host_opts: [ip: {127, 0, 0, 1}]
  test "Copy link copies the link to 127.0.0.1; the copied secret leaves the clipboard once spent" do
    view = mount()
    info = assigns(view).info
    assert {:ok, %{host: "10.9.8.7"}} = Link.parse(info.link)

    view = render_info(view, {:tap, :copy_link})
    assert clipboard() == info.local_link
    assert {:ok, %{host: "127.0.0.1", token: token}} = Link.parse(clipboard())
    assert {:ok, %{token: ^token}} = Link.parse(info.link)

    # New code: emptied
    view = render_info(view, {:tap, :renew})
    assert clipboard() == ""

    # used (the app proved the secret): emptied
    view = render_info(view, {:tap, :copy_code})
    assert clipboard() == assigns(view).info.code
    {task, view} = ask(view)
    assert_receive {:pairing, {:secret, :used}} = msg, 1_000
    view = render_info(view, msg)
    assert clipboard() == ""
    view = render_info(view, {:tap, {:decide, :deny}})
    assert Task.await(task) == {:error, :denied}

    # something the player copied since stays
    view = view |> render_info({:tap, :renew}) |> render_info({:tap, :copy_code})
    FakeClipboard.put(nil, "the player's own text")
    view = render_info(view, {:tap, :renew})
    assert clipboard() == "the player's own text"

    # the screen closing: emptied
    view = render_info(view, {:tap, :copy_link})
    PairScreen.terminate(:shutdown, view.socket)
    assert clipboard() == ""
  end

  test "a second app asking while the sheet shows is refused; Allow answers the app on the sheet" do
    view = mount_screen(PairScreen)
    {first, view} = ask(view, "Humdinger")

    # a new secret (the first is used up), proven by another app while the player reads the sheet
    :ok = Pairing.renew()
    view = render_info(view, :tick)
    {target, auth, magpie} = {target(view), token(view), identity("Magpie")}
    second = Task.async(fn -> Client.pair(target, auth, magpie) end)
    assert_receive {:pairing, {:request, _ref, %{app_name: "Magpie"}}} = msg, 5_000
    view = render_info(view, msg)

    assert Task.await(second, 2_000) == {:error, :denied}
    assert text(view) =~ "says it is Humdinger"
    refute text(view) =~ "says it is Magpie"

    view = render_info(view, {:tap, {:decide, :allow}})
    assert {:ok, _record} = Task.await(first)
    assert [%{app_name: "Humdinger"}] = Pairings.list()
    assert text(view) =~ "Humdinger is paired"
  end

  @tag host_opts: [ip: {127, 0, 0, 1}]
  test "a new Wi-Fi address while the screen is open: pairing moves to it with a new secret",
       context do
    view = mount()
    old = assigns(view).info
    assert old.host == "127.0.0.1"
    view = render_info(view, {:tap, :copy_code})

    Agent.update(context.addresses, fn _ -> [{~c"wlan0", [flags: [:up], addr: {10, 9, 8, 7}]}] end)

    send(Pairing, :check_front)
    view = render_info(view, :tick)

    info = assigns(view).info
    assert info.host == "10.9.8.7"
    assert info.code != old.code
    assert {:ok, %{host: "10.9.8.7"}} = Link.parse(info.link)
    assert text(view) =~ "on this Wi-Fi (10.9.8.7)"
    # the old code is gone from the clipboard, and the screen still owns pairing
    assert clipboard() == ""
    {task, _view} = ask(view)
    Task.shutdown(task, :brutal_kill)
  end

  @tag host_opts: [ip: {127, 0, 0, 1}]
  test "a new Wi-Fi address while the sheet shows: the sheet closes and the new code can be asked about",
       context do
    view = mount()
    {task, view} = ask(view)
    assert find(view, :sheet, id: "pair_request")

    Agent.update(context.addresses, fn _ -> [{~c"wlan0", [flags: [:up], addr: {10, 9, 8, 7}]}] end)

    send(Pairing, :check_front)
    assert_receive {:pairing, :restarted} = msg, 1_000
    view = render_info(view, msg)

    refute find(view, :sheet, id: "pair_request")
    assert text(view) =~ "Humdinger stopped asking."
    assert assigns(view).info.host == "10.9.8.7"
    Task.shutdown(task, :brutal_kill)

    # the new secret's request gets the sheet, not an automatic refusal
    {magpie, view} = ask(view, "Magpie")
    assert text(view) =~ "says it is Magpie"
    view = render_info(view, {:tap, {:decide, :allow}})
    assert {:ok, _record} = Task.await(magpie)
    assert [%{app_name: "Magpie"}] = Pairings.list()
    assert text(view) =~ "Magpie is paired"
  end

  @tag cert: ~s({"cert": "MIIB), paired: true
  test "a certificate file cut short is replaced by a new certificate; the old pairings are revoked",
       %{dir: dir} do
    view = mount_screen(PairScreen)
    assert find(view, :canvas, id: "pair_qr")

    path = Path.join(dir, "pair_cert.json")
    assert {:ok, %{"cert" => _, "key" => _}} = path |> File.read!() |> JSON.decode()
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    # they were paired with the old certificate
    assert Pairings.list() == []
  end

  @tag cert: :mismatched
  test "a certificate whose key isn't its own is replaced", %{dir: dir} do
    path = Path.join(dir, "pair_cert.json")
    {:ok, %{"cert" => old}} = Path.join(dir, "mismatched.json") |> File.read!() |> JSON.decode()
    view = mount_screen(PairScreen)
    assert find(view, :canvas, id: "pair_qr")

    {:ok, %{"cert" => new}} = path |> File.read!() |> JSON.decode()
    assert new != old
    {:ok, link} = Link.parse(assigns(view).info.link)
    assert link.fp == new |> Base.url_decode64!(padding: false) |> Cert.fingerprint()
  end

  @tag allowed: []
  test "the certificate's key and the cookies stay out of :sys.get_status" do
    %{cert: %{key: key}} = :sys.get_state(Pairing)
    status = :sys.get_status(Pairing) |> inspect(limit: :infinity, printable_limit: :infinity)
    refute status =~ inspect(key, limit: :infinity)

    cookie = File.read!(Path.join(FMutate.Paths.dist_dir(), "sibling_cookie"))
    assert byte_size(cookie) == 64
    refute :sys.get_status(Dist) |> inspect(limit: :infinity) =~ cookie
  end

  @tag allowed: []
  test "I/O's Allow asks MobPair.Pairings: a name paired a moment ago doesn't get the sibling cookie" do
    # FMutate.Dist hasn't heard of the pairing yet: it follows the registry that was running at its start
    stop_supervised!(Pairings)
    start_supervised!({Pairings, default_cookie: :keep, allow_list: false})
    node = :"humdinger_race@127.0.0.1"
    register(node)
    assert %{apps: [%{node: ^node, state: :pending}]} = Dist.info()

    {:ok, _} = Pairings.add(pairing(Atom.to_string(node)))
    assert Dist.allow(node) == {:error, :paired}
    assert %{apps: [%{node: ^node, state: :pending}]} = Dist.info()
  end

  @tag cert: :unreadable
  test "a certificate that can't be read turns pairing off without stopping FMutate" do
    assert Pairing.open() == {:error, {:certificate, :eacces}}
    view = mount_screen(PairScreen)
    assert text(view) =~ "FMutate's pairing certificate can't be read."
    refute find(view, :canvas, id: "pair_qr")
  end

  @tag allowed: ["voice@127.0.0.1"]
  test "a name a sibling-cookie app has can't be paired; a merely pending one can" do
    view = mount_screen(PairScreen)
    voice = %{identity("Voice") | node: "voice@127.0.0.1"}
    assert Client.pair(target(view), token(view), voice) == {:error, :bad_node}
    refute_received {:pairing, {:request, _, _}}

    # a registered name (no cookie needed) is pending, not claimed
    view = render_info(view, {:tap, :renew})
    me = identity()
    register(String.to_atom(me.node))
    task = Task.async(fn -> Client.pair(target(view), token(view), me) end)
    assert_receive {:pairing, {:request, _ref, %{app_name: "Humdinger"}}}, 5_000
    Task.shutdown(task, :brutal_kill)

    # a name never seen is no claim, and asking makes no atom of it
    name = "never_seen_#{System.unique_integer([:positive])}@127.0.0.1"
    refute Dist.claimed?(name)
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end
end
