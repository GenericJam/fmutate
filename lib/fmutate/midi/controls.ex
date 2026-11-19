defmodule FMutate.MIDI.Controls do
  @moduledoc """
  Hardware MIDI controls learned onto layout controls, at play time (pure). A learned message (see
  `FMutate.MIDI.Learn` for `midi_in`) drives its layout control as touching it would: its bindings give
  instance inputs, and the surface is told what to show (`surface_text/1`).

  It also holds the instance's rule 7 arbiter (`FMutate.Bindings`): the surface's absolute moves
  (`touch/2`) and the learned controls' go through the same one, so a hardware knob and the on-screen
  controls bound to one target pick up from each other.

  ## Conversions

    * **Press** (`on: "press"`): a note on is down, its note off up; a CC, aftertouch or pitch bend is down
      from half way (CC ≥ 64) and up below; a program change is a tap (down, up). Only changes count (a CC
      button's repeated 127 is one press). The press bindings then work as on the surface: momentary down
      and up, or toggle (each down flips the control's toggle, which the surface shares). Long-press bindings
      aren't fired from MIDI.
    * **Value** (`value`, `x`, `y`), absolute (0..127, pitch bend 0..16383, a note's velocity): absolute
      targets (MASTER, MIDI CC / pitch bend out) take the value through rule 7: the hardware control is its
      own participant (`"midi:<control>:<gesture>"`), so after another control moved the target it is
      ignored until it reaches the current value (pickup). Encoders get clicks from the change in value: a
      full sweep is #{200} pt of an on-screen drag, `200 / pt_per_click` clicks (33 at the default 6 pt).
    * **Value, relative** (a CC whose `mode` is relative): each step is one encoder click, or 1/100 of an
      absolute target's range (rule 7 lets relative moves through: they start from the current value).
  """

  alias FMutate.{Bindings, Inputs, LayoutEdit}
  alias FMutate.MIDI.Learn
  alias FMutate.MIDI.Map, as: MidiMap

  @pot_range_pt 200
  @default_pt_per_click 6
  @relative_step 0.01

  defstruct mappings: %{}, auto: %{}, targets: %{}, runtime: %{}, toggles: %{}, bindings: %Bindings{}

  @type surface ::
          {:press, String.t(), boolean}
          | {:toggle, String.t(), boolean}
          | {:value, String.t(), String.t(), float}
          | {:clicks, String.t(), integer}
          | {:shine, String.t(), boolean}
          | {:octave, -1 | 1}

  @type t :: %__MODULE__{}

  @doc "No learned controls, an empty arbiter."
  def new, do: %__MODULE__{bindings: Bindings.new()}

  @doc """
  Take the learned inputs of `layout` (the current one for the instance's firmware). The arbiter and the
  toggles carry over; a control that is gone loses its runtime state.
  """
  @spec load(t, map) :: t
  def load(%__MODULE__{} = c, layout) do
    list =
      for {ctl, sub, m} <- LayoutEdit.midi_ins(layout) do
        key = if sub, do: "#{ctl["id"]}##{sub}", else: ctl["id"]
        bindings = for b <- LayoutEdit.bindings(layout, ctl["id"], sub), (b["on"] || "press") == m["on"], do: b

        %{
          id: {key, m["on"]},
          key: key,
          control: ctl["id"],
          on: m["on"],
          match: {type(m["type"]), m["channel"], m["number"]},
          device: m["device"],
          mode: m["mode"] || "absolute",
          detect: false,
          bindings: bindings
        }
      end

    # device-specific inputs before any-device ones
    mappings = list |> Enum.sort_by(&is_nil(&1.device)) |> Enum.group_by(& &1.match)
    ids = MapSet.new(list, & &1.id)
    keys = MapSet.new(list, & &1.key)

    %{
      c
      | mappings: mappings,
        targets: targets(layout),
        runtime: Map.filter(c.runtime, fn {id, _} -> id in ids or match?({:auto, _, _}, id) end),
        toggles: Map.filter(c.toggles, fn {k, _} -> k in keys end)
    }
  end

  # the layout's controls by what they drive, for what the surface shows of automap: a button's or key's
  # press bindings, a knob's / slider's / XY pad's value bindings → [{control key, :press | :value}]
  defp targets(layout) do
    for {c, sub} <- controls_and_pads(layout),
        b <- LayoutEdit.bindings(layout, c["id"], sub),
        kind = if((b["on"] || "press") == "press", do: :press, else: :value),
        reduce: %{} do
      acc ->
        key = if sub, do: "#{c["id"]}##{sub}", else: c["id"]
        Map.update(acc, b["to"], [{key, kind}], &[{key, kind} | &1])
    end
  end

  defp controls_and_pads(layout) do
    all = (layout["dock"] || []) ++ Enum.flat_map(layout["pages"], &(&1["controls"] || []))

    Enum.flat_map(all, fn
      %{"type" => "pad_grid"} = c -> for i <- 0..(length(get_in(c, ["pad_grid", "pads"]) || []) - 1)//1, do: {c, i}
      %{"type" => t} = c when t in ["button", "key", "label", "knob", "slider", "xy_pad"] -> [{c, nil}]
      _ -> []
    end)
  end

  @doc """
  A source's automap (`FMutate.MIDI.Automap.assignments/2`; `[]` when it is off): its knobs and pads drive
  those FM-1 inputs. A knob that repeats its value as an endless encoder does is taken as one.
  """
  def put_auto(%__MODULE__{} = c, source, assignments) do
    maps =
      Map.new(assignments, fn {match, _n, kind, target} ->
        on = if kind == :knob, do: "value", else: "press"

        {match,
         %{
           id: {:auto, source, match},
           key: "auto:#{source}:#{elem(match, 1)}:#{elem(match, 2)}",
           control: nil,
           on: on,
           match: match,
           device: source,
           mode: "absolute",
           detect: kind == :knob,
           bindings: [%{"on" => on, "to" => target}]
         }}
      end)

    auto = if maps == %{}, do: Map.delete(c.auto, source), else: Map.put(c.auto, source, maps)
    %{c | auto: auto}
  end

  @doc "The keys automapped for a source."
  def auto_keys(%__MODULE__{auto: auto}, source), do: auto |> Map.get(source, %{}) |> Map.keys() |> MapSet.new()

  @doc """
  An automapped message from `source`: `{instance_inputs, surface, state}`. The surface is shown the layout's
  controls bound to the same FM-1 input (lit while a pad holds a button, an encoder's knob turning, MASTER's
  value; rule 7 makes the on-screen MASTER stale until it picks up).
  """
  def handle_auto(%__MODULE__{} = c, source, ev) do
    case get_in(c.auto, [source, MidiMap.key(ev)]) do
      nil ->
        {[], [], c}

      m ->
        {ins, sur, c} = apply_input(c, m, source, ev)
        {ins, Enum.flat_map(sur, &shown(c, m, &1)), c}
    end
  end

  defp shown(c, m, {:press, _key, down}) do
    [%{"button" => b} = to] = Enum.map(m.bindings, & &1["to"])
    lit = for {key, :press} <- Map.get(c.targets, to, []), do: {:shine, key, down}

    case {b, down} do
      {"oct_down", true} -> lit ++ [{:octave, -1}]
      {"oct_up", true} -> lit ++ [{:octave, 1}]
      _ -> lit
    end
  end

  defp shown(c, m, {:clicks, _control, n}) do
    [to] = Enum.map(m.bindings, & &1["to"])
    for {key, :value} <- Map.get(c.targets, to, []), not String.contains?(key, "#"), do: {:clicks, key, n}
  end

  defp shown(_c, _m, {:value, _control, key, v}), do: [{:value, "midi", key, v}]
  defp shown(_c, _m, _other), do: []

  @doc "The master pot's value as the instance has it (rule 7 starts from it; see `FMutate.Bindings.seed/3`)."
  def seed_master(%__MODULE__{} = c, value), do: %{c | bindings: Bindings.seed(c.bindings, "pot:master", value)}

  # FMutate.MIDI.Map's event types (no String.to_existing_atom/1: modules load lazily on a device)
  defp type("cc"), do: :cc
  defp type("note"), do: :note
  defp type("pitch_bend"), do: :pitch_bend
  defp type("channel_pressure"), do: :channel_pressure
  defp type("poly_pressure"), do: :poly_pressure
  defp type("program"), do: :program

  @doc "The `FMutate.MIDI.Map.key/1`s learned for a source (by its name): its own and any device's."
  @spec keys(t, String.t()) :: MapSet.t()
  def keys(%__MODULE__{mappings: mappings}, source) do
    for {match, list} <- mappings, Enum.any?(list, &(&1.device in [nil, source])), into: MapSet.new(), do: match
  end

  @doc "Whether anything is learned."
  def any?(%__MODULE__{mappings: m}), do: map_size(m) > 0

  @doc """
  A learned message from `source`: `{instance_inputs, surface, state}` (`surface` is what the on-screen
  controls must show, `surface_text/1`).
  """
  @spec handle(t, String.t(), MidiMap.event()) :: {list, [surface], t}
  def handle(%__MODULE__{} = c, source, ev) do
    list = Map.get(c.mappings, MidiMap.key(ev), [])

    case Enum.find(list, &(&1.device == source)) || Enum.find(list, &is_nil(&1.device)) do
      nil -> {[], [], c}
      m -> apply_input(c, m, source, ev)
    end
  end

  @doc "A source went away: let go of what its learned and automapped controls hold."
  @spec release_source(t, String.t()) :: {list, [surface], t}
  def release_source(%__MODULE__{} = c, source) do
    held = for {id, %{down: true, from: ^source}} <- c.runtime, do: id
    learned = c.mappings |> Map.values() |> List.flatten()
    auto = c.auto |> Map.get(source, %{}) |> Map.values()

    Enum.reduce(held, {[], [], c}, fn id, {ins, sur, c} ->
      case Enum.find(learned ++ auto, &(&1.id == id)) do
        nil ->
          {ins, sur, c}

        %{control: nil} = m ->
          c = put_rt(c, m, %{rt(c, m) | down: false})
          {i, s, c} = press(c, m, false)
          {ins ++ i, sur ++ Enum.flat_map(s, &shown(c, m, &1)), c}

        m ->
          c = put_rt(c, m, %{rt(c, m) | down: false})
          {i, s, c} = press(c, m, false)
          {ins ++ i, sur ++ s, c}
      end
    end)
  end

  @doc """
  A move from the surface through rule 7 (`FMutate.InstrumentView.arbitrate/2`): `{instance_input | nil,
  state}`.
  """
  def touch(%__MODULE__{} = c, payload) do
    {event, b} = FMutate.InstrumentView.arbitrate(c.bindings, payload)
    {event, %{c | bindings: b}}
  end

  @doc "The surface toggled a control (`key`: its id, or `\"<id>#<pad>\"`)."
  def toggled(%__MODULE__{} = c, key, on) when is_boolean(on), do: %{c | toggles: Map.put(c.toggles, key, on)}

  ## Presses

  defp apply_input(c, %{on: "press"} = m, source, ev) do
    rt = rt(c, m)

    case press_of(ev) do
      :tap ->
        {i1, s1, c} = press(c, m, true)
        {i2, s2, c} = press(c, m, false)
        {i1 ++ i2, s1 ++ s2, c}

      down when down == rt.down ->
        {[], [], c}

      down ->
        c = put_rt(c, m, %{rt | down: down, from: source})
        press(c, m, down)
    end
  end

  defp apply_input(c, m, _source, ev), do: value(c, m, ev)

  defp press_of({:note, _, _, v}), do: v > 0
  defp press_of({:program, _, _}), do: :tap
  defp press_of(ev), do: value01(ev) >= 0.5

  defp press(c, m, down) do
    {toggle, momentary} = Enum.split_with(m.bindings, &(&1["mode"] == "toggle"))
    inputs = Enum.flat_map(momentary, &fire(c, &1["to"], down))

    if down and toggle != [] do
      on = not Map.get(c.toggles, m.key, false)
      c = %{c | toggles: Map.put(c.toggles, m.key, on)}
      {inputs ++ Enum.flat_map(toggle, &fire(c, &1["to"], on)), [{:press, m.key, down}, {:toggle, m.key, on}], c}
    else
      {inputs, [{:press, m.key, down}], c}
    end
  end

  # a press target's instance inputs (InstrumentView.kt `fire`); pages and app actions are the surface's
  defp fire(_c, %{"key" => k}, down), do: [{:key, k, dir(down)}]

  defp fire(_c, %{"button" => b}, down) do
    case Enum.find(Inputs.buttons(), &(Atom.to_string(&1) == b)) do
      nil -> []
      id -> [{:button, id, dir(down)}]
    end
  end

  defp fire(_c, %{"midi" => %{"type" => "note"} = mi}, down) do
    ch = (mi["channel"] || 1) - 1
    n = mi["number"] || 0
    if down, do: [{:midi, <<0x90 + ch, n, 100>>}], else: [{:midi, <<0x80 + ch, n, 0>>}]
  end

  # a CC button: `on` while down; on release the value a control of this layout last set, else `off`
  defp fire(c, %{"midi" => %{"type" => "cc"} = mi} = to, down) do
    v =
      cond do
        down -> mi["on"] || 127
        v = Bindings.value(c.bindings, target_key(to)) -> round(v * 127)
        true -> mi["off"] || 0
      end

    [{:midi, <<0xB0 + (mi["channel"] || 1) - 1, mi["number"] || 0, v>>}]
  end

  defp fire(_c, %{"encoder" => _} = to, true), do: encoder(to, if(to["invert"], do: -1, else: 1))
  defp fire(_c, _to, _down), do: []

  defp dir(true), do: :down
  defp dir(false), do: :up

  ## Values

  # an automapped knob: after a few values that repeat as an endless encoder's do, it is taken as one
  defp value(c, %{detect: true} = m, {:cc, _, _, v} = ev) do
    rt = rt(c, m)
    hist = Enum.take([v | rt.hist], 4)

    mode =
      cond do
        rt.mode -> rt.mode
        length(hist) < 4 -> nil
        (detected = Learn.mode(Enum.reverse(hist))) != "absolute" -> detected
        true -> nil
      end

    c = put_rt(c, m, %{rt | hist: hist, mode: mode})
    value(c, %{m | detect: false, mode: mode || "absolute"}, ev)
  end

  defp value(c, %{mode: mode} = m, {:cc, _, _, v}) when mode != "absolute" do
    case Learn.steps(mode, v) do
      0 ->
        {[], [], c}

      steps ->
        Enum.reduce(m.bindings, {[], [], c}, fn b, acc -> relative(acc, m, b["to"], steps) end)
    end
  end

  defp value(c, m, ev) do
    case value01(ev) do
      nil ->
        {[], [], c}

      v ->
        rt = rt(c, m)

        {ins, sur, c, accs} =
          m.bindings
          |> Enum.with_index()
          |> Enum.reduce({[], [], c, rt.acc}, fn {b, i}, acc -> absolute(acc, m, rt.last, b["to"], i, v) end)

        {ins, sur, put_rt(c, m, %{rt(c, m) | last: v, acc: accs})}
    end
  end

  defp relative({ins, sur, c}, m, %{"encoder" => _} = to, steps) do
    n = if to["invert"], do: -steps, else: steps
    {ins ++ encoder(to, n), sur ++ [{:clicks, m.control, n}], c}
  end

  defp relative({ins, sur, c}, m, to, steps) do
    case target_key(to) do
      nil ->
        {ins, sur, c}

      key ->
        current = Bindings.value(c.bindings, key) || 0.5
        set({ins, sur, c}, m, to, key, clamp(current + steps * @relative_step))
    end
  end

  defp absolute({ins, sur, c, accs}, m, last, %{"encoder" => _} = to, i, v) do
    if last == nil do
      {ins, sur, c, accs}
    else
      sign = if to["invert"], do: -1, else: 1
      acc = Map.get(accs, i, 0.0) + (v - last) * clicks_per_sweep(to) * sign
      n = trunc(acc)
      accs = Map.put(accs, i, acc - n)

      if n == 0,
        do: {ins, sur, c, accs},
        else: {ins ++ encoder(to, n), sur ++ [{:clicks, m.control, n}], c, accs}
    end
  end

  defp absolute({ins, sur, c, accs}, m, _last, to, _i, v) do
    case target_key(to) do
      nil ->
        {ins, sur, c, accs}

      key ->
        {ins, sur, c} = set({ins, sur, c}, m, to, key, v)
        {ins, sur, c, accs}
    end
  end

  defp set({ins, sur, c}, m, to, key, v) do
    case Bindings.absolute(c.bindings, key, "midi:#{m.key}:#{m.on}", v) do
      {:send, v, b} -> {ins ++ [value_input(to, v)], sur ++ [{:value, m.control, key, v}], %{c | bindings: b}}
      {:ignore, b} -> {ins, sur, %{c | bindings: b}}
    end
  end

  defp value_input(%{"pot" => _}, v), do: {:pot, :master, v}

  defp value_input(%{"midi" => %{"type" => "cc"} = mi}, v),
    do: {:midi, <<0xB0 + (mi["channel"] || 1) - 1, mi["number"] || 0, round(v * 127)>>}

  defp value_input(%{"midi" => %{"type" => "pitch_bend"} = mi}, v) do
    raw = (8192 + (v - 0.5) * 2 * 8191) |> round() |> max(0) |> min(16383)
    {:midi, <<0xE0 + (mi["channel"] || 1) - 1, Bitwise.band(raw, 0x7F), Bitwise.bsr(raw, 7)>>}
  end

  defp encoder(%{"encoder" => e}, n) do
    case Enum.find(Inputs.encoders(), &(Atom.to_string(&1) == e)) do
      nil -> []
      id -> [{:encoder, id, n}]
    end
  end

  @doc "Clicks an encoder binding gets for a whole sweep of an absolute hardware control."
  def clicks_per_sweep(to), do: @pot_range_pt / (to["pt_per_click"] || @default_pt_per_click)

  @doc "The surface's key of an absolute target (`Layout.kt` `absoluteKey`), or nil."
  def target_key(%{"pot" => _}), do: "pot:master"
  def target_key(%{"midi" => %{"type" => "cc"} = mi}), do: "cc:#{mi["channel"] || 1}:#{mi["number"] || 0}"
  def target_key(%{"midi" => %{"type" => "pitch_bend"} = mi}), do: "bend:#{mi["channel"] || 1}"
  def target_key(_), do: nil

  defp value01({:cc, _, _, v}), do: v / 127
  defp value01({:channel_pressure, _, v}), do: v / 127
  defp value01({:poly_pressure, _, _, v}), do: v / 127
  defp value01({:pitch_bend, _, v}), do: v / 16383
  defp value01({:note, _, _, 0}), do: nil
  defp value01({:note, _, _, v}), do: v / 127
  defp value01({:program, _, n}), do: n / 127

  defp clamp(v), do: v |> max(0.0) |> min(1.0)

  defp rt(c, m), do: Map.get(c.runtime, m.id, %{down: false, from: nil, last: nil, acc: %{}, hist: [], mode: nil})
  defp put_rt(c, m, rt), do: %{c | runtime: Map.put(c.runtime, m.id, rt)}

  ## The surface

  @doc """
  What the surface must show, as the text `FMutate.IONif.surface/1` hands it: one line per change, fields
  separated by tabs:

      p <key> <0|1>                  a learned press went down / up (key: control id, or "<id>#<pad>")
      t <key> <0|1>                  its toggle is now off / on
      v <control> <target> <value>   an absolute target (as Layout.kt keys it) moved to value (0..1)
      e <control> <clicks>           encoder clicks sent for a knob / slider / XY pad
      h <key> <0|1>                  automap: a pad holds the FM-1 button this control is bound to (lit only)
      o <-1|1>                       automap: a pad pressed OCT− / OCT+

  The surface draws them (pressed, toggled, the knob's value, an encoder's turn and bubble), makes the control
  the owner of the target for rule 7, and does what only it can: page changes, the BEND action, a velocity
  strip's octave on OCT presses. It sends nothing to the firmware for them.
  """
  @spec surface_text([surface]) :: iodata
  def surface_text(list), do: Enum.map_intersperse(list, "\n", &line/1)

  defp line({:press, key, down}), do: ["p\t", key, "\t", bit(down)]
  defp line({:toggle, key, on}), do: ["t\t", key, "\t", bit(on)]
  defp line({:value, control, key, v}), do: ["v\t", control, "\t", key, "\t", :erlang.float_to_binary(v * 1.0, decimals: 4)]
  defp line({:clicks, control, n}), do: ["e\t", control, "\t", Integer.to_string(n)]
  defp line({:shine, key, down}), do: ["h\t", key, "\t", bit(down)]
  defp line({:octave, dir}), do: ["o\t", Integer.to_string(dir)]

  defp bit(true), do: "1"
  defp bit(false), do: "0"
end
