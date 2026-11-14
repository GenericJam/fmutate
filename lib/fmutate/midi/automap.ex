defmodule FMutate.MIDI.Automap do
  @moduledoc """
  Automap (pure): a MIDI controller's knobs and pads drive the FM-1's panel with no learning, on every layout.
  Device-wide, per source, on by default for devices (off for the virtual port: apps, not controllers);
  `FMutate.MIDI` keeps the switch and the first-touch order with the source's settings.

  ## Which hardware control is knob n / pad n

    * **Known controllers** (`profiles/0`, by a case-insensitive substring of the device's name, factory
      settings only):

      | Controller | Knobs 1–8 | Pads |
      |---|---|---|
      | AKAI MPK mini mk3 (`MPK mini 3`) | CC 70–77, ch 1 | ch 10: bank A notes 36–43, bank B 44–51 |
      | AKAI MPK mini mk2 (`MPK Mini Mk II`) | CC 1–8, ch 1 | first touch |

    * **Any other controller, first touch**: the first CC moved becomes knob 1, the next other CC knob 2, … up
      to 8; the first note on MIDI channel 10 (General MIDI's drum channel, where AKAI, Novation and Arturia
      pads play by default) becomes pad 1, the next other one pad 2, … Keys play on other channels and stay
      keys; a pad on another channel can be learned onto a control instead. CCs that aren't knobs are left
      out: bank select (0, 32), data entry and (N)RPN (6, 38, 96–101), pedals (64–69), channel mode
      (120–127). The order is kept per device name until Reset.

  ## What they drive

    * knobs 1–4 → KNOB1–4, 5 → SELECT, 6 → PRESETS, 7 → ALGO (encoders: clicks from the change, as a learned
      knob), 8 → MASTER (the pot, through rule 7: pickup against the on-screen MASTER);
    * pads 1–8 → FX, SEL, ENV, LFO, EDIT, GLO, HOME, SAVE; 9–14 → ARP, SEQ, PLAY, REC, OCT−, OCT+
      (momentary); pads 15 and 16 drive nothing and keep playing notes.

  A knob that repeats its value as an endless encoder does (`FMutate.MIDI.Learn.mode/1`) is taken as one.
  A per-control learned input wins over automap; automap wins over the default path (notes → keys, the
  rest → the firmware's MIDI in).
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
      knobs: for(cc <- 70..77, do: {1, cc}),
      pads: for(n <- 36..51, do: {10, n})
    },
    %{
      name: "AKAI MPK mini mk2",
      match: ["mpk mini mk ii", "mpk mini mkii", "mpk mini mk2", "mpkmini2"],
      knobs: for(cc <- 1..8, do: {1, cc}),
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

  @typedoc "First-touch order: `{channel, cc}` knobs and `{channel, note}` pads, in the order they came."
  @type order :: %{knobs: [{1..16, byte}], pads: [{1..16, byte}]}

  @doc "Nothing touched yet."
  def empty, do: %{knobs: [], pads: []}

  @doc """
  The knobs and pads of a source: its profile's where it has one (pads first touch where the profile has
  none), else the first-touch order.
  """
  @spec slots(String.t(), order) :: order
  def slots(name, order) do
    case profile(name) do
      nil -> order
      p -> %{knobs: p.knobs, pads: p.pads || order.pads}
    end
  end

  @doc """
  Whether first touch still takes new knobs and new pads for this source (`%{knobs: bool, pads: bool}`).
  """
  def open(name, order) do
    s = slots(name, order)
    p = profile(name)

    %{
      knobs: p == nil and length(s.knobs) < length(@knob_targets),
      pads: (p == nil or p.pads == nil) and length(s.pads) < length(@pad_targets)
    }
  end

  @doc """
  Whether first touch takes `ev` as a new knob or pad, given what is still `open`: a CC that is a knob's,
  or a note on channel #{@pad_channel}.
  """
  def candidate?({:cc, _ch, cc, _v}, %{knobs: true}), do: cc not in @not_knobs
  def candidate?({:note, @pad_channel, _n, v}, %{pads: true}), do: v > 0
  def candidate?(_ev, _open), do: false

  @doc "Take `ev` into the order if it is a new knob or pad: `{:new, order}` or `:same`."
  @spec touch(String.t(), order, MidiMap.event()) :: {:new, order} | :same
  def touch(name, order, ev) do
    s = slots(name, order)
    open = open(name, order)

    case ev do
      {:cc, ch, cc, _} ->
        if candidate?(ev, open) and {ch, cc} not in s.knobs, do: {:new, %{order | knobs: order.knobs ++ [{ch, cc}]}}, else: :same

      {:note, ch, n, _} ->
        if candidate?(ev, open) and {ch, n} not in s.pads, do: {:new, %{order | pads: order.pads ++ [{ch, n}]}}, else: :same

      _ ->
        :same
    end
  end

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

  @doc "A target's name on the panel (\"KNOB1\", \"MASTER\", \"OCT−\")."
  def target_name(%{"pot" => _}), do: "MASTER"
  def target_name(%{"encoder" => "algorithm"}), do: "ALGO"
  def target_name(%{"encoder" => e}), do: String.upcase(e)
  def target_name(%{"button" => "oct_down"}), do: "OCT−"
  def target_name(%{"button" => "oct_up"}), do: "OCT+"
  def target_name(%{"button" => b}), do: String.upcase(b)
end
