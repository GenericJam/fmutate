# Evaluate Elixir on the running app on a device and print the result (development tool).
#
#   mix run --no-start tools/rpc.exs emulator-5554 'FMutate.Instance.view("a")'
#   mix run --no-start tools/rpc.exs ZY22DP6HFL 'Node.self()'
#   mix run --no-start tools/rpc.exs 00008110-001E1C3A34F8401E 'FMutate.Audio.stats()'
#
# Android: the app is the distribution node fmutate_a@127.0.0.1 on the device's 127.0.0.1:9150 (FMutate.Dist,
# no EPMD). This forwards a free host port to it (adb forward), starts a hidden host node that only connects out
# (dist_listen false) and finds the app's node at that port, and uses the development cookie mob_dev deployed
# with the app (builds deployed by mob_dev accept it as a dev tool). Several of these can run at once against
# different devices.
#
# A physical iPhone (its UDID): the BEAM already runs as Mob's development node (FMutate.Dist can't start a
# second one), fmutate_app_ios@<host> on the phone's port 9101. The Mac reaches it through usbmuxd (`iproxy`,
# libimobiledevice), which needs the node named for 127.0.0.1: start the app with
#   xcrun devicectl device process launch --device <udid> --terminate-existing \
#     --environment-variables '{"MOB_NODE_HOST":"127.0.0.1"}' com.genericjam.fmutate
[serial, expr] =
  case System.argv() do
    [s, e] ->
      [s, e]

    _ ->
      raise "usage: mix run --no-start tools/rpc.exs <adb serial | iPhone udid> '<elixir expression>'"
  end

Mix.Task.run("app.config")

iphone? = String.match?(serial, ~r/^[0-9A-F]{8}-[0-9A-F]{16}$/)

free_port = fn ->
  {:ok, s} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
  {:ok, port} = :inet.port(s)
  :gen_tcp.close(s)
  port
end

{target, host_port, undo} =
  if iphone? do
    port = free_port.()

    iproxy =
      Port.open(
        {:spawn_executable, System.find_executable("iproxy")},
        [:binary, args: ["#{port}:9101", "-u", serial]]
      )

    {:os_pid, iproxy_pid} = Port.info(iproxy, :os_pid)
    Process.sleep(500)

    {:"fmutate_app_ios@127.0.0.1", port,
     fn -> System.cmd("kill", [Integer.to_string(iproxy_pid)]) end}
  else
    instance = "a"

    {out, 0} =
      System.cmd("adb", ["-s", serial, "forward", "tcp:0", "tcp:#{FMutate.Dist.port(instance)}"])

    port = out |> String.trim() |> String.to_integer()

    {FMutate.Dist.node_name(instance), port,
     fn -> System.cmd("adb", ["-s", serial, "forward", "--remove", "tcp:#{port}"]) end}
  end

result =
  try do
    :ok = :application.set_env(:kernel, :erl_epmd_node_listen_port, host_port)
    name = :"rpc_#{System.unique_integer([:positive])}@127.0.0.1"
    {:ok, _} = :net_kernel.start(name, %{name_domain: :longnames, dist_listen: false})
    Node.set_cookie(target, MobDev.DistCookie.for_project!())

    if Node.connect(target) do
      :rpc.call(target, Code, :eval_string, [expr], 30_000)
    else
      {:badrpc, :cannot_connect}
    end
  after
    undo.()
  end

case result do
  {:badrpc, :cannot_connect} ->
    IO.puts(
      :stderr,
      "cannot connect to #{target} on #{serial} (is the app running? deployed with mix mob.deploy?)"
    )

    System.halt(1)

  {:badrpc, reason} ->
    IO.puts(:stderr, "badrpc: #{inspect(reason)}")
    System.halt(1)

  {value, _binding} ->
    IO.puts(inspect(value, pretty: true, limit: :infinity, printable_limit: 4096))
end

System.halt(0)
