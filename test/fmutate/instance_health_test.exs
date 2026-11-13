defmodule FMutate.Instance.HealthTest do
  use ExUnit.Case, async: true

  alias FMutate.Instance.Health

  # one window of `pct` % speed (1 s of wall time) after the clock started at {0, 0}
  defp window(%{clock: {w0, f0}} = h, pct), do: Health.status(h, w0 + 1_000, f0 + pct * 10)

  defp windows(h, pcts), do: Enum.reduce(pcts, h, fn pct, h -> h |> window(pct) |> elem(0) end)

  # `cpu`: nil for a native engine, else what was kept for the firmware (Health.memory/1)
  defp started(buffer \\ :auto, default \\ 1024, cpu \\ nil) do
    {h, :none} =
      Health.status(Health.new(buffer, default, Health.start_fill(buffer, default), cpu), 0, 0)

    # past the warm-up (two windows), and one judged window
    windows(h, [100, 100, 100])
  end

  describe "speed" do
    test "the warm-up windows judge nothing" do
      {h, :none} = Health.status(Health.new(:auto, 1024, 1024), 0, 0)
      h = windows(h, [10, 10])
      assert h.pct == nil and h.slow == false
    end

    test "only windows of a second count" do
      h = started()
      {h, :none} = Health.status(h, h.clock |> elem(0) |> Kernel.+(900), 0)
      assert {_, :window} = window(h, 100)
    end

    test "too slow after three windows in a row below 95 %, not before" do
      h = started() |> windows([80, 80])
      assert h.pct == 80
      refute h.slow
      # a good window in between starts the count again
      h = h |> windows([100, 80, 80])
      refute h.slow
      h = windows(h, [80])
      assert h.slow
    end

    test "hysteresis: stays slow between 95 and 98 %, clears after three windows at 98 % or more" do
      h = started() |> windows([80, 80, 80])
      assert h.slow
      h = windows(h, [96, 97, 96, 97])
      assert h.slow
      h = windows(h, [99, 99])
      assert h.slow
      h = windows(h, [96, 99, 99])
      assert h.slow
      h = windows(h, [99])
      refute h.slow
    end

    test "the speed shown moves only by 2 points or more" do
      h = started() |> windows([80])
      assert h.pct == 80
      assert windows(h, [81]).pct == 80
      assert windows(h, [82]).pct == 82
      assert windows(h, [78]).pct == 78
    end

    test "a pause forgets the clock: the stall isn't counted as slow" do
      h = started() |> windows([80, 80]) |> Health.pause()
      {h, :none} = Health.status(h, 50_000, 7)
      assert {h, :window} = Health.status(h, 51_000, 1_007)
      assert h.pct == 100 and not h.slow
    end
  end

  describe "auto fill" do
    # windows at wall `t`, `t + 1000`, … with the underrun counts given
    defp counts(h, t, list) do
      Enum.reduce(list, {h, t, []}, fn n, {h, t, fills} ->
        {h, fill} = Health.underruns(h, t, n)
        {h, t + 1_000, if(fill, do: [fill | fills], else: fills)}
      end)
      |> then(fn {h, t, fills} -> {h, t, Enum.reverse(fills)} end)
    end

    test "one step up when underruns grow in 2 of 5 windows; a single glitch doesn't" do
      h = started()
      {h, t, []} = counts(h, 10_000, [0, 3, 3, 3, 3, 3])
      assert h.fill == 1024
      {h, _t, fills} = counts(h, t, [5, 5, 6])
      assert fills == [1536]
      assert h.fill == 1536
    end

    test "steps up to the engine's limit and no further" do
      h = started()
      {h, _t, fills} = counts(h, 10_000, Enum.to_list(0..40))
      {_step, max} = Health.limits()
      assert List.last(fills) == max
      assert fills == Enum.uniq(fills)
      assert h.fill == max
      assert Enum.all?(fills, &(&1 <= max))
    end

    test "settles back towards the default after a minute without underruns" do
      h = started()
      {h, t, [1536, 2048]} = counts(h, 10_000, [0, 1, 2, 3, 4])
      {h, t, fills} = counts(h, t, List.duplicate(4, 60))
      assert fills == [1536]
      {h, _t, fills} = counts(h, t, List.duplicate(4, 120))
      assert fills == [1024]
      assert h.fill == 1024
    end

    test "a step down that brings underruns back is undone and becomes the floor" do
      h = started()
      {h, t, [1536, 2048]} = counts(h, 10_000, [0, 1, 2, 3, 4])
      {h, t, [1536]} = counts(h, t, List.duplicate(4, 60))
      {h, t, [2048]} = counts(h, t, [5, 6])
      assert h.floor == 2048
      {h, _t, []} = counts(h, t, List.duplicate(6, 300))
      assert h.fill == 2048
    end

    test "a fixed buffer is used as is" do
      h = started(3072)
      assert h.fill == 3072
      {h, _t, []} = counts(h, 10_000, Enum.to_list(0..20))
      assert h.fill == 3072
    end

    test "underruns in the warm-up windows don't count" do
      {h, :none} = Health.status(Health.new(:auto, 1024, 1024), 0, 0)
      {h, :window} = window(h, 100)
      {h, nil} = Health.underruns(h, 1_000, 5)
      {h, :window} = window(h, 100)
      {h, nil} = Health.underruns(h, 2_000, 9)
      {h, :window} = window(h, 100)
      assert {_h, nil} = Health.underruns(h, 3_000, 9)
    end

    test "start fill: fixed as chosen, auto from the default or what the last engine learnt, clamped" do
      assert Health.start_fill(3072, 1024) == 3072
      assert Health.start_fill(:auto, 1024) == 1024
      assert Health.start_fill(:auto, 1024, 2560) == 2560
      assert Health.start_fill(:auto, 2048, 1024) == 2048
      assert Health.start_fill(99_999, 1024) == 3840
      assert Health.start_fill(:auto, 100) == 512
    end

    test "choosing a buffer sets it now; back to auto starts from the default" do
      h = started()
      {h, 3072} = Health.buffer(h, 3072)
      assert h.fill == 3072
      {h, 1024} = Health.buffer(h, :auto)
      assert h.fill == 1024 and h.buffer == :auto
    end
  end

  describe "emulated CPU clock" do
    # emulator engine windows, each `{pct, stale halves in it, the engine's CPU %}`: the health and the clocks set
    defp emu_windows(h, list) do
      Enum.reduce(list, {h, []}, fn {pct, stale, busy}, {h, set} ->
        {h, :window} = window(h, pct)
        {wall, _} = h.clock
        c = h.cpu
        {h, mhz} = Health.cpu(h, wall, (c.stale || 0) + stale, (c.cpu_ms || 0) + busy * 10)
        {h, if(mhz, do: set ++ [mhz], else: set)}
      end)
    end

    defp slow(n), do: List.duplicate({80, 0, 100}, n)
    defp fine(n, busy), do: List.duplicate({100, 0, busy}, n)

    test "too slow: one step down at a time, each judged anew, down to 80 MHz and no further" do
      h = started(:auto, 1024, %{})
      assert Health.cpu_mhz(h) == 240
      {h1, [180]} = emu_windows(h, slow(5))
      assert h1.slow
      assert Health.advice(h1) == :lowering

      {h, set} = emu_windows(h, slow(40))
      assert set == [180, 120, 80]
      assert Health.cpu_mhz(h) == 80
      assert Health.advice(h) == :limit
    end

    test "an engine that keeps up keeps its clock" do
      {h, []} = emu_windows(started(:auto, 1024, %{}), fine(200, 90))
      assert Health.cpu_mhz(h) == 240
      assert Health.advice(h) == nil
    end

    test "the clock that keeps up is kept for the firmware; the next engine starts there" do
      {h, _} = emu_windows(started(:auto, 1024, %{}), slow(8) ++ fine(10, 50))
      assert Health.cpu_mhz(h) == 120
      mem = Health.memory(h)
      assert mem == %{mode: :auto, mhz: 120, min: 80}
      assert Health.cpu_mhz(Health.new(:auto, 1024, 1024, mem)) == 120
      # (never below what the firmware was found to need)
      assert Health.cpu_mhz(Health.new(:auto, 1024, 1024, %{mhz: 80, min: 180})) == 180
      assert Health.memory(started()) == nil
    end

    test "the firmware's own audio starving: one step back up, and the firmware's floor from then on" do
      h = started(:auto, 1024, %{mhz: 120})
      assert Health.cpu_mhz(h) == 120
      # (one stale half is no pattern)
      {h, []} = emu_windows(h, [{100, 1, 40}, {100, 0, 40}])
      {h, [180]} = emu_windows(h, [{100, 5, 40}])
      assert Health.memory(h).min == 180

      # too slow at the clock it needs: nothing left to lower, said honestly
      {h, []} = emu_windows(h, slow(20))
      assert Health.cpu_mhz(h) == 180
      assert h.slow
      assert Health.advice(h) == :limit
    end

    test "after a minute with room to spare, one step up is tried; a try that is too slow is undone for good" do
      h = started(:auto, 1024, %{mhz: 120})
      # (no room: 60 % at 120 MHz would be 90 % at 180)
      {h, []} = emu_windows(h, fine(70, 60))
      {h, [180]} = emu_windows(h, fine(1, 30))

      {h, [120]} = emu_windows(h, slow(5))
      {h, []} = emu_windows(h, fine(300, 10))
      assert Health.cpu_mhz(h) == 120
    end

    test "a fixed clock is used as is; too slow says what the player can still do" do
      h = started(:auto, 1024, %{})
      {h, 120} = Health.cpu_mode(h, 120)
      {h, []} = emu_windows(h, slow(20))
      assert Health.cpu_mhz(h) == 120
      assert Health.advice(h) == :lower_in_io

      {h, 80} = Health.cpu_mode(h, 80)
      assert Health.advice(h) == :limit
      assert Health.memory(h) == %{mode: 80, mhz: 80, min: 80}

      # (back to auto: from the clock now)
      {h, 80} = Health.cpu_mode(h, :auto)
      assert Health.memory(h).mode == :auto
    end

    test "a native engine has no clock: too slow is the phone's limit" do
      h = started() |> windows([80, 80, 80])
      assert Health.cpu_mhz(h) == nil
      assert {^h, nil} = Health.cpu(h, 99_000, 5, 500)
      assert Health.advice(h) == :limit
    end
  end

  describe "buffer advice" do
    test "auto fill holds while the engine is too slow: more fill would only play later" do
      h = started() |> windows([80, 80, 80])
      assert h.slow
      {h, _t, []} = counts(h, 10_000, Enum.to_list(0..20))
      assert h.fill == 1024
    end

    test "raise the buffer only for a fast enough engine underrunning on a fixed buffer below the largest" do
      {h, _t, []} = counts(started(2048), 10_000, [0, 1, 2])
      assert Health.advice(h) == :raise_buffer
      {h, _t, []} = counts(started(3840), 10_000, [0, 1, 2])
      assert Health.advice(h) == nil
      {h, _t, _} = counts(started(), 10_000, [0, 1, 2])
      assert Health.advice(h) == nil
    end
  end
end
