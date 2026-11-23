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
  The messages that let go of everything sent out (note offs, then CC 123 on each channel notes went out on),
  and nothing held. `[]` when no note went out since the last release.
  """
  @spec release(t) :: {[binary], t}
  def release(%__MODULE__{} = out) do
    all_off = for ch <- Enum.sort(out.channels), do: <<0xB0 + ch, 123, 0>>
    {offs(out) ++ all_off, new()}
  end
end
