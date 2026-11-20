# A sibling app's side of protocol.md, run from the computer against FMutate on a device (development tool).
#
#   mise exec -- elixir tools/sibling_probe.exs <adb serial> <sibling cookie> [seconds to hold the key]
#
# Get the cookie the way a sibling does, from FMutate's signature-protected provider (the probe app in
# tools/android_probe, signed with the same key), and register the probe's node name there first (FMutate
# refuses a name nobody registered before it reads it, protocol.md §7):
#
#   adb -s <serial> shell am start -n com.genericjam.fmutate.probe/.ProbeActivity --es do cookie
#   adb -s <serial> shell am start -n com.genericjam.fmutate.probe/.ProbeActivity --es do register \
#     --es node fmutate_probe@127.0.0.1
#   adb -s <serial> logcat -d -s FMutateProbe
#
# It uses nothing from this project, only OTP, configured as protocol.md says (no EPMD, fixed port, a
# hidden node that only connects out). It retries until the player taps Allow on FMutate's I/O screen,
# subscribes to status and LEDs, holds key 7 down and lets go, prints what comes back, then waits for the
# player's Disconnect and checks that it can't get back in.
[serial, cookie | rest] = System.argv()
hold_s = case rest, do: ([s] -> String.to_integer(s); [] -> 4)

target = :"fmutate_a@127.0.0.1"
{out, 0} = System.cmd("adb", ["-s", serial, "forward", "tcp:0", "tcp:9150"])
port = out |> String.trim() |> String.to_integer()
say = fn msg -> IO.puts("[#{Time.utc_now() |> Time.truncate(:millisecond)}] #{msg}") end

:ok = :application.set_env(:kernel, :erl_epmd_node_listen_port, port)
{:ok, _} = :net_kernel.start(:"fmutate_probe@127.0.0.1", %{name_domain: :longnames, dist_listen: false})
Node.set_cookie(target, String.to_atom(cookie))
say.("#{Node.self()} → #{target} (device 127.0.0.1:9150 via host port #{port})")

knock = fn knock, n ->
  if Node.connect(target) do
    n
  else
    if n == 0, do: say.("refused: waiting for Allow on FMutate's I/O screen (retrying every second)")
    Process.sleep(1_000)
    knock.(knock, n + 1)
  end
end

attempts = knock.(knock, 0)
say.("connected after #{attempts} refused attempt(s)")
Node.monitor(target, true)

fmutate = {:fmutate_instance, target}
:ok = GenServer.call(fmutate, {:fmutate, 1, "a", {:subscribe, self(), [:status, :leds, :screen]}})
say.("subscribed to status, leds, screen")
say.("list_firmware: #{inspect(GenServer.call(fmutate, {:fmutate, 1, "a", {:list_firmware}}))}")
say.("wrong instance: #{inspect(GenServer.call(fmutate, {:fmutate, 1, "b", {:list_firmware}}))}")

drain = fn drain, acc, until ->
  left = until - System.monotonic_time(:millisecond)

  receive do
    {:status, s} -> say.("event {:status, #{inspect(s)}}") && drain.(drain, acc, until)
    {:leds, keys, _buttons} -> say.("event {:leds, keys=0x#{Integer.to_string(keys, 16)}, ...}") && drain.(drain, acc, until)
    {:screen, seq, frame} -> drain.(drain, Map.update(acc, :frames, {1, seq, byte_size(frame)}, fn {n, _, b} -> {n + 1, seq, b} end), until)
    {:nodedown, ^target} -> Map.put(acc, :nodedown, true)
  after
    max(left, 0) -> acc
  end
end

send(fmutate, {:fmutate, 1, "a", {:key, 7, :down, 100}})
say.("sent {:key, 7, :down, 100}; holding #{hold_s} s")
acc = drain.(drain, %{}, System.monotonic_time(:millisecond) + hold_s * 1_000)
send(fmutate, {:fmutate, 1, "a", {:key, 7, :up}})
say.("sent {:key, 7, :up}")
acc = drain.(drain, acc, System.monotonic_time(:millisecond) + 1_000)

case acc[:frames] do
  {n, seq, bytes} -> say.("screen: #{n} frames, last seq #{seq}, #{bytes} bytes each")
  nil -> say.("screen: no frames")
end

say.("now tap Disconnect on FMutate's I/O screen")
acc = if acc[:nodedown], do: acc, else: drain.(drain, %{}, System.monotonic_time(:millisecond) + 120_000)

if acc[:nodedown] do
  say.("nodedown: FMutate cut the connection")
  back = for _ <- 1..3, do: Node.connect(target) && Process.sleep(500)
  say.("reconnect attempts after Disconnect: #{inspect(back)}")
else
  say.("no Disconnect within 2 minutes")
end

System.cmd("adb", ["-s", serial, "forward", "--remove", "tcp:#{port}"])
