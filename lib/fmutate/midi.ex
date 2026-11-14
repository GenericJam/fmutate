defmodule FMutate.MIDI do
  @moduledoc """
  An instance's MIDI (HANDOFF §10): what comes in on its virtual port (`FMutate A`) and on the devices the
  player opened becomes instance inputs (`FMutate.MIDI.Map`, per source), and the MIDI clock follows,
  sends or is off.

  ## The path of a note

  Android delivers MIDI on a binder thread in the app process; the mob_midi plugin (`MobMidi`) hands the
  bytes to the process that opened the port with `enif_send` (no JSON, no main-thread hop). This process
  opens the instance's virtual port (`MobMidi.open_virtual/2`, declared in the Android manifest) and, for
  instance `"a"`, the devices `FMutate.IO` asks it to (it is IO's *player*), so the bytes come straight
  here; it maps them and casts `FMutate.Instance.input/2`, which writes the engine command to the engine's
  Port. Each message carries the sender's timestamp and when the bridge got it, so `latency/1` reports what
  the trip costs (see `docs/architecture.md`, "MIDI latency").

  ## Clock

    * `:follow` — clock, start, continue, stop and song position from every accepted source go to the
      firmware's MIDI in.
    * `:send` — FMutate is the master: this process sends start, then 24 clocks per quarter note at
      `bpm` out of the virtual port (stamped with their exact time, so receivers that honour MIDI
      timestamps get no jitter) and into the firmware's MIDI in; stop when the mode changes.
    * `:off` — clock messages are dropped both ways.

  ## Learned controls (MIDI learn)

  The current layout of the instance's firmware may have hardware controls learned onto its controls
  (`midi_in`, `FMutate.MIDI.Learn`). This process keeps them (`FMutate.MIDI.Controls`, reloaded whenever
  `FMutate.Layouts` saves a layout or the firmware changes): a matching message drives its layout control's
  bindings here, as instance inputs, and skips its default path. The on-screen control is told what to show
  through `FMutate.IONif.surface/1` (a JNI call into the surface's queue, applied once per display frame),
  never through the instrument screen's process, and only after the inputs are on their way; the lines of
  all the messages waiting in this mailbox go in one call.

  The instance's rule 7 arbiter lives here too, so the surface's absolute moves come through
  `surface_in/2` and pick up from learned hardware controls and the other way round.

  `learn/2` arms MIDI learn for the editor: the next suitable message (from any source, not played) becomes
  `{:midi_learn, id, {:ok, midi_in}}` to the caller, or `{:midi_learn, id, :timeout}` after
  #{div(15_000, 1000)} s; `cancel_learn/1` disarms it. `subscribe/1` gets `{:midi, id, {:layout, firmware,
  layout}}` whenever the current layout was saved (by the editor or by `clear_learned/2` from I/O).

  Settings (clock mode, tempo, per-source channel and note mode) are kept per instance across restarts.
  Sources are known by name, so a device keeps its settings when it is plugged in again.
  """

  use GenServer
  require Logger

  alias FMutate.{Firmware, Instance, LayoutEdit, Layouts, Paths}
  alias FMutate.MIDI.{Automap, Controls, Learn}
  alias FMutate.MIDI.Map, as: MidiMap

  @latency_samples 256
  @clock_lead_ms 4
  @bpm_range 20..300
  @learn_timeout_ms 15_000

  ## API

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def via(id), do: {:via, Registry, {FMutate.Registry, {:midi, id}}}

  @doc "The instance's virtual port name (`\"a\"` → `\"FMutate A\"`)."
  def port_name(id), do: "FMutate " <> String.upcase(id)

  @doc "The instance index of a v1 instance id (`\"a\"` → 0); also its virtual port's number."
  def index(<<c>>) when c in ?a..?z, do: c - ?a

  @doc """
  `%{clock, bpm, bend, sources, learned, automap}`: `sources` maps a source name to its settings
  (`channel`, `notes`, `automap`, `auto_order`; only the ones the player changed: others are
  `%{channel: :all, notes: :keys}`); `learned` lists the current layout's learned controls as
  `%{control, sub, on, device, message, name}` (`device` nil: any device); `automap` maps every source
  that is plugged in (and the virtual port) to `%{on, profile, assigned, open}` (`assigned`: `[{"CC 70 ch 1",
  "KNOB1"}]`, `open`: whether first touch still takes knobs / pads).
  """
  def settings(id), do: GenServer.call(via(id), :settings)

  @doc "Automap for a source (by name) on or off."
  def set_automap(id, name, on) when is_boolean(on), do: configure_source(id, name, automap: on)

  @doc "Forget a source's first-touch order: its knobs and pads are learned again from the next touch."
  def reset_automap(id, name), do: configure_source(id, name, auto_order: Automap.empty())

  @doc "Clock mode: `:follow`, `:send` or `:off`."
  def set_clock(id, mode) when mode in [:follow, :send, :off],
    do: GenServer.call(via(id), {:clock, mode})

  @doc "Tempo of the clock FMutate sends (`:send`), in BPM."
  def set_bpm(id, bpm) when bpm in @bpm_range, do: GenServer.call(via(id), {:bpm, bpm})

  @doc "A source's settings: `channel: :all | 1..16`, `notes: :keys | :firmware`."
  def configure_source(id, name, opts) when is_binary(name),
    do: GenServer.call(via(id), {:source, name, opts})

  @doc "Send MIDI out of the instance's virtual port."
  def send_out(id, bytes) when is_binary(bytes), do: GenServer.cast(via(id), {:send_out, bytes})

  @doc """
  What the MIDI trip costs, over the last #{@latency_samples} messages, in ms (`min`, `median`, `p90`,
  `max`): `delivery` from the sender's timestamp to the bridge, `to_beam` from the bridge to this process, `n`.
  """
  def latency(id), do: GenServer.call(via(id), :latency)

  @doc """
  Arm MIDI learn for gesture `on` (`FMutate.MIDI.Learn`): the caller gets `{:midi_learn, id, {:ok, midi_in}}`
  or `{:midi_learn, id, :timeout}`. A second call re-arms for the new caller and gesture.
  """
  def learn(id, on), do: GenServer.call(via(id), {:learn, self(), on})

  @doc "Stop learning."
  def cancel_learn(id), do: GenServer.call(via(id), :cancel_learn)

  @doc "Get `{:midi, id, {:layout, firmware, layout}}` whenever another process saves the current layout."
  def subscribe(id), do: GenServer.call(via(id), {:subscribe, self()})

  @doc """
  Forget learned controls of the current layout and save it: `{:control, id, sub, on}` one, or
  `{:device, name}` every input learned from that device.
  """
  def clear_learned(id, what), do: GenServer.call(via(id), {:clear, what})

  @doc false
  # FMutate.Layouts saved (or reset) a layout: the current one if it is for the running firmware
  def layout_saved(id, firmware, layout) do
    pid = Process.whereis(FMutate.Registry) && GenServer.whereis(via(id))
    if pid, do: GenServer.cast(pid, {:layout, firmware, layout, self()})
    :ok
  end

  @doc """
  An input event from the instrument surface that goes through rule 7 here (an absolute move carrying its
  control, see `FMutate.InstrumentView`).
  """
  def surface_in(id, payload), do: GenServer.cast(via(id), {:surface_in, payload})

  @doc "The surface toggled control (or pad) `key` on or off."
  def surface_toggle(id, key, on), do: GenServer.cast(via(id), {:surface_toggle, key, on})

  ## Server

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    saved = load(id)
    view = Instance.subscribe(id)

    MobMidi.open_virtual(nil, port_name(id))

    names =
      if Process.whereis(FMutate.IO) do
        # v1: every opened device plays instance "a"
        if index(id) == 0, do: :ok = FMutate.IO.attach_player(self())
        device_names(FMutate.IO.subscribe())
      else
        %{}
      end

    layout = Layouts.current(id, view.firmware)

    state = %{
      id: id,
      clock: saved[:clock] || :follow,
      bpm: saved[:bpm] || 120,
      prefs: saved[:sources] || %{},
      bend: bends?(view.firmware),
      names: names,
      virtual: nil,
      parsers: %{},
      samples: [],
      ticker: nil,
      firmware: view.firmware,
      layout: layout,
      controls: Controls.new() |> Controls.load(layout) |> Controls.seed_master(view.master),
      learn: nil,
      subscribers: %{},
      surface: Keyword.get_lazy(opts, :surface, &native_surface/0),
      shown: []
    }

    {:ok, start_clock(state)}
  end

  # the surface's queue (FMutate.IONif) on a device; nowhere on a host
  defp native_surface do
    if FMutate.IONif.loaded?(), do: &FMutate.IONif.surface/1, else: fn _text -> :ok end
  end

  @impl true
  def handle_call(:settings, _from, state) do
    names = [port_name(state.id) | Map.values(state.names)]

    {:reply,
     Map.take(state, [:clock, :bpm, :bend])
     |> Map.put(:sources, state.prefs)
     |> Map.put(:learned, learned(state.layout))
     |> Map.put(:automap, Map.new(names, &{&1, automap_summary(state, &1)})), state}
  end

  def handle_call({:clock, mode}, _from, state) do
    state = state |> stop_clock() |> Map.put(:clock, mode) |> reconfigure() |> start_clock()
    save(state)
    {:reply, :ok, state}
  end

  def handle_call({:bpm, bpm}, _from, state) do
    state = %{state | bpm: bpm}
    save(state)
    {:reply, :ok, state}
  end

  def handle_call({:source, name, opts}, _from, state) do
    prefs = Map.update(state.prefs, name, Map.new(opts), &Map.merge(&1, Map.new(opts)))
    state = reconfigure(%{state | prefs: prefs})
    save(state)
    {:reply, :ok, state}
  end

  def handle_call({:learn, pid, on}, _from, state) do
    state = disarm(state)
    timer = Process.send_after(self(), :learn_timeout, @learn_timeout_ms)
    state = reconfigure(%{state | learn: %{pid: pid, learn: Learn.new(on), timer: timer, window: nil}})
    {:reply, :ok, state}
  end

  def handle_call(:cancel_learn, _from, state), do: {:reply, :ok, disarm(state)}

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, true)}}
  end

  # Layouts.save/3 tells this process (a cast, so it is handled before any later call) to take the new layout
  def handle_call({:clear, what}, _from, state) do
    edited =
      case what do
        {:control, cid, sub, on} -> LayoutEdit.clear_midi_in(state.layout, cid, sub, on)
        {:device, name} -> LayoutEdit.clear_midi_device(state.layout, name)
      end

    with {:ok, layout} <- edited, :ok <- Layouts.save(state.id, state.firmware, layout) do
      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call(:latency, _from, state) do
    {delivery, to_beam} = Enum.unzip(state.samples)

    {:reply, %{n: length(state.samples), delivery: summary(delivery), to_beam: summary(to_beam)},
     state}
  end

  @impl true
  def handle_cast({:send_out, bytes}, state) do
    out(state, bytes, 0)
    {:noreply, state}
  end

  def handle_cast({:layout, firmware, layout, saver}, %{firmware: firmware} = state),
    do: {:noreply, use_layout(state, layout, saver)}

  def handle_cast({:layout, _other_firmware, _layout, _saver}, state), do: {:noreply, state}

  def handle_cast({:surface_in, payload}, state) do
    {event, controls} = Controls.touch(state.controls, payload)
    if event, do: Instance.input(state.id, event)
    {:noreply, %{state | controls: controls}}
  end

  def handle_cast({:surface_toggle, key, on}, state),
    do: {:noreply, %{state | controls: Controls.toggled(state.controls, key, on)}}

  # from FMutate.IO: play a device (all its output ports)
  def handle_cast({:open_device, device, ports}, state) do
    for port <- 0..(ports - 1)//1, do: MobMidi.open_input(nil, device, port: port)
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:midi, :raw,
         %{device: device, port: port, bytes: bytes, timestamp: sent_ns, received: recv_ns}},
        state
      ) do
    now = MobMidi.now_ns()
    source = {device, port}
    state = ensure_source(state, source)
    {events, parser} = MidiMap.feed(state.parsers[source], bytes)
    state = %{state | parsers: Map.put(state.parsers, source, parser)}
    state = Enum.reduce(events, state, &event(&2, source, &1))
    sample = {(recv_ns - sent_ns) / 1.0e6, (now - recv_ns) / 1.0e6}
    {:noreply, %{state | samples: Enum.take([sample | state.samples], @latency_samples)}}
  end

  # what the learned controls show, in one call for everything this mailbox had waiting
  def handle_info(:show, state) do
    _ = state.surface.(Controls.surface_text(Enum.reverse(state.shown)))
    {:noreply, %{state | shown: []}}
  end

  def handle_info(:learn_timeout, %{learn: %{pid: pid}} = state) do
    send(pid, {:midi_learn, state.id, :timeout})
    {:noreply, disarm(state)}
  end

  def handle_info(:learn_timeout, state), do: {:noreply, state}

  # a CC's learn window ended
  def handle_info({:learn_window, ref}, %{learn: %{window: ref, pid: pid} = l} = state) do
    case Learn.finish(l.learn) do
      nil -> :ok
      midi_in -> send(pid, {:midi_learn, state.id, {:ok, midi_in}})
    end

    {:noreply, disarm(state)}
  end

  def handle_info({:learn_window, _stale}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = %{state | subscribers: Map.delete(state.subscribers, pid)}
    state = if match?(%{pid: ^pid}, state.learn), do: disarm(state), else: state
    {:noreply, state}
  end

  def handle_info({:midi, :opened, %{direction: :virtual, device: device}}, state),
    do: {:noreply, %{state | virtual: device}}

  def handle_info({:midi, :virtual_status, %{senders: senders, listeners: listeners}}, state) do
    FMutate.IO.virtual_status(index(state.id), port_name(state.id), senders, listeners)
    {:noreply, state}
  end

  def handle_info({:midi, :opened, %{direction: :input, device: device}}, state) do
    send(FMutate.IO, {:device_opened, device})
    {:noreply, state}
  end

  def handle_info({:midi, :error, %{op: :open_input, device: device, reason: reason}}, state) do
    send(FMutate.IO, {:device_failed, device, reason})
    {:noreply, state}
  end

  def handle_info({:midi, :error, %{op: :open_virtual, reason: reason}}, state) do
    Logger.warning("midi: #{port_name(state.id)} not available (#{reason})")
    {:noreply, state}
  end

  def handle_info({:io, io}, state) do
    names = device_names(io)
    # a source whose device went away lets go of its keys
    gone =
      for {{device, _} = src, _} <- state.parsers,
          device != state.virtual,
          not Map.has_key?(names, device),
          do: src

    {:noreply, %{release_sources(state, gone) | names: names}}
  end

  def handle_info({:instance, id, {:state, view}}, %{id: id} = state) do
    bend = bends?(view.firmware)

    state =
      if view.firmware == state.firmware,
        do: state,
        else: use_layout(%{state | firmware: view.firmware}, Layouts.current(id, view.firmware))

    if bend == state.bend,
      do: {:noreply, state},
      else: {:noreply, reconfigure(%{state | bend: bend})}
  end

  def handle_info({:instance, _id, _event}, state), do: {:noreply, state}

  def handle_info({:tick, ref}, %{ticker: {ref, next_ns, interval_ns}} = state) do
    out(state, <<0xF8>>, next_ns)
    Instance.input(state.id, {:midi, <<0xF8>>})
    {:noreply, schedule_tick(state, ref, next_ns + interval_ns)}
  end

  def handle_info({:tick, _stale}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  ## Sources

  defp source_name(%{virtual: device} = state, {device, _port}), do: port_name(state.id)

  defp source_name(state, {device, port}),
    do: Map.get(state.names, device, "device #{device}") <> port_suffix(port)

  defp port_suffix(0), do: ""
  defp port_suffix(port), do: " · port #{port + 1}"

  # a source's parser, made with its settings (and its automap) the first time it plays
  defp ensure_source(state, source) do
    if Map.has_key?(state.parsers, source) do
      state
    else
      name = source_name(state, source)
      state = refresh_auto(state, name)
      %{state | parsers: Map.put(state.parsers, source, MidiMap.new(options(state, name)))}
    end
  end

  defp options(state, name) do
    pref = Map.get(state.prefs, name, %{})
    auto = automap?(state, name)

    [
      channel: pref[:channel] || :all,
      notes: pref[:notes] || :keys,
      bend: state.bend,
      clock: state.clock,
      learned: Controls.keys(state.controls, name),
      learning: state.learn != nil,
      auto: Controls.auto_keys(state.controls, name),
      auto_open: if(auto, do: Automap.open(name, auto_order(state, name)), else: %{knobs: false, pads: false})
    ]
  end

  defp reconfigure(state) do
    state = Enum.reduce(state.parsers, state, fn {src, _}, st -> refresh_auto(st, source_name(st, src)) end)

    parsers =
      Map.new(state.parsers, fn {src, p} ->
        {src, MidiMap.configure(p, options(state, source_name(state, src)))}
      end)

    %{state | parsers: parsers}
  end

  ## Automap (FMutate.MIDI.Automap): on by default for devices, off for the virtual port (apps)

  defp automap?(state, name), do: Map.get(Map.get(state.prefs, name, %{}), :automap, name != port_name(state.id))
  defp auto_order(state, name), do: get_in(state.prefs, [name, :auto_order]) || Automap.empty()

  defp automap_summary(state, name) do
    order = auto_order(state, name)

    assigned =
      for {{type, ch, n}, _i, _kind, target} <- Automap.assignments(name, order) do
        what = if type == :cc, do: "CC #{n} ch #{ch}", else: "note #{n} ch #{ch}"
        {what, Automap.target_name(target)}
      end

    %{
      on: automap?(state, name),
      profile: with(%{name: p} <- Automap.profile(name), do: p),
      assigned: assigned,
      open: Automap.open(name, order)
    }
  end

  defp refresh_auto(state, name) do
    assignments = if automap?(state, name), do: Automap.assignments(name, auto_order(state, name)), else: []
    %{state | controls: Controls.put_auto(state.controls, name, assignments)}
  end

  # first touch: a new knob or pad joins the source's order (kept with its settings)
  defp first_touch(state, source, name, ev) do
    case Automap.touch(name, auto_order(state, name), ev) do
      :same ->
        state

      {:new, order} ->
        prefs = Map.update(state.prefs, name, %{auto_order: order}, &Map.put(&1, :auto_order, order))
        state = refresh_auto(%{state | prefs: prefs}, name)
        save(state)
        parser = MidiMap.configure(state.parsers[source], options(state, name))
        %{state | parsers: Map.put(state.parsers, source, parser)}
    end
  end

  defp release_sources(state, sources) do
    Enum.reduce(sources, state, fn src, st ->
      {inputs, _} = MidiMap.release_all(st.parsers[src])
      for input <- inputs, do: Instance.input(st.id, input)
      {inputs, shown, controls} = Controls.release_source(st.controls, source_name(st, src))
      st = show(%{st | controls: controls}, inputs, shown)
      %{st | parsers: Map.delete(st.parsers, src)}
    end)
  end

  ## Events from the parsers

  defp event(state, _source, {:key, _, _} = input), do: input!(state, input)
  defp event(state, _source, {:midi, _} = input), do: input!(state, input)

  defp event(state, source, {:learned, ev}) do
    {inputs, shown, controls} = Controls.handle(state.controls, source_name(state, source), ev)
    show(%{state | controls: controls}, inputs, shown)
  end

  defp event(state, source, {:auto, ev}) do
    name = source_name(state, source)
    state = first_touch(state, source, name, ev)
    {inputs, shown, controls} = Controls.handle_auto(state.controls, name, ev)
    show(%{state | controls: controls}, inputs, shown)
  end

  defp event(%{learn: %{} = l} = state, source, {:learn, ev}) do
    case Learn.offer(l.learn, source_name(state, source), ev) do
      {:done, midi_in} ->
        send(l.pid, {:midi_learn, state.id, {:ok, midi_in}})
        disarm(state)

      {:window, learn} ->
        ref = make_ref()
        Process.send_after(self(), {:learn_window, ref}, Learn.window_ms())
        %{state | learn: %{l | learn: learn, window: ref}}

      {:wait, learn} ->
        %{state | learn: %{l | learn: learn}}

      :ignore ->
        state
    end
  end

  defp event(state, _source, {:learn, _ev}), do: state

  defp input!(state, input) do
    Instance.input(state.id, input)
    state
  end

  # the inputs first, then (once the mailbox is through) what the surface shows
  defp show(state, inputs, shown) do
    for input <- inputs, do: Instance.input(state.id, input)

    if shown != [] and state.shown == [], do: send(self(), :show)
    %{state | shown: Enum.reverse(shown, state.shown)}
  end

  defp disarm(%{learn: nil} = state), do: state

  defp disarm(%{learn: l} = state) do
    Process.cancel_timer(l.timer)
    reconfigure(%{state | learn: nil})
  end

  defp use_layout(state, layout, saver \\ nil) do
    # the process that saved it (the editor) has it already
    for pid <- Map.keys(state.subscribers), pid != saver, do: send(pid, {:midi, state.id, {:layout, state.firmware, layout}})
    reconfigure(%{state | layout: layout, controls: Controls.load(state.controls, layout)})
  end

  defp learned(layout) do
    for {c, sub, m} <- LayoutEdit.midi_ins(layout) do
      %{control: c["id"], sub: sub, on: m["on"], device: m["device"], message: Learn.message(m), name: control_name(c, sub)}
    end
  end

  defp control_name(%{"type" => "pad_grid"} = c, sub) do
    pad = c |> get_in(["pad_grid", "pads"]) |> Enum.at(sub, %{})
    "pad " <> if((pad["label"] || "") == "", do: "#{sub + 1}", else: pad["label"])
  end

  defp control_name(c, _sub) do
    type = String.downcase(LayoutEdit.type_name(c["type"]))
    if (c["label"] || "") == "", do: type, else: "#{c["label"]} #{type}"
  end

  defp device_names(%{midi: devices}), do: Map.new(devices, &{&1.id, &1.name})
  defp device_names(_), do: %{}

  defp bends?(firmware_id) do
    case firmware_id && Firmware.get(firmware_id) do
      %{caps: caps} -> Map.get(caps, :pitch_bend, false)
      _ -> false
    end
  end

  ## Clock out

  defp start_clock(%{clock: :send} = state) do
    out(state, <<0xFA>>, 0)
    Instance.input(state.id, {:midi, <<0xFA>>})
    schedule_tick(state, make_ref(), now_ns() + interval_ns(state))
  end

  defp start_clock(state), do: state

  defp stop_clock(%{ticker: {_, _, _}} = state) do
    out(state, <<0xFC>>, 0)
    Instance.input(state.id, {:midi, <<0xFC>>})
    %{state | ticker: nil}
  end

  defp stop_clock(state), do: state

  defp interval_ns(state), do: round(60.0e9 / (state.bpm * 24))

  # Wake a little before the tick and stamp it with its exact time; a tempo change applies from the next tick.
  # After a stall (app paused) restart from now instead of sending the missed ticks in a burst.
  defp schedule_tick(state, ref, next_ns) do
    now = now_ns()
    next_ns = if next_ns < now - 50_000_000, do: now, else: next_ns
    wake_ms = max(0, div(next_ns - now, 1_000_000) - @clock_lead_ms)
    Process.send_after(self(), {:tick, ref}, wake_ms)
    %{state | ticker: {ref, next_ns, interval_ns(state)}}
  end

  # out of the virtual port, stamped `timestamp_ns` (0 = now); nobody listening is fine
  defp out(%{virtual: nil}, _bytes, _timestamp_ns), do: :ok

  defp out(state, bytes, timestamp_ns),
    do: MobMidi.send_raw(nil, state.virtual, bytes, at: timestamp_ns)

  defp now_ns, do: MobMidi.now_ns()

  ## Stats, persistence

  defp summary([]), do: nil

  defp summary(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    at = fn q -> Enum.at(sorted, min(n - 1, trunc(q * n))) |> Float.round(3) end
    %{min: at.(0.0), median: at.(0.5), p90: at.(0.9), max: Float.round(List.last(sorted), 3)}
  end

  defp load(id) do
    case File.read(Paths.midi_settings(id)) do
      {:ok, bin} -> :erlang.binary_to_term(bin, [:safe])
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp save(state) do
    data = %{clock: state.clock, bpm: state.bpm, sources: state.prefs}
    File.write!(Paths.midi_settings(state.id), :erlang.term_to_binary(data))
  end
end
