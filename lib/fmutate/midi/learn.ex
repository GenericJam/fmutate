defmodule FMutate.MIDI.Learn do
  @moduledoc """
  MIDI learn, pure: what the editor's "Learn from MIDI" stores for one gesture of a layout control, from the
  first hardware message that suits it.

  A layout control's MIDI input (`midi_in` in `priv/layout.schema.json`) is
  `%{"on" => gesture, "type" => type, "channel" => 1..16, "number" => n, "device" => name, "mode" => mode}`:

    * `on` — `"value"` (knob, slider), `"x"` / `"y"` (XY pad), `"press"` (button, key, pad).
    * `type` — `"cc"`, `"note"`, `"pitch_bend"`, `"channel_pressure"`, `"poly_pressure"`, `"program"`;
      `number` is the CC, the note or the program (absent for pitch bend and channel pressure).
    * `device` — the source's name as FMutate lists it (`FMutate.MIDI`: a device's name, " · port N" past
      its first port, `"FMutate A"` for apps on the virtual port). Absent: any device.
    * `mode` — CC on a value gesture only: `"absolute"` (default) or a relative encoder's coding,
      `"relative_offset"` (64 ± n), `"relative_twos"` (1..63 up, 127 = −1) or `"relative_sign"` (1..63 up,
      65 = −1).

  Presses learn a note on, a CC, a program change or aftertouch; values learn a CC, pitch bend, aftertouch or a
  note on (its velocity). A CC is listened to for `window_ms/0` after its first message, so a CC button's
  release and a knob's next values are taken too, and the values tell an endless encoder from a knob
  (`mode/1`). Anything else is learned at once.
  """

  alias FMutate.MIDI.Map, as: MidiMap

  @window_ms 300

  defstruct [:on, :source, :first, values: []]

  @type t :: %__MODULE__{on: String.t(), source: String.t() | nil, first: MidiMap.event() | nil, values: [byte()]}

  @doc "How long a CC is listened to after its first message, in ms."
  def window_ms, do: @window_ms

  @doc "Start learning gesture `on` (`\"press\"`, `\"value\"`, `\"x\"`, `\"y\"`)."
  @spec new(String.t()) :: t
  def new(on) when on in ["press", "value", "x", "y"], do: %__MODULE__{on: on}

  @doc """
  A message from `source` while learning: `{:done, midi_in}`, `{:window, learn}` (a CC: the first of the
  window, call `finish/1` when it ends), `{:wait, learn}` (taken, keep listening) or `:ignore` (not for this
  gesture, or another control's message during a CC's window).
  """
  @spec offer(t, String.t(), MidiMap.event()) :: {:done, map} | {:window, t} | {:wait, t} | :ignore
  def offer(%__MODULE__{first: nil} = l, source, ev) do
    cond do
      not suits?(l.on, ev) -> :ignore
      match?({:cc, _, _, _}, ev) -> {:window, %{l | source: source, first: ev, values: [elem(ev, 3)]}}
      true -> {:done, midi_in(l.on, source, ev, nil)}
    end
  end

  def offer(%__MODULE__{} = l, source, {:cc, _, _, v} = ev) do
    if source == l.source and MidiMap.key(ev) == MidiMap.key(l.first),
      do: {:wait, %{l | values: [v | l.values]}},
      else: :ignore
  end

  def offer(%__MODULE__{}, _source, _ev), do: :ignore

  @doc "The CC window ended: the learned input (nil if nothing came)."
  @spec finish(t) :: map | nil
  def finish(%__MODULE__{first: nil}), do: nil

  def finish(%__MODULE__{} = l) do
    mode = if l.on == "press", do: nil, else: mode(Enum.reverse(l.values))
    midi_in(l.on, l.source, l.first, mode)
  end

  defp suits?("press", {:note, _, _, v}), do: v > 0
  defp suits?("press", {type, _, _, _}) when type in [:cc, :poly_pressure], do: true
  defp suits?("press", {type, _, _}) when type in [:program, :channel_pressure], do: true
  defp suits?("press", _ev), do: false
  defp suits?(_value, {:program, _, _}), do: false
  defp suits?(_value, {:note, _, _, v}), do: v > 0
  defp suits?(_value, _ev), do: true

  defp midi_in(on, source, ev, mode) do
    {type, ch, n} = MidiMap.key(ev)

    %{"on" => on, "type" => Atom.to_string(type), "channel" => ch}
    |> put_if("number", n)
    |> put_if("device", source)
    |> put_if("mode", if(mode not in [nil, "absolute"], do: mode))
  end

  defp put_if(map, _k, nil), do: map
  defp put_if(map, k, v), do: Map.put(map, k, v)

  @doc """
  A CC's values in the order they came → how it is coded. A knob or fader (absolute) never sends the same
  value twice in a row; an endless encoder repeats its step (+1, +1, …), so repeats in a relative coding's
  range give that coding: 57..71 → 64 ± n; 1..15 and 113..127 → two's complement; 1..15 and 65..79 → sign
  and magnitude. Steps of +1 alone (65) read as 64 ± n; the sheet can change it.
  """
  @spec mode([byte()]) :: String.t()
  def mode(values) do
    repeats = values |> Enum.chunk_every(2, 1, :discard) |> Enum.any?(fn [a, b] -> a == b end)
    within = fn ranges -> Enum.all?(values, fn v -> Enum.any?(ranges, &(v in &1)) end) end

    cond do
      not repeats -> "absolute"
      within.([57..63, 65..71]) -> "relative_offset"
      within.([1..15, 113..127]) -> "relative_twos"
      within.([1..15, 65..79]) -> "relative_sign"
      true -> "absolute"
    end
  end

  @doc "A relative CC value → signed steps."
  @spec steps(String.t(), byte()) :: integer
  def steps("relative_offset", v), do: v - 64
  def steps("relative_twos", v), do: if(v < 64, do: v, else: v - 128)
  def steps("relative_sign", v), do: if(v < 64, do: v, else: -(v - 64))

  @doc ~S|What the player reads: "CC 74 ch 1 · Arturia KeyStep", "note C2 (36) ch 10 · any device".|
  @spec describe(map) :: String.t()
  def describe(m) do
    what(m) <> " ch #{m["channel"]}" <> " · " <> (m["device"] || "any device") <> mode_note(m["mode"])
  end

  @doc "The message alone (no device): \"CC 74 ch 1\"."
  def message(m), do: what(m) <> " ch #{m["channel"]}"

  defp what(%{"type" => "cc", "number" => n}), do: "CC #{n}"
  defp what(%{"type" => "note", "number" => n}), do: "note #{note_name(n)} (#{n})"
  defp what(%{"type" => "pitch_bend"}), do: "pitch bend"
  defp what(%{"type" => "channel_pressure"}), do: "aftertouch"
  defp what(%{"type" => "poly_pressure", "number" => n}), do: "aftertouch #{note_name(n)}"
  defp what(%{"type" => "program", "number" => n}), do: "program #{n + 1}"

  defp mode_note(nil), do: ""
  defp mode_note("absolute"), do: ""
  defp mode_note(_relative), do: " · relative"

  defp note_name(n), do: Enum.at(~w(C C# D D# E F F# G G# A A# B), rem(n, 12)) <> Integer.to_string(div(n, 12) - 1)

  @doc "The relative codings, with their names for the sheet."
  def modes do
    [
      {"absolute", "Absolute"},
      {"relative_offset", "64 ± n"},
      {"relative_twos", "2's compl."},
      {"relative_sign", "Sign bit"}
    ]
  end

  @doc """
  Whether two MIDI inputs would take the same messages: the same type, channel and number, from the same
  device or where either is any device.
  """
  def overlap?(a, b) do
    a["type"] == b["type"] and a["channel"] == b["channel"] and a["number"] == b["number"] and
      (a["device"] == nil or b["device"] == nil or a["device"] == b["device"])
  end
end
