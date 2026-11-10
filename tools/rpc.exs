# Evaluate Elixir on the running app on a device and print the result (development tool).
#
#   mix run --no-start tools/rpc.exs emulator-5554 'FMutate.Instance.view("a")'
#   mix run --no-start tools/rpc.exs ZY22DP6HFL 'Node.self()'
#
# The app is the distribution node fmutate_a@127.0.0.1 on the device's 127.0.0.1:9150 (FMutate.Dist, no
# EPMD). This forwards a free host port to it, starts a hidden host node that only connects out
# (dist_listen false) and finds the app's node at that port, and uses the development cookie mob_dev
# deployed with the app (builds deployed by mob_dev accept it as a dev tool). Several of these can run at
# once against different devices.
[serial, expr] =
  case System.argv() do
    [s, e] -> [s, e]
    _ -> raise "usage: mix run --no-start tools/rpc.exs <adb serial> '<elixir expression>'"
  end

Mix.Task.run("app.config")

instance = "a"
target = FMutate.Dist.node_name(instance)

{out, 0} = System.cmd("adb", ["-s", serial, "forward", "tcp:0", "tcp:#{FMutate.Dist.port(instance)}"])
host_port = out |> String.trim() |> String.to_integer()

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
    System.cmd("adb", ["-s", serial, "forward", "--remove", "tcp:#{host_port}"])
  end

case result do
  {:badrpc, :cannot_connect} ->
    IO.puts(:stderr, "cannot connect to #{target} on #{serial} (is the app running? deployed with mix mob.deploy?)")
    System.halt(1)

  {:badrpc, reason} ->
    IO.puts(:stderr, "badrpc: #{inspect(reason)}")
    System.halt(1)

  {value, _binding} ->
    IO.puts(inspect(value, pretty: true, limit: :infinity, printable_limit: 4096))
end
