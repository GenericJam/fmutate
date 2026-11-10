# Evaluate Elixir on the running app on a device and print the result (development tool).
#
#   mix run --no-start tools/rpc.exs emulator-5554 'FMutate.Instance.state("a")'
#   mix run --no-start tools/rpc.exs ZY22DP6HFL 'Node.self()'
#
# Attaches without restarting the app (MobDev.Connector, restart: false), then evaluates the
# expression on the device node with Code.eval_string.
[serial, expr] =
  case System.argv() do
    [s, e] -> [s, e]
    _ -> raise "usage: mix run --no-start tools/rpc.exs <adb serial> '<elixir expression>'"
  end

Mix.Task.run("app.config")

{connected, _failed} =
  ExUnit.CaptureIO.with_io(fn ->
    MobDev.Connector.connect_all(platforms: [:android], only: [serial], restart: false)
  end)
  |> elem(0)

case connected do
  [%{node: node} | _] ->
    case :rpc.call(node, Code, :eval_string, [expr], 30_000) do
      {:badrpc, reason} -> IO.puts(:stderr, "badrpc: #{inspect(reason)}") && System.halt(1)
      {value, _binding} -> IO.puts(inspect(value, pretty: true, limit: :infinity, printable_limit: 4096))
    end

  [] ->
    IO.puts(:stderr, "no connected node for #{serial}")
    System.halt(1)
end
