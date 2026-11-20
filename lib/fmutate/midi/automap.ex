defmodule FMutate.MIDI.Automap do
  @moduledoc """
  Automap (pure): a MIDI controller's knobs and pads drive the FM-1's panel with no learning, on every layout.
  Device-wide, per source, on by default for devices (off for the virtual port: apps, not controllers);
  `FMutate.MIDI` keeps the switch and the order (`t:order/0`) with the source's settings, by device name.

  ## Which hardware control is knob n / pad n

    * **Known controllers** (`profiles/0`, by a case-insensitive substring of the device's name): their
      factory programs. A controller with several programs is on the first one its knobs fit: every CC seen
      from it (`seen`) must be one of that program's knobs (or its joystick's), and the first CC that fits
      no program switches the device to first touch, keeping the CCs seen so far in the order they came.

      | Controller | Program | Knobs K1–K8 | Joystick | Pads |
      |---|---|---|---|---|
      | AKAI MPK mini mk3 (`MPK mini 3`) | — | CC 70–77, ch 1 | CC 1 | ch 10: bank A notes 36–43, bank B 44–51 |
      | AKAI MPK mini mk2 (`MPK Mini Mk II`) | PROG 1 | CC 1–8, ch 1 | CC 1 | first touch |
      | | PROG 2 | CC 20, 21, 22, 23, 16, 17, 18, 19 | CC 1 | first touch |
      | | PROG 3 | CC 20–27 | CC 1 | first touch |
      | | PROG 4 | CC 20–27 | CC 30, 31 | first touch |

      The mk2's programs are its factory `.mk2` presets (decoded: the knob table's CC per knob, and the
      joystick's Y axis). Its joystick sends CC 1 in PROG 1–3, the same CC as PROG 1's K1, so CC 1 never
      decides the program and never takes a knob in first touch: it goes on to the firmware (mod wheel).

    * **Any other controller, first touch**: the first CC moved becomes knob 1, the next other CC knob 2, … up
      to 8; the first note on MIDI channel 10 (General MIDI's drum channel, where AKAI, Novation and Arturia
      pads play by default) becomes pad 1, the next other one pad 2, … Keys play on other channels and stay
      keys; a pad on another channel can be learned onto a control instead. CCs that aren't knobs are left
      out: bank select (0, 32), data entry and (N)RPN (6, 38, 96–101), pedals (64–69), channel mode
      (120–127), and a known controller's joystick.

    * **Lined up** (`line_up/3`, the I/O screen's guided "Line up knobs"): the player turned the knob they
      want for KNOB1, then KNOB2, … (or skipped one); that order holds, and no other knob joins.

  The order is kept per device name until Reset (`empty/0`), across firmwares and layouts.

  ## What they drive

    * knobs 1–4 → KNOB1–4, 5 → SELECT, 6 → PRESETS, 7 → ALGO (encoders: clicks from the change, as a learned
      knob), 8 → MASTER (the pot, through rule 7: pickup against the on-screen MASTER);
    * pads 1–8 → FX, SEL, ENV, LFO, EDIT, GLO, HOME, SAVE; 9–14 → ARP, SEQ, PLAY, REC, OCT−, OCT+
      (momentary); pads 15 and 16 drive nothing and keep playing notes.

  A knob that repeats its value as an endless encoder does (`FMutate.MIDI.Learn.mode/1`) is taken as one.
  A per-control learned input wins over a pinned synth parameter (`FMutate.MIDI.Params`), which wins over
  automap; automap wins over the default path (notes → keys, the rest → the firmware's MIDI in).
  """

  alias FMutate.MIDI.Map, as: MidiMap

  @knob_targets [
    %{"encoder" => "knob1"},
    %{"encoder" => "knob2"},
    %{"encoder" => "knob3"},
    %{"encoder" => "knob4"},
    %{"encoder" => "select"},
    %{"encoder" => "presets"},
    %{"encoder" => "algorithm"},
    %{"pot" => "master"}
  ]

  @pad_targets ~w(fx sel env lfo edit glo home save arp seq play rec oct_down oct_up)
               |> Enum.map(&%{"button" => &1})

  @pad_channel 10
  @not_knobs [0, 32, 6, 38] ++ Enum.to_list(96..101) ++ Enum.to_list(64..69) ++ Enum.to_list(120..127)

  @profiles [
    %{
      name: "AKAI MPK mini mk3",
      match: ["mpk mini 3", "mpk mini mk3", "mpk mini iii"],
      joystick: [{1, 1}],
      programs: [%{name: nil, knobs: for(cc <- 70..77, do: {1, cc}), joystick: []}],
      pads: for(n <- 36..51, do: {10, n})
    },
    %{
      name: "AKAI MPK mini mk2",
      match: ["mpk mini mk ii", "mpk mini mkii", "mpk mini mk2", "mpkmini2"],
      joystick: [{1, 1}],
      programs: [
        %{name: "PROG 1", knobs: for(cc <- 1..8, do: {1, cc}), joystick: []},
        %{name: "PROG 2", knobs: for(cc <- [20, 21, 22, 23, 16, 17, 18, 19], do: {1, cc}), joystick: []},
        %{name: "PROG 3", knobs: for(cc <- 20..27, do: {1, cc}), joystick: []},
        %{name: "PROG 4", knobs: for(cc <- 20..27, do: {1, cc}), joystick: [{1, 30}, {1, 31}]}
      ],
      pads: nil
    }
  ]

  @doc "The known controllers."
  def profiles, do: @profiles

  @doc "The known controller a device name is, or nil."
  def profile(name) when is_binary(name) do
    down = String.downcase(name)
    Enum.find(@profiles, fn p -> Enum.any?(p.match, &String.contains?(down, &1)) end)
  end

  @doc "The FM-1 inputs knobs 1–8 drive."
  def knob_targets, do: @knob_targets

  @doc "The FM-1 inputs pads 1–14 drive."
  def pad_targets, do: @pad_targets

  @typedoc """
  A device's order: `knobs` (`{channel, cc}`, nil where a line-up skipped one) and `pads` (`{channel, note}`)
  in slot order; `seen`, the knob CCs that came from it (they pick a known controller's program); `by`,
  where the knobs come from: `:auto` (the profile's program, else first touch), `:touch` (first touch: a
  known controller whose CCs fit none of its programs) or `:line_up`.
  """
  @type slot :: {1..16, byte}
  @type order :: %{knobs: [slot | nil], pads: [slot], seen: [slot], by: :auto | :touch | :line_up}

  @doc "Nothing touched yet."
  def empty, do: %{knobs: [], pads: [], seen: [], by: :auto}

  @doc "An order as saved (orders saved before `seen` and `by` existed get them)."
  def normalize(%{} = order), do: Map.merge(empty(), Map.take(order, [:knobs, :pads, :seen, :by]))

  @doc "The profile program the CCs seen from a device fit (nil: no profile, or none fits)."
  def program(name, order) do
    case profile(name) do
      nil -> nil
      p -> fitting(p, order.seen)
    end
  end

  defp fitting(p, seen), do: Enum.find(p.programs, &fits?(p, &1, seen))

  defp fits?(p, prog, seen), do: Enum.all?(seen, &(&1 in prog.knobs or &1 in prog.joystick or &1 in p.joystick))

  @doc """
  The knobs and pads of a source: its profile program's knobs while it is on one, else its order's; its
  profile's pads, else the first-touch ones.
  """
  @spec slots(String.t(), order) :: %{knobs: [slot | nil], pads: [slot]}
  def slots(name, order) do
    p = profile(name)

    knobs =
      case {p && order.by, program(name, order)} do
        {:auto, %{knobs: knobs}} -> knobs
        _ -> order.knobs
      end

    %{knobs: knobs, pads: (p && p.pads) || order.pads}
  end

  @doc """
  Whether new knobs and pads come to `touch/3` from this source, and the CCs that never do (`pass`: a known
  controller's joystick, for the firmware): `%{knobs: bool, pads: bool, pass: MapSet}`. A known controller on
  its program takes every knob CC (to check it still fits).
  """
  def open(name, order) do
    p = profile(name)

    knobs =
      case order.by do
        :line_up -> false
        :auto when p != nil -> true
        _ -> length(order.knobs) < length(@knob_targets)
      end

    %{
      knobs: knobs,
      pads: (p == nil or p.pads == nil) and length(order.pads) < length(@pad_targets),
      pass: pass(p, order)
    }
  end

  # the joystick's CCs, unless the program the device is on has them as knobs (the mk2's PROG 1: K1 is CC 1 too)
  defp pass(nil, _order), do: MapSet.new()

  defp pass(p, order) do
    prog = if order.by == :auto, do: fitting(p, order.seen)
    knobs = if prog, do: prog.knobs, else: []
    (p.joystick ++ ((prog && prog.joystick) || [])) |> Enum.reject(&(&1 in knobs)) |> MapSet.new()
  end

  @doc "Whether a CC number can be a knob (not bank select, data entry, (N)RPN, a pedal or channel mode)."
  def knob_cc?(cc), do: cc not in @not_knobs

  @doc """
  Whether `ev` goes to `touch/3`, given what is `open`: a CC that can be a knob (not one of `pass`), or a
  note on on channel #{@pad_channel}.
  """
  def candidate?({:cc, ch, cc, _v}, %{knobs: true} = open),
    do: cc not in @not_knobs and not MapSet.member?(Map.get(open, :pass, MapSet.new()), {ch, cc})

  def candidate?({:note, @pad_channel, _n, v}, %{pads: true}), do: v > 0
  def candidate?(_ev, _open), do: false

  @doc """
  Take `ev` into the order: a new first-touch knob or pad, or a CC that tells (or changes) a known
  controller's program, or that fits none and switches it to first touch. `{:new, order}` or `:same`.
  """
  @spec touch(String.t(), order, MidiMap.event()) :: {:new, order} | :same
  def touch(name, order, ev) do
    open = open(name, order)

    if candidate?(ev, open), do: take(profile(name), order, ev), else: :same
  end

  defp take(p, %{by: :auto} = order, {:cc, ch, cc, _}) when p != nil do
    k = {ch, cc}

    cond do
      k in order.seen or k in p.joystick ->
        :same

      fitting(p, order.seen ++ [k]) ->
        {:new, %{order | seen: order.seen ++ [k]}}

      true ->
        # fits no program: first touch from here, with the knobs seen so far in the order they came
        seen = order.seen ++ [k]
        knobs = seen |> Enum.reject(&(&1 in p.joystick)) |> Enum.take(length(@knob_targets))
        {:new, %{order | seen: seen, knobs: knobs, by: :touch}}
    end
  end

  defp take(_p, order, {:cc, ch, cc, _}) do
    if {ch, cc} in order.knobs,
      do: :same,
      else: {:new, %{order | knobs: order.knobs ++ [{ch, cc}], seen: Enum.uniq(order.seen ++ [{ch, cc}])}}
  end

  defp take(_p, order, {:note, ch, n, _}) do
    if {ch, n} in order.pads, do: :same, else: {:new, %{order | pads: order.pads ++ [{ch, n}]}}
  end

  @doc """
  The knobs the player lined up (`[{channel, cc} | nil]`, slot by slot, nil: skipped) become the device's
  order; its pads stay.
  """
  @spec line_up(order, [slot | nil]) :: order
  def line_up(order, knobs) do
    knobs = knobs |> Enum.take(length(@knob_targets)) |> trim_nils()
    %{order | knobs: knobs, seen: Enum.uniq(order.seen ++ Enum.reject(knobs, &is_nil/1)), by: :line_up}
  end

  @doc """
  Put one hardware knob (`{channel, cc}`) on knob slot `i` (1..8), as a line-up: where the knob was is
  emptied, and whatever had slot `i` moves there (a swap). The current slots are the starting point.
  """
  def place(name, order, k, i) when i in 1..8 do
    knobs = slots(name, order).knobs
    knobs = knobs ++ List.duplicate(nil, max(0, length(@knob_targets) - length(knobs)))
    was = Enum.find_index(knobs, &(&1 == k))
    other = Enum.at(knobs, i - 1)
    knobs = List.replace_at(knobs, i - 1, k)
    knobs = if was && was != i - 1, do: List.replace_at(knobs, was, other), else: knobs
    line_up(order, knobs)
  end

  defp trim_nils(list), do: list |> Enum.reverse() |> Enum.drop_while(&is_nil/1) |> Enum.reverse()

  @doc """
  What a source's slots drive: `[{match_key, number, :knob | :pad, target}]` (`number` from 1), only for
  slots with a target.
  """
  def assignments(name, order) do
    s = slots(name, order)

    knobs =
      for {{ch, cc}, i} <- Enum.with_index(s.knobs), t = Enum.at(@knob_targets, i), t != nil,
          do: {{:cc, ch, cc}, i + 1, :knob, t}

    pads =
      for {{ch, n}, i} <- Enum.with_index(s.pads), t = Enum.at(@pad_targets, i), t != nil,
          do: {{:note, ch, n}, i + 1, :pad, t}

    knobs ++ pads
  end

  @doc """
  The name printed on the hardware for a knob of a known controller ("K1"), from the program its CCs fit;
  nil when that isn't known.
  """
  def hardware_name(name, order, {ch, cc}) do
    with %{knobs: knobs} <- program(name, order),
         i when i != nil <- Enum.find_index(knobs, &(&1 == {ch, cc})) do
      "K#{i + 1}"
    else
      _ -> nil
    end
  end

  @doc """
  Every joystick CC of a known controller (any program's), for a source with automap off: they go to the
  firmware even when its unmapped knobs don't.
  """
  def joystick(name) do
    case profile(name) do
      nil -> MapSet.new()
      p -> MapSet.new(p.joystick ++ Enum.flat_map(p.programs, & &1.joystick))
    end
  end

  @doc "A target's name on the panel (\"KNOB1\", \"MASTER\", \"OCT−\")."
  def target_name(%{"pot" => _}), do: "MASTER"
  def target_name(%{"encoder" => "algorithm"}), do: "ALGO"
  def target_name(%{"encoder" => e}), do: String.upcase(e)
  def target_name(%{"button" => "oct_down"}), do: "OCT−"
  def target_name(%{"button" => "oct_up"}), do: "OCT+"
  def target_name(%{"button" => b}), do: String.upcase(b)
end
