defmodule FMutate.MIDI.Mapping do
  @moduledoc """
  What each hardware control of a MIDI source drives, as the I/O screen's table shows it (pure): one row per
  knob (CC) FMutate knows of for the source (its automap slots, its known controller's program, its pins, the
  layout's inputs learned from it, the CCs that came from it), then its pads.

  Precedence, as `FMutate.MIDI` applies it: a layout control's learned input > a pinned synth parameter >
  automap > the default path (the firmware's own MIDI map, or nothing when the source's unmapped knobs are
  off).
  """

  alias FMutate.MIDI.{Automap, Controls, Params}

  @type via :: :learned | :pin | :automap | :synth | :dropped
  @type row :: %{
          key: {:cc | :note, 1..16, byte},
          kind: :knob | :pad,
          hw: String.t() | nil,
          msg: String.t(),
          via: via,
          to: String.t(),
          slot: pos_integer | nil
        }

  @doc """
  The rows for a source. `src`: `name`, `automap` (on?), `order` (`FMutate.MIDI.Automap`), `pins`
  (`%{{ch, cc} => param}` for the current firmware), `learned` (the layout's learned inputs that take this
  source, as `FMutate.MIDI.settings/1` lists them, with `match`), `seen` (CC keys that came from it this
  session), `unmapped` (`:synth | :drop`), `firmware` (its name) and `params` (`FMutate.MIDI.Params`, or nil).
  """
  @spec rows(map) :: [row]
  def rows(src) do
    # the program the source's CCs fit, this session's included (they name its knobs even with automap off)
    order = src.order
    known = %{order | seen: Enum.uniq(order.seen ++ for({:cc, ch, n} <- src.seen, do: {ch, n}))}
    src = %{src | order: known}
    slots = if src.automap, do: Automap.slots(src.name, order), else: %{knobs: [], pads: []}
    program = Automap.program(src.name, known)

    knobs =
      src
      |> knob_keys(slots, program)
      |> Enum.map(&knob_row(src, slots, &1))
      |> Enum.sort_by(&{&1.hw == nil, &1.hw || "", &1.slot || 99, elem(&1.key, 2)})

    knobs ++ pad_rows(src, slots)
  end

  defp pad_rows(src, slots) do
    for {{ch, n}, i} <- Enum.with_index(slots.pads),
        t = Enum.at(Automap.pad_targets(), i),
        t != nil do
      key = {:note, ch, n}

      {via, to} =
        case learned(src, key) do
          nil -> {:automap, Automap.target_name(t)}
          l -> {:learned, l.name}
        end

      %{
        key: key,
        kind: :pad,
        hw: "Pad #{i + 1}",
        msg: "note #{n} ch #{ch}",
        via: via,
        to: to,
        slot: i + 1
      }
    end
  end

  defp knob_keys(src, slots, program) do
    program_knobs = if program, do: program.knobs, else: []
    learned = for %{match: {:cc, ch, n}} <- src.learned, do: {ch, n}
    seen = for {:cc, ch, n} <- src.seen, do: {ch, n}

    Enum.uniq(
      Enum.reject(slots.knobs, &is_nil/1) ++
        program_knobs ++ Map.keys(src.pins) ++ learned ++ seen
    )
  end

  defp knob_row(src, slots, {ch, cc} = k) do
    slot = Enum.find_index(slots.knobs, &(&1 == k))
    {via, to} = knob_target(src, k, slot && Enum.at(Automap.knob_targets(), slot))

    %{
      key: {:cc, ch, cc},
      kind: :knob,
      hw: Automap.hardware_name(src.name, src.order, k),
      msg: if(ch == 1, do: "CC #{cc}", else: "CC #{cc} ch #{ch}"),
      via: via,
      to: to,
      slot: slot && slot + 1
    }
  end

  # learned > pin > automap > the default path
  defp knob_target(src, {ch, cc} = k, target) do
    cond do
      l = learned(src, {:cc, ch, cc}) ->
        {:learned, l.name}

      p = Map.get(src.pins, k) ->
        {:pin, Params.label(p)}

      target ->
        {:automap, Automap.target_name(target)}

      src.unmapped == :drop and not MapSet.member?(src.pass, k) ->
        {:dropped, "nothing (unmapped knobs are off)"}

      true ->
        {:synth, synth(src, cc)}
    end
  end

  defp learned(src, key), do: Enum.find(src.learned, &(&1.match == key))

  defp synth(%{params: nil, firmware: fw}, _cc), do: "#{fw}'s MIDI in"

  defp synth(%{params: params, firmware: fw}, cc) do
    case Params.by_cc(params, cc) do
      nil -> "#{fw}'s MIDI in (sets nothing)"
      p -> "#{fw}: #{Params.label(p)}"
    end
  end

  @doc "The panel targets no hardware knob drives (automap on): `[\"SELECT\", …]`."
  def free(src) do
    if src.automap do
      knobs = Automap.slots(src.name, src.order).knobs

      for {t, i} <- Enum.with_index(Automap.knob_targets()),
          (k = Enum.at(knobs, i)) == nil or Map.has_key?(src.pins, k),
          do: Automap.target_name(t)
    else
      []
    end
  end

  @doc ~S|The short tags of a source's knobs and pads for the surface ("K1", else "CC20"), by match.|
  def tags(name, order, matches) do
    Map.new(matches, fn
      {:cc, ch, cc} = m -> {m, Automap.hardware_name(name, order, {ch, cc}) || Controls.tag_of(m)}
      m -> {m, Controls.tag_of(m)}
    end)
  end
end
