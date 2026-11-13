defmodule FMutate.Instance.Health do
  @moduledoc """
  How well the running engine keeps up (pure; `FMutate.Instance` owns one per live engine).

  **Speed** (`pct`): firmware ms per wall ms over windows of at least 1000 ms, from the engine's STATUS
  (`ms`, every 100 ms). The reported value is a whole percent and only moves when the measurement moves 2
  points or more, so the instance view (and the screens re-rendering on it) stay still while it jitters.

  **Too slow** (`slow`): on after 3 windows in a row below 95 %, off after 3 in a row at 98 % or more
  (hysteresis: an engine hovering around 95 % doesn't flicker). The first 2 windows after READY are
  warm-up (an emulated firmware compiles itself while it boots) and judge nothing.

  **Engine fill** (`fill`, frames queued ahead of the mixer, `docs/engine_protocol.md` op `0x07`). With the
  buffer on `:auto`: when the slot's underruns grew in 2 of the last 5 windows, one step of 512
  frames up (to 3840, the engine's limit), then the next 5 windows judge again. After 60 s without
  an underrun, one step back down towards the computed default (`FMutate.Audio.engine_fill/0`); a step down
  that brings underruns back within those 60 s is undone and becomes the floor for this engine. A fixed
  buffer is used as is. More fill only absorbs jitter: an engine slower than real time underruns at any
  fill, so the fill doesn't climb while the engine is too slow.

  **Emulated CPU clock** (`cpu`, the emulator engine only; op `0x08`). fm1-emu emulates the FM-1's CPU at
  240 MHz, and many firmwares spend those cycles waiting; at a lower clock the firmware gets fewer
  instructions per second of its time (its clock, timers and audio stay right) and costs the phone less.
  On `:auto`, an engine too slow for 3 windows in a row steps down 240 → 180 → 120 → 80 MHz, one
  step each time, never below 80 or the lowest clock this firmware was found to need (`min`). A firmware
  whose own audio starves (2 or more DMA halves it didn't write in time in a window: the engine's `stale`)
  is below the clock it needs: one step back up, which becomes its `min`. After 60 s on a lowered clock,
  not too slow and with the engine's CPU time predicting that one step up would take at most 70 % of a core,
  one step up is tried; a tried step that turns out too slow is undone and stays this engine's ceiling.
  Each change waits 2 windows before the next judgement. A fixed clock (the I/O screen's choice) is used as
  is. `memory/1` is what to keep per firmware, `new/4` starts from it.
  """

  @window_ms 1_000
  @slow_below 95
  @fast_from 98
  @slow_windows 3
  @warmup_windows 2
  @deadband 2
  @step 512
  @max_fill 3840
  @min_fill 512
  @climb_windows 2
  @climb_span 5
  @quiet_ms 60_000

  @clocks [240, 180, 120, 80]
  @full_mhz 240
  @floor_mhz 80
  @settle_windows 2
  @starve_halves 2
  @probe_after_ms 60_000
  @probe_busy 70

  defstruct clock: nil,
            windows: 0,
            pct: nil,
            slow: false,
            below: 0,
            above: 0,
            buffer: :auto,
            default: 1024,
            fill: 1024,
            floor: 1024,
            underruns: nil,
            recent: [],
            quiet_since: nil,
            lowered_at: nil,
            cpu: nil

  @type buffer :: :auto | pos_integer
  @type cpu_mode :: :auto | pos_integer
  @typedoc "What `FMutate.Instance` keeps per firmware: the clock mode, the clock last set, the lowest it needs."
  @type memory :: %{mode: cpu_mode, mhz: pos_integer, min: pos_integer}
  @type t :: %__MODULE__{}

  @doc "Fill steps and limits: `{step, max}` frames."
  def limits, do: {@step, @max_fill}

  @doc "The fixed buffers the I/O screen offers (frames)."
  def fixed_buffers, do: [2048, 3072, @max_fill]

  @doc "The emulated CPU clocks auto steps through and the I/O screen offers (MHz), fastest first."
  def clocks, do: @clocks

  @doc "The fill an engine starts with: a fixed buffer, else `current` (the auto fill so far) or the default."
  @spec start_fill(buffer, pos_integer, pos_integer | nil) :: pos_integer
  def start_fill(buffer, default, current \\ nil)
  def start_fill(n, _default, _current) when is_integer(n), do: clamp(n)
  def start_fill(:auto, default, nil), do: clamp(default)
  def start_fill(:auto, default, current), do: clamp(max(default, current))

  @doc """
  A health for an engine that just became READY with `fill`. `cpu`: nil for a native engine; for the emulator
  engine what was kept for the firmware (`memory/1`, or `%{}` the first time): the clock starts there
  (`cpu_mhz/1`).
  """
  @spec new(buffer, pos_integer, pos_integer, map | nil) :: t
  def new(buffer, default, fill, cpu \\ nil) do
    default = clamp(default)
    %__MODULE__{buffer: buffer, default: default, fill: clamp(fill), floor: default, cpu: cpu_new(cpu)}
  end

  defp cpu_new(nil), do: nil

  defp cpu_new(memory) do
    mode = Map.get(memory, :mode, :auto)
    min = memory |> Map.get(:min, @floor_mhz) |> clamp_mhz()

    mhz =
      case mode do
        n when is_integer(n) -> clamp_mhz(n)
        :auto -> memory |> Map.get(:mhz, @full_mhz) |> clamp_mhz() |> max(min)
      end

    %{
      mode: mode,
      mhz: mhz,
      min: min,
      max: @full_mhz,
      probed: false,
      settle: 0,
      changed_at: nil,
      stale: nil,
      cpu_ms: nil,
      cpu_at: nil,
      busy: nil
    }
  end

  @doc "The emulated CPU clock to run at now (MHz), nil for a native engine."
  def cpu_mhz(%{cpu: nil}), do: nil
  def cpu_mhz(%{cpu: c}), do: c.mhz

  @doc "What to keep for this firmware (nil for a native engine): `new/4` starts the next engine from it."
  @spec memory(t) :: memory | nil
  def memory(%{cpu: nil}), do: nil
  def memory(%{cpu: c}), do: %{mode: c.mode, mhz: c.mhz, min: c.min}

  @doc """
  A STATUS at wall time `wall` (ms) with firmware time `fw_ms`. `:window` when a window just closed (the
  caller then passes the slot's underruns to `underruns/3`, and for the emulator engine its counts to
  `cpu/4`), else `:none`.
  """
  @spec status(t, integer, non_neg_integer) :: {t, :window | :none}
  def status(%{clock: nil} = h, wall, fw_ms), do: {%{h | clock: {wall, fw_ms}}, :none}

  def status(%{clock: {w0, f0}} = h, wall, fw_ms) when wall - w0 >= @window_ms do
    h = %{h | clock: {wall, fw_ms}, windows: h.windows + 1}

    if h.windows <= @warmup_windows,
      do: {h, :window},
      else: {speed(h, (fw_ms - f0) * 100 / (wall - w0)), :window}
  end

  def status(h, _wall, _fw_ms), do: {h, :none}

  @doc "Forget the clock (the audio output stopped: firmware time stands still and says nothing)."
  def pause(h), do: %{h | clock: nil}

  defp speed(h, pct) do
    h = if h.pct == nil or abs(pct - h.pct) >= @deadband, do: %{h | pct: round(pct)}, else: h

    cond do
      pct < @slow_below ->
        below = h.below + 1
        %{h | below: below, above: 0, slow: h.slow or below >= @slow_windows}

      pct >= @fast_from ->
        above = h.above + 1
        %{h | above: above, below: 0, slow: h.slow and above < @slow_windows}

      true ->
        %{h | below: 0, above: 0}
    end
  end

  @doc """
  The slot's underrun count at the end of a window (wall ms). Returns the health and the new target fill
  when it changed, else nil.
  """
  @spec underruns(t, integer, non_neg_integer) :: {t, pos_integer | nil}
  def underruns(%{windows: n} = h, wall, count) when n <= @warmup_windows,
    do: {%{h | underruns: count, quiet_since: wall}, nil}

  def underruns(h, wall, count) do
    grew = h.underruns != nil and count > h.underruns
    recent = Enum.take([grew | h.recent], @climb_span)

    h = %{
      h
      | underruns: count,
        recent: recent,
        quiet_since: if(grew, do: wall, else: h.quiet_since || wall)
    }

    cond do
      is_integer(h.buffer) ->
        {h, nil}

      # (too slow: more fill would only play later; the underruns are the engine's speed)
      h.slow ->
        {h, nil}

      Enum.count(recent, & &1) >= @climb_windows and h.fill < @max_fill ->
        # a step down that brought underruns back is undone, and this engine stays there
        floor =
          if h.lowered_at && wall - h.lowered_at < @quiet_ms,
            do: min(h.fill + @step, @max_fill),
            else: h.floor

        fill = min(h.fill + @step, @max_fill)
        {%{h | fill: fill, floor: floor, recent: [], lowered_at: nil}, fill}

      grew ->
        {h, nil}

      wall - h.quiet_since >= @quiet_ms and h.fill > max(h.default, h.floor) ->
        fill = max(h.fill - @step, max(h.default, h.floor))
        {%{h | fill: fill, quiet_since: wall, lowered_at: wall}, fill}

      true ->
        {h, nil}
    end
  end

  @doc "The player chose a buffer: the new health and the fill to set now."
  @spec buffer(t, buffer) :: {t, pos_integer}
  def buffer(h, :auto),
    do:
      {%{h | buffer: :auto, fill: h.default, floor: h.default, recent: [], lowered_at: nil},
       h.default}

  def buffer(h, n) when is_integer(n),
    do: {%{h | buffer: n, fill: clamp(n), recent: []}, clamp(n)}

  @doc """
  The emulator engine's counts at the end of a window (wall ms): the DMA halves its firmware left stale so
  far and its CPU time so far (ms). Returns the health and the clock to set now when it changed, else nil.
  A native engine's health (no `cpu`) is returned as is.
  """
  @spec cpu(t, integer, non_neg_integer, non_neg_integer) :: {t, pos_integer | nil}
  def cpu(%{cpu: nil} = h, _wall, _stale, _cpu_ms), do: {h, nil}

  def cpu(%{cpu: c} = h, wall, stale, cpu_ms) do
    busy = if c.cpu_at && wall > c.cpu_at, do: round((cpu_ms - c.cpu_ms) * 100 / (wall - c.cpu_at))
    starving = c.stale != nil and stale - c.stale >= @starve_halves
    # (`changed_at`: since the clock was last set, or since this engine's first window)
    c = %{c | stale: stale, cpu_ms: cpu_ms, cpu_at: wall, busy: busy, changed_at: c.changed_at || wall}
    h = %{h | cpu: c}
    up = step_up(c.mhz)

    cond do
      h.windows <= @warmup_windows or c.mode != :auto ->
        {h, nil}

      c.settle > 0 ->
        {%{h | cpu: %{c | settle: c.settle - 1}}, nil}

      # below the clock this firmware needs: back up, and never this low again
      starving and c.mhz < @full_mhz ->
        set_clock(h, %{c | min: up, max: max(c.max, up)}, up, wall)

      h.below >= @slow_windows and c.mhz > c.min ->
        down = c.mhz |> step_down() |> max(c.min)
        # (a step up that was only a try, and too slow: this engine stays below it)
        top = if c.probed, do: down, else: c.max
        set_clock(%{h | below: 0}, %{c | max: top, probed: false}, down, wall)

      probe?(h, c, up, wall) ->
        set_clock(h, %{c | probed: true}, up, wall)

      true ->
        {h, nil}
    end
  end

  defp probe?(h, c, up, wall) do
    up > c.mhz and up <= c.max and not h.slow and c.busy != nil and
      wall - c.changed_at >= @probe_after_ms and c.busy * up / c.mhz <= @probe_busy
  end

  defp set_clock(h, c, mhz, wall),
    do: {%{h | cpu: %{c | mhz: mhz, settle: @settle_windows, changed_at: wall}}, mhz}

  @doc """
  The player chose the emulated CPU clock: `:auto` (from the clock now, as the rules above) or fixed MHz.
  The new health and the clock to set now.
  """
  @spec cpu_mode(t, cpu_mode) :: {t, pos_integer | nil}
  def cpu_mode(%{cpu: nil} = h, _mode), do: {h, nil}

  def cpu_mode(%{cpu: c} = h, :auto),
    do: {%{h | cpu: %{c | mode: :auto, max: @full_mhz, probed: false, settle: @settle_windows}}, c.mhz}

  def cpu_mode(%{cpu: c} = h, mhz) when is_integer(mhz) do
    mhz = clamp_mhz(mhz)
    {%{h | cpu: %{c | mode: mhz, mhz: mhz, probed: false}}, mhz}
  end

  @doc """
  What the instrument should say about keeping up, beside the speed: `:lowering` (too slow, the emulated CPU
  is being stepped down), `:lower_in_io` (too slow on a fixed clock that could go lower), `:limit` (too slow
  and nothing left to lower: this phone can't run it in real time), `:raise_buffer` (fast enough, but
  underrunning on a fixed buffer below the largest), or nil.
  """
  @spec advice(t) :: :lowering | :lower_in_io | :limit | :raise_buffer | nil
  def advice(%{slow: true, cpu: nil}), do: :limit
  def advice(%{slow: true, cpu: %{mode: :auto} = c}), do: if(c.mhz > c.min, do: :lowering, else: :limit)
  def advice(%{slow: true, cpu: c}), do: if(c.mhz > max(c.min, @floor_mhz), do: :lower_in_io, else: :limit)

  def advice(%{buffer: b} = h) when is_integer(b) and b < @max_fill,
    do: if(Enum.count(h.recent, & &1) >= @climb_windows, do: :raise_buffer)

  def advice(_h), do: nil

  defp step_down(mhz), do: Enum.find(@clocks, @floor_mhz, &(&1 < mhz))
  defp step_up(mhz), do: @clocks |> Enum.reverse() |> Enum.find(@full_mhz, &(&1 > mhz))

  defp clamp_mhz(n), do: n |> max(@floor_mhz) |> min(@full_mhz)
  defp clamp(n), do: n |> max(@min_fill) |> min(@max_fill)
end
