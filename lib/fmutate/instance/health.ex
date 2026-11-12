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
  fill, which is what `slow` shows.
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
            lowered_at: nil

  @type buffer :: :auto | pos_integer
  @type t :: %__MODULE__{}

  @doc "Fill steps and limits: `{step, max}` frames."
  def limits, do: {@step, @max_fill}

  @doc "The fixed buffers the I/O screen offers (frames)."
  def fixed_buffers, do: [2048, 3072, @max_fill]

  @doc "The fill an engine starts with: a fixed buffer, else `current` (the auto fill so far) or the default."
  @spec start_fill(buffer, pos_integer, pos_integer | nil) :: pos_integer
  def start_fill(buffer, default, current \\ nil)
  def start_fill(n, _default, _current) when is_integer(n), do: clamp(n)
  def start_fill(:auto, default, nil), do: clamp(default)
  def start_fill(:auto, default, current), do: clamp(max(default, current))

  @doc "A health for an engine that just became READY with `fill`."
  @spec new(buffer, pos_integer, pos_integer) :: t
  def new(buffer, default, fill) do
    default = clamp(default)
    %__MODULE__{buffer: buffer, default: default, fill: clamp(fill), floor: default}
  end

  @doc """
  A STATUS at wall time `wall` (ms) with firmware time `fw_ms`. `:window` when a window just closed (the
  caller then passes the slot's underruns to `underruns/3`), else `:none`.
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

  def underruns(%{buffer: fixed} = h, wall, count) when is_integer(fixed),
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

  defp clamp(n), do: n |> max(@min_fill) |> min(@max_fill)
end
