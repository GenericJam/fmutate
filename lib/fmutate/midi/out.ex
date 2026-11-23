defmodule FMutate.MIDI.Out do
  @moduledoc """
  MIDI out from the surface (pure): where a binding's MIDI message goes, and what the outputs still hold.

  A layout binding whose target is a MIDI message (`{"midi": {...}}`: note, CC, pitch bend) has a destination,
  its `"to"`: `"synth"` (absent: the running firmware's MIDI in, as always), `"out"` (only MIDI out: the
  instance's own port and the outputs switched on in I/O) or `"both"`. `route/2` turns an instance input
  `{:midi, bytes}` into what each destination gets: the input itself for the synth, `{:out, bytes}` for the
  outputs.

  Rule 7 keys an Out-only CC or pitch bend apart from the synth's (`"out:cc:<ch>:<n>"`, `"out:bend:<ch>"`): the
  synth's CC 74 and a DAW's CC 74 are two values. Both keeps the synth's key: it moves the synth's value, so it
  picks up from (and stales) the synth's controls bound to the same CC.

  What went out is tracked (`sent/2`) so nothing stays held in a DAW: `release/1` gives a note off for every
  note still on, then CC 123 (all notes off) on each channel notes went out on since the last release.
  """

  import Bitwise

  defstruct held: MapSet.new(), channels: MapSet.new()

  @type dest :: :synth | :out | :both
  @type t :: %__MODULE__{held: MapSet.t({0..15, 0..127}), channels: MapSet.t(0..15)}

  @doc "Nothing held."
  def new, do: %__MODULE__{}

  @doc "A binding target's destination (`:synth` for anything but a MIDI target sent elsewhere)."
  @spec dest(map) :: dest
  def dest(%{"midi" => %{"to" => to}}), do: of(to)
  def dest(_target), do: :synth

  @doc "A surface payload's destination (its `\"to\"`, sent by the surface for MIDI targets that aren't synth)."
  @spec payload_dest(map) :: dest
  def payload_dest(%{"to" => to}), do: of(to)
  def payload_dest(_payload), do: :synth

  defp of("out"), do: :out
  defp of("both"), do: :both
  defp of(_synth), do: :synth

  @doc "The rule 7 key prefix of a destination: Out-only targets are their own (see the module doc)."
  @spec key_prefix(dest) :: String.t()
  def key_prefix(:out), do: "out:"
  def key_prefix(_dest), do: ""

  @doc """
  What an instance input becomes at `dest`: `[input]` (synth), `[{:out, bytes}]` (out), or both. Inputs that
  aren't MIDI only ever go to the synth.
  """
  @spec route(term, dest) :: list
  def route({:midi, bytes} = input, dest) when is_binary(bytes) do
    case dest do
      :synth -> [input]
      :out -> [{:out, bytes}]
      :both -> [input, {:out, bytes}]
    end
  end

  def route(nil, _dest), do: []
  def route(input, _dest), do: [input]

  @doc "`bytes` went out: a note on is held until its note off (or a note on at velocity 0)."
  @spec sent(t, binary) :: t
  def sent(%__MODULE__{} = out, <<st, n, v>>) when st in 0x90..0x9F and n < 128 and v in 1..127 do
    ch = st &&& 0x0F
    %{out | held: MapSet.put(out.held, {ch, n}), channels: MapSet.put(out.channels, ch)}
  end

  def sent(%__MODULE__{} = out, <<st, n, _v>>) when st in 0x80..0x9F and n < 128,
    do: %{out | held: MapSet.delete(out.held, {st &&& 0x0F, n})}

  def sent(%__MODULE__{} = out, _bytes), do: out

  @doc "A note off for every note still held out (what an output being switched off gets)."
  @spec offs(t) :: [binary]
  def offs(%__MODULE__{held: held}), do: for({ch, n} <- Enum.sort(held), do: <<0x80 + ch, n, 0>>)

  @doc """
  The messages that let go of what was sent out, and what stays held: a note off for every held note not in
  `keep` (`{channel 0..15, note}`), then CC 123 (all notes off) on each channel notes went out on that has no
  kept note left. `[]` when no note went out since the last release.
  """
  @spec release(t, MapSet.t()) :: {[binary], t}
  def release(%__MODULE__{} = out, keep \\ MapSet.new()) do
    {kept, gone} = Enum.split_with(out.held, &MapSet.member?(keep, &1))
    kept_channels = MapSet.new(kept, &elem(&1, 0))
    offs = for {ch, n} <- Enum.sort(gone), do: <<0x80 + ch, n, 0>>
    all_off = for ch <- Enum.sort(out.channels), not MapSet.member?(kept_channels, ch), do: <<0xB0 + ch, 123, 0>>
    {offs ++ all_off, %__MODULE__{held: MapSet.new(kept), channels: kept_channels}}
  end

  @doc """
  The notes (`{channel 0..15, note}`) the layout's dock sends out (Out or Both): the dock stays on screen across
  pages, so a page change doesn't let go of them.
  """
  @spec dock_notes(map | nil) :: MapSet.t()
  def dock_notes(layout) do
    for c <- (layout && layout["dock"]) || [],
        b <- (c["bindings"] || []) ++ Enum.flat_map(get_in(c, ["pad_grid", "pads"]) || [], &(&1["bindings"] || [])),
        %{"midi" => %{"type" => "note"} = mi} = to <- [b["to"]],
        dest(to) != :synth,
        into: MapSet.new(),
        do: {(mi["channel"] || 1) - 1, mi["number"] || 0}
  end
end
