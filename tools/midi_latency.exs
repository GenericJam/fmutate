# Measures how long a MIDI note takes from another app to the firmware engine's Port (development tool):
#
#   mise exec -- mix run --no-start tools/midi_latency.exs <adb serial> [notes]
#
# Needs the probe app (tools/android_probe) on the device. The probe plays `notes` short notes into the
# "FMutate A" virtual port, each stamped with System.nanoTime(); on the device this traces the FMutate.MIDI
# process receiving each message (which carries the sender's and Kotlin's stamps) and the engine process's
# port_command for the key, and reports per hop (CLOCK_MONOTONIC throughout; BEAM trace timestamps are
# moved onto it with an offset taken at the start):
#
#   sender → Kotlin   Android's MIDI service delivering into FMutateMidiService
#   Kotlin → BEAM     JNI + enif_send to FMutate.MIDI's mailbox
#   BEAM → Port       FMutate.MIDI → FMutate.Instance → FMutate.Engine → port_command (write to the engine's stdin)
[serial | rest] = System.argv()
notes = case rest, do: ([n] -> String.to_integer(n); [] -> 40)

Mix.Task.run("app.config")
target = FMutate.Dist.node_name("a")
{out, 0} = System.cmd("adb", ["-s", serial, "forward", "tcp:0", "tcp:#{FMutate.Dist.port("a")}"])
host_port = out |> String.trim() |> String.to_integer()
:ok = :application.set_env(:kernel, :erl_epmd_node_listen_port, host_port)
{:ok, _} = :net_kernel.start(:"latency_#{System.unique_integer([:positive])}@127.0.0.1", %{name_domain: :longnames, dist_listen: false})
Node.set_cookie(target, MobDev.DistCookie.for_project!())
true = Node.connect(target)

duration_ms = notes * 200 + 3_000

device = """
midi = GenServer.whereis(FMutate.MIDI.via("a"))
%{live: %{pid: eng}} = :sys.get_state(FMutate.Instance.via("a"))
offset = FMutate.IONif.now_ns() - :erlang.monotonic_time(:nanosecond)
me = self()
collect = fn collect, acc ->
  receive do
    :stop -> send(me, {:events, Enum.reverse(acc)})
    ev -> collect.(collect, [ev | acc])
  end
end
tracer = spawn(fn -> collect.(collect, []) end)
:erlang.trace_pattern({:erlang, :port_command, :_}, true, [:global])
:erlang.trace(midi, true, [:receive, :monotonic_timestamp, {:tracer, tracer}])
:erlang.trace(eng, true, [:call, :monotonic_timestamp, {:tracer, tracer}])
Process.sleep(#{duration_ms})
:erlang.trace(midi, false, [:all])
:erlang.trace(eng, false, [:all])
:erlang.trace_pattern({:erlang, :port_command, :_}, false, [:global])
send(tracer, :stop)
events = receive do {:events, e} -> e after 5_000 -> [] end
ins = for {:trace_ts, _, :receive, {:fm1io, :midi, _src, <<0x90, n, v>>, sent, recv}, ts} <- events, v > 0, do: {n - 53, sent, recv, ts + offset}
outs = for {:trace_ts, _, :call, {:erlang, :port_command, [_port, <<1, k, 1>> | _]}, ts} <- events, do: {k, ts + offset}
{rows, _} =
  Enum.map_reduce(ins, outs, fn {k, sent, recv, beam}, outs ->
    case Enum.split_while(outs, fn {kk, t} -> kk != k or t < beam end) do
      {_, [{^k, port} | rest]} -> {{recv - sent, beam - recv, port - beam, port - sent}, rest}
      _ -> {nil, outs}
    end
  end)
Enum.reject(rows, &is_nil/1)
"""

task = Task.async(fn -> :rpc.call(target, Code, :eval_string, [device], duration_ms + 20_000) end)
Process.sleep(1_000)

System.cmd("adb", ["-s", serial, "shell", "am", "start", "-n", "com.genericjam.fmutate.probe/.ProbeActivity",
  "--es", "do", "notes", "--ei", "note", "60", "--ei", "count", "#{notes}", "--ei", "hold", "100", "--ei", "gap", "100"])

{rows, _} = Task.await(task, duration_ms + 30_000)
System.cmd("adb", ["-s", serial, "forward", "--remove", "tcp:#{host_port}"])

summary = fn values ->
  s = values |> Enum.map(&(&1 / 1.0e6)) |> Enum.sort()
  n = length(s)
  q = fn p -> Enum.at(s, min(n - 1, trunc(p * n))) |> Float.round(3) end
  "min #{q.(0.0)}  median #{q.(0.5)}  p90 #{q.(0.9)}  max #{Float.round(List.last(s), 3)} ms"
end

if rows == [] do
  IO.puts("no notes matched (is the probe app installed?)")
else
  {a, b, c, d} = rows |> Enum.map(&Tuple.to_list/1) |> Enum.zip() |> List.to_tuple()
  IO.puts("#{length(rows)} notes")
  IO.puts("sender → Kotlin   #{summary.(Tuple.to_list(a))}")
  IO.puts("Kotlin → BEAM     #{summary.(Tuple.to_list(b))}")
  IO.puts("BEAM → Port       #{summary.(Tuple.to_list(c))}")
  IO.puts("total             #{summary.(Tuple.to_list(d))}")
end
