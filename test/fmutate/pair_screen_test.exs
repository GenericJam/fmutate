defmodule FMutate.PairScreenTest do
  # The Pair screen against a real pairing endpoint (FMutate.Pairing → MobPair.Host on loopback) and a real
  # joining client (MobPair.Client, as Humdinger runs it): what the player sees and what each answer does.
  use Mob.ScreenCase, async: false

  alias FMutate.{Pairing, PairScreen}
  alias MobPair.{Cert, Client, Code, Link, Pairings, Transport}

  @moduletag :capture_log

  setup context do
    dir = Path.join(System.tmp_dir!(), "fmutate_pair_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    start_supervised!({Pairings, default_cookie: :keep, allow_list: false})

    start_supervised!(
      {Pairing,
       dir: dir,
       addresses: fn -> [] end,
       advertise: false,
       node: :"fmutate_a@127.0.0.1",
       dist_port: 9150,
       host_opts: Map.get(context, :host_opts, [])}
    )

    %{dir: dir}
  end

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
    assert_renderable(view)
  end

  test "Allow pairs the app on this phone: plain distribution to FMutate's loopback node, its own cookie" do
    view = mount_screen(PairScreen)
    {task, view} = ask(view)

    assert text(view) =~ "Humdinger wants to connect"
    assert text(view) =~ "this phone · on moto e"

    view = render_info(view, {:tap, {:decide, :allow}})
    assert {:ok, record} = Task.await(task)
    assert {record.dist_proto, record.host, record.dist_port} == {:inet_tcp, "127.0.0.1", 9150}
    assert record.node == "fmutate_a@127.0.0.1"
    assert %{app_name: "Humdinger", cookie: cookie} = Pairings.get(record.self_node)
    assert cookie == record.cookie
    assert_receive {:pairing, {:paired, %{app_name: "Humdinger"}}}, 1_000

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
    view = mount_screen(PairScreen)
    {target, auth} = {target(view), token(view)}
    Process.sleep(1_100)

    view = render_info(view, :tick)
    assert text(view) =~ "This code has expired"
    assert Client.pair(target, auth, identity()) == {:error, :expired}

    view = render_info(view, {:tap, :renew})
    assert text(view) =~ ~r/expires in 0:0[01]/
  end
end
