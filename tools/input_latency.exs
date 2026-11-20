# Input → sound in the mixer, on the running app (development tool). An expression for tools/rpc.exs:
#
#   mix run --no-start tools/rpc.exs <device> "$(cat tools/input_latency.exs)"
#
# Per note: the time from FMutate.Instance.input (key down) until the mixer's peak passes 1000, polled straight
# from the audio NIF (its peak since the last call) in a loop, and the engine's ring fill just before (44.1 kHz
# frames). Not FMutate.Audio.stats/0: that is a snapshot taken every 100 ms, and polling it adds up to 100 ms.
# 12 notes 400 ms apart, then two after 2 s and 3 s of silence. The sound reaches the speaker after the output
# latency on top (Audio.stats().latency_ms).
us = fn -> System.monotonic_time(:microsecond) end

quiet = fn quiet, ms ->
  Process.sleep(ms)
  if FMutate.AudioNif.stats().peak > 200, do: quiet.(quiet, 200), else: :ok
end

trial = fn k, pause ->
  quiet.(quiet, pause)
  fill = hd(FMutate.AudioNif.stats().fills)
  t0 = us.()
  FMutate.Instance.input("a", {:key, k, :down})

  wait = fn wait ->
    cond do
      FMutate.AudioNif.stats().peak > 1000 -> us.()
      us.() - t0 > 500_000 -> nil
      true -> :erlang.yield() && wait.(wait)
    end
  end

  t1 = wait.(wait)
  Process.sleep(150)
  FMutate.Instance.input("a", {:key, k, :up})
  {pause, fill, t1 && Float.round((t1 - t0) / 1000, 1)}
end

for(i <- 1..12, do: trial.(rem(i * 5, 20) + 3, 400)) ++ for(p <- [2000, 3000], do: trial.(10, p))
