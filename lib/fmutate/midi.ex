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
  through `FMutate.IONif.surface/1` (Android: a JNI call into the surface's queue, applied once per display
  frame) or `FMutate.SurfaceNif.surface/1` (iOS: the Swift surface's queue, applied on the main thread), never
  through the instrument screen's process, and only after the inputs are on their way; the lines of all the
  messages waiting in this mailbox go in one call.

  The instance's rule 7 arbiter lives here too, so the surface's absolute moves come through
  `surface_in/2` and pick up from learned hardware controls and the other way round.

  `learn/2` arms MIDI learn for the editor: the next suitable message (from any source, not played) becomes
  `{:midi_learn, id, {:ok, midi_in}}` to the caller, or `{:midi_learn, id, :timeout}` after
  #{div(15_000, 1000)} s; `cancel_learn/1` disarms it. `subscribe/1` gets `{:midi, id, {:layout, firmware,
  layout}}` whenever the current layout was saved (by the editor or by `clear_learned/2` from I/O).

  ## MIDI out from the surface

  A layout binding to a MIDI message has a destination (`FMutate.MIDI.Out`): synth (the firmware's MIDI in, as
  always), out, or both. What goes out (from the surface, `surface_in/2`, and from learned hardware controls)
  is sent from here to every output: the instance's virtual port (always) and the devices switched on with
  `set_output/3` (kept per instance by name, opened again when they come back), stamped with the time the
  hardware message had when it came from one (surface events carry none: now). Nothing of it reaches the
  firmware, and firmware switches, crashes and sound loads don't touch it. `release_out/1` lets go of every
  note still held out (release-all, a page change, leaving the instrument, quit). `outputs/1` lists the
  outputs with what each was sent.

  Settings (clock mode, tempo, per-source channel and note mode) are kept per instance across restarts.
  Sources are known by name, so a device keeps its settings when it is plugged in again.
  """

  use GenServer
  require Logger

  alias FMutate.{Firmware, Instance, LayoutEdit, Layouts, Paths}
  alias FMutate.MIDI.{Automap, Controls, Learn, Mapping, Out, Params}
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
  (`channel`, `notes`, `automap`, `auto_order`, `unmapped`, `pins`; only the ones the player changed: others
  are `%{channel: :all, notes: :keys}`); `learned` lists the current layout's learned controls as
  `%{control, sub, on, device, message, name, match}` (`device` nil: any device); `automap` maps every source
  that is plugged in (and the virtual port) to `%{on, profile, program, by, open, unmapped, rows, free}`:
  `rows` what each of its hardware controls drives (`FMutate.MIDI.Mapping`), `free` the panel targets no
  knob drives, `program` the known controller's program its CCs fit, `by` where its knobs come from
  (`FMutate.MIDI.Automap`), `open` whether first touch still takes knobs / pads.
  """
  def settings(id), do: GenServer.call(via(id), :settings)

  @doc "Automap for a source (by name) on or off."
  def set_automap(id, name, on) when is_boolean(on), do: configure_source(id, name, automap: on)

  @doc """
  Forget a source's knob and pad order (first touch, its program, a line-up): they are taken again from the
  next touch. Its pins stay.
  """
  def reset_automap(id, name), do: configure_source(id, name, auto_order: Automap.empty())

  @doc """
  What a source's CCs that drive nothing in FMutate do: `:synth` (to the firmware's MIDI in, where its own
  MIDI map may change the sound) or `:drop`.
  """
  def set_unmapped(id, name, mode) when mode in [:synth, :drop], do: configure_source(id, name, unmapped: mode)

  @doc """
  Pin a source's knob (`{channel, cc}`) to a synth parameter of the running firmware by its label
  (`FMutate.MIDI.Params.label/1`, e.g. `"PERFORM · CUTOFF"`), or unpin it (nil). Kept per device name and
  firmware: the knob then sends that parameter's CC to the firmware's MIDI in (on the knob's channel), and
  drives no panel knob. `{:error, :unknown}` when the firmware has no such parameter.
  """
  def pin(id, name, {ch, cc} = knob, label) when ch in 1..16 and cc in 0..127 and (is_binary(label) or label == nil),
    do: GenServer.call(via(id), {:pin, name, knob, label})

  @doc """
  Put a source's knob (`{channel, cc}`) on panel slot `slot` (1 KNOB1 … 8 MASTER), as one step of a line-up:
  the knob it had moves to where this one was. Unpins the knob on the running firmware.
  """
  def place(id, name, {ch, cc} = knob, slot) when ch in 1..16 and cc in 0..127 and slot in 1..8,
    do: GenServer.call(via(id), {:place, name, knob, slot})

  @doc """
  Start lining up a source's knobs (the I/O screen's guided flow): its messages drive nothing while it runs;
  each new knob CC takes the next panel target (KNOB1, KNOB2, … MASTER). The caller gets `{:midi, id,
  {:line_up, %{source, step, slots}}}` at the start and after each step, and `{:midi, id, {:line_up, nil}}`
  when it ends. `line_up_skip/1` leaves the current target out, `line_up_done/1` keeps the result as the
  source's order, `line_up_cancel/1` forgets it.
  """
  def line_up(id, name) when is_binary(name), do: GenServer.call(via(id), {:line_up, self(), name})

  @doc "Skip the target the line-up is at."
  def line_up_skip(id), do: GenServer.call(via(id), :line_up_skip)

  @doc "End the line-up, keeping its order (the targets not reached or skipped drive nothing)."
  def line_up_done(id), do: GenServer.call(via(id), :line_up_done)

  @doc "End the line-up, keeping the order the source had."
  def line_up_cancel(id), do: GenServer.call(via(id), :line_up_cancel)

  @doc """
  Hear which hardware control moved: `{:midi, id, {:touched, source, key}}` (`FMutate.MIDI.Map.key/1`, at most
  every #{150} ms for the same control) and `{:midi, id, {:changed, source}}` when what its table shows
  changed (a new knob, a program).
  """
  def watch(id), do: GenServer.call(via(id), {:watch, self()})

  @doc "Clock mode: `:follow`, `:send` or `:off`."
  def set_clock(id, mode) when mode in [:follow, :send, :off],
    do: GenServer.call(via(id), {:clock, mode})

  @doc "Tempo of the clock FMutate sends (`:send`), in BPM."
  def set_bpm(id, bpm) when bpm in @bpm_range, do: GenServer.call(via(id), {:bpm, bpm})

  @doc """
  A source's settings: `channel: :all | 1..16`, `notes: :keys | :firmware`, `automap: boolean`,
  `unmapped: :synth | :drop`, `auto_order` (`FMutate.MIDI.Automap`).
  """
  def configure_source(id, name, opts) when is_binary(name),
    do: GenServer.call(via(id), {:source, name, opts})

  @doc "Send MIDI out of the instance's virtual port."
  def send_out(id, bytes) when is_binary(bytes), do: GenServer.cast(via(id), {:send_out, bytes})

  @doc """
  The MIDI outputs: the virtual port first (always on), then every device with a port FMutate can write to:
  `%{name, type, device, on, status, sent, bytes, last, error}`. `type` `:port` (the virtual port) or the
  device's (`:usb`, `:bluetooth`, `:virtual`); `status` `:open`, `:opening`, `:off`, `:unavailable` (no virtual
  port) or `{:error, reason}` (it didn't open); `sent` / `bytes` what went out of it, `last` the last message,
  `error` the last send's error (nil once a send goes through; `:no_listener` on the virtual port: no app).
  """
  def outputs(id), do: GenServer.call(via(id), :outputs)

  @doc "Send MIDI out to a device (by name) or stop; kept per instance, and opened whenever it is plugged in."
  def set_output(id, name, on) when is_binary(name) and is_boolean(on), do: GenServer.call(via(id), {:output, name, on})

  @doc """
  Let go of everything held out: a note off for each note still on, then CC 123 on the channels notes went out
  on. Waits until they are sent; `:ok` also when the instance's MIDI isn't running.
  """
  def release_out(id) do
    GenServer.call(via(id), :release_out)
  catch
    :exit, _ -> :ok
  end

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
    # terminate/2 lets go of what is held out when the app stops
    Process.flag(:trap_exit, true)
    saved = load(id)
    view = Instance.subscribe(id)

    MobMidi.open_virtual(nil, port_name(id))

    io =
      if Process.whereis(FMutate.IO) do
        # v1: every opened device plays instance "a"
        if index(id) == 0, do: :ok = FMutate.IO.attach_player(self())
        FMutate.IO.subscribe()
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
      names: device_names(io),
      devices: Map.get(io, :midi, []),
      virtual: nil,
      parsers: %{},
      samples: [],
      ticker: nil,
      firmware: view.firmware,
      layout: layout,
      controls:
        Controls.new()
        |> Controls.load(layout)
        |> Controls.seed_master(view.master)
        |> Controls.seed_balance(view.balance),
      learn: nil,
      lineup: nil,
      subscribers: %{},
      watchers: %{},
      touched: %{},
      seen: %{},
      params: Params.of(view.firmware),
      surface: Keyword.get_lazy(opts, :surface, &native_surface/0),
      shown: [],
      # MIDI out (FMutate.MIDI.Out): the devices switched on (by name), their ports' state by device id, what each
      # output (by name) was sent, what the outputs hold, the timestamp of the hardware message being handled
      enabled: MapSet.new(saved[:outputs] || []),
      opened: %{},
      stats: %{},
      out: Out.new(),
      at: 0,
      # the mob_midi boundary for output ports (tests fake it)
      midi_out: Keyword.get(opts, :midi_out, &mob_midi_out/1)
    }

    {:ok, state |> sync_outputs() |> start_clock()}
  end

  defp mob_midi_out({:open, device}), do: MobMidi.open_output(nil, device)
  defp mob_midi_out({:close, device}), do: MobMidi.close(nil, device)
  defp mob_midi_out({:send, device, bytes, at}), do: MobMidi.send_raw(nil, device, bytes, at: at)

  # the surface's queue on a device (Android: FMutate.IONif; iOS: FMutate.SurfaceNif); nowhere on a host
  defp native_surface do
    cond do
      FMutate.IONif.loaded?() -> &FMutate.IONif.surface/1
      FMutate.SurfaceNif.loaded?() -> &FMutate.SurfaceNif.surface/1
      true -> fn _text -> :ok end
    end
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

  def handle_call(:outputs, _from, state), do: {:reply, outputs_view(state), state}

  def handle_call({:output, name, true}, _from, state) do
    state = sync_outputs(%{state | enabled: MapSet.put(state.enabled, name)})
    save(state)
    {:reply, :ok, state}
  end

  def handle_call({:output, name, false}, _from, state) do
    state = Enum.reduce(state.devices, state, fn d, st -> if d.name == name, do: output_off(st, d), else: st end)
    state = %{state | enabled: MapSet.delete(state.enabled, name)}
    save(state)
    {:reply, :ok, state}
  end

  def handle_call(:release_out, _from, state), do: {:reply, :ok, release_out_now(state)}

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

  def handle_call({:watch, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | watchers: Map.put(state.watchers, pid, true)}}
  end

  def handle_call({:pin, name, knob, label}, _from, state) do
    pins = source_pref(state, name, :pins, %{})
    mine = Map.get(pins, state.firmware, %{})

    cond do
      label == nil ->
        {:reply, :ok, configured(state, name, :pins, Map.put(pins, state.firmware, Map.delete(mine, knob)))}

      Params.by_label(state.params, label) ->
        {:reply, :ok, configured(state, name, :pins, Map.put(pins, state.firmware, Map.put(mine, knob, label)))}

      true ->
        {:reply, {:error, :unknown}, state}
    end
  end

  def handle_call({:place, name, knob, slot}, _from, state) do
    order = Automap.place(name, auto_order(state, name), knob, slot)
    pins = source_pref(state, name, :pins, %{})
    pins = Map.update(pins, state.firmware, %{}, &Map.delete(&1, knob))
    state = put_pref(state, name, :pins, pins)
    {:reply, :ok, configured(state, name, :auto_order, order)}
  end

  def handle_call({:line_up, pid, name}, _from, state) do
    state = line_up_end(state)
    knobs = List.duplicate(nil, length(Automap.knob_targets()))
    lu = %{pid: pid, ref: Process.monitor(pid), source: name, step: 0, knobs: knobs}
    state = reconfigure(%{state | lineup: lu})
    {:reply, :ok, line_up_tell(state, name)}
  end

  def handle_call(:line_up_skip, _from, %{lineup: %{} = lu} = state) do
    step = min(lu.step + 1, length(lu.knobs))
    {:reply, :ok, line_up_tell(%{state | lineup: %{lu | step: step}}, lu.source)}
  end

  def handle_call(:line_up_done, _from, %{lineup: %{} = lu} = state) do
    order = Automap.line_up(auto_order(state, lu.source), lu.knobs)
    state = put_pref(state, lu.source, :auto_order, order)
    state = line_up_end(state)
    save(state)
    {:reply, :ok, state}
  end

  def handle_call(:line_up_cancel, _from, state), do: {:reply, :ok, line_up_end(state)}
  def handle_call(msg, _from, state) when msg in [:line_up_skip, :line_up_done], do: {:reply, :ok, state}

  # Layouts.save/3 tells this process (a cast, so it is handled before any later call) to take the new layout.
  # The edit is made to the layout as saved when it is written (Layouts.update/3), not to this process's copy,
  # so an undo or an edit that lands first isn't lost.
  def handle_call({:clear, what}, _from, state) do
    edit = fn layout ->
      case what do
        {:control, cid, sub, on} -> LayoutEdit.clear_midi_in(layout, cid, sub, on)
        {:device, name} -> LayoutEdit.clear_midi_device(layout, name)
      end
    end

    {:reply, Layouts.update(state.id, state.firmware, edit), state}
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

  # an absolute move through rule 7, or a MIDI message the surface sends out: to where its binding sends it
  def handle_cast({:surface_in, payload}, state) do
    {event, controls} = Controls.touch(state.controls, payload)
    {:noreply, deliver(%{state | controls: controls}, Out.route(event, Out.payload_dest(payload)))}
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
    name = source_name(state, source)
    # what learned controls send out keeps the hardware message's time
    state = Enum.reduce(events, %{state | at: sent_ns}, &(&2 |> event(source, &1) |> moved(name, moved_key(&1))))
    sample = {(recv_ns - sent_ns) / 1.0e6, (now - recv_ns) / 1.0e6}
    {:noreply, %{state | at: 0, samples: Enum.take([sample | state.samples], @latency_samples)}}
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
    state = %{state | subscribers: Map.delete(state.subscribers, pid), watchers: Map.delete(state.watchers, pid)}
    state = if match?(%{pid: ^pid}, state.learn), do: disarm(state), else: state
    state = if match?(%{pid: ^pid}, state.lineup), do: line_up_end(state), else: state
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

  # (an output switched off while it opened stays off)
  def handle_info({:midi, :opened, %{direction: :output, device: device}}, state) do
    if Map.has_key?(state.opened, device),
      do: {:noreply, %{state | opened: Map.put(state.opened, device, :open)}},
      else: {:noreply, state}
  end

  # an output that didn't open (or whose open close/2 cancelled): shown on its row
  def handle_info({:midi, :error, %{op: :open_output, device: device, reason: reason}}, state) do
    if Map.has_key?(state.opened, device),
      do: {:noreply, %{state | opened: Map.put(state.opened, device, {:error, reason})}},
      else: {:noreply, state}
  end

  # FMutate.IO closed the device (every port of it): an output still switched on opens again
  def handle_info({:device_closed, device}, state),
    do: {:noreply, sync_outputs(%{state | opened: Map.delete(state.opened, device)})}

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

    state = %{release_sources(state, gone) | names: names, devices: Map.get(io, :midi, [])}
    {:noreply, sync_outputs(state)}
  end

  def handle_info({:instance, id, {:state, view}}, %{id: id} = state) do
    bend = bends?(view.firmware)

    state =
      if view.firmware == state.firmware,
        do: state,
        else: use_layout(%{state | firmware: view.firmware, params: Params.of(view.firmware)}, Layouts.current(id, view.firmware))

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

    [
      channel: pref[:channel] || :all,
      notes: pref[:notes] || :keys,
      bend: state.bend,
      clock: state.clock,
      learned: Controls.keys(state.controls, name),
      learning: state.learn != nil or match?(%{source: ^name}, state.lineup),
      auto: Controls.auto_keys(state.controls, name),
      auto_open: auto_open(state, name),
      unmapped: pref[:unmapped] || :synth
    ]
  end

  # what first touch takes from a source, and the CCs that always go to the firmware (a joystick; with automap
  # off every joystick CC of its profile, the mk2's CC 1 included, which its PROG 1 shares with K1)
  defp auto_open(state, name) do
    if automap?(state, name),
      do: Automap.open(name, auto_order(state, name)),
      else: %{knobs: false, pads: false, pass: Automap.joystick(name)}
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

  defp source_pref(state, name, key, default), do: Map.get(Map.get(state.prefs, name, %{}), key, default)
  defp automap?(state, name), do: source_pref(state, name, :automap, name != port_name(state.id))
  defp auto_order(state, name), do: Automap.normalize(source_pref(state, name, :auto_order, Automap.empty()))

  # a source's pins on the running firmware, resolved against its parameter list: %{{ch, cc} => param}
  defp pins(state, name) do
    for {k, label} <- get_in(state.prefs, [name, :pins, state.firmware]) || %{},
        p = Params.by_label(state.params, label),
        p != nil,
        into: %{},
        do: {k, p}
  end

  defp put_pref(state, name, key, value) do
    prefs = Map.update(state.prefs, name, %{key => value}, &Map.put(&1, key, value))
    %{state | prefs: prefs}
  end

  # a source setting changed by the player: applied, saved, and the watchers' tables refreshed
  defp configured(state, name, key, value) do
    state = state |> put_pref(name, key, value) |> reconfigure()
    save(state)
    notify_watchers(state, {:changed, name})
    state
  end

  defp automap_summary(state, name) do
    order = auto_order(state, name)
    src = mapping_source(state, name)
    program = Automap.program(name, order)

    %{
      on: src.automap,
      profile: with(%{name: p} <- Automap.profile(name), do: p),
      program: program && program.name,
      factory: program != nil and order.by == :auto,
      by: order.by,
      open: Automap.open(name, order) |> Map.take([:knobs, :pads]),
      unmapped: src.unmapped,
      rows: Mapping.rows(src),
      free: Mapping.free(src)
    }
  end

  defp mapping_source(state, name) do
    fw = state.firmware && Firmware.get(state.firmware)

    %{
      name: name,
      automap: automap?(state, name),
      order: auto_order(state, name),
      pins: pins(state, name),
      learned: Enum.filter(learned(state.layout), &(&1.device in [nil, name])),
      seen: Map.get(state.seen, name, []),
      unmapped: source_pref(state, name, :unmapped, :synth),
      firmware: (fw && fw.name) || "the firmware",
      params: state.params,
      pass: auto_open(state, name).pass
    }
  end

  defp refresh_auto(state, name) do
    order = auto_order(state, name)
    auto = if automap?(state, name), do: Automap.assignments(name, order), else: []

    pins =
      for {{ch, cc}, p} <- pins(state, name),
          do: {{:cc, ch, cc}, nil, :pin, %{"midi" => %{"type" => "cc", "channel" => ch, "number" => p.cc}}}

    tags = Mapping.tags(name, order, for({m, _, _, _} <- auto ++ pins, do: m))
    %{state | controls: Controls.put_auto(state.controls, name, auto ++ pins, tags)}
  end

  # first touch: a new knob or pad joins the source's order, or a known controller's CCs tell its program
  # (kept with its settings)
  defp first_touch(state, source, name, ev) do
    case Automap.touch(name, auto_order(state, name), ev) do
      :same ->
        state

      {:new, order} ->
        state = refresh_auto(put_pref(state, name, :auto_order, order), name)
        save(state)
        notify_watchers(state, {:changed, name})
        parser = MidiMap.configure(state.parsers[source], options(state, name))
        %{state | parsers: Map.put(state.parsers, source, parser)}
    end
  end

  ## Line up (the I/O screen's guided flow): the player turns the knob they want for KNOB1, then KNOB2, …

  defp line_up_take(%{lineup: lu} = state, name, {:cc, ch, cc, _v}) do
    k = {ch, cc}
    targets = length(Automap.knob_targets())

    if Automap.knob_cc?(cc) and k not in lu.knobs and lu.step < targets do
      knobs = List.replace_at(lu.knobs, lu.step, k)
      step = Enum.find_index(knobs, &is_nil/1) || targets
      line_up_tell(%{state | lineup: %{lu | knobs: knobs, step: max(step, lu.step + 1) |> min(targets)}}, name)
    else
      state
    end
  end

  defp line_up_take(state, _name, _ev), do: state

  defp line_up_tell(%{lineup: lu} = state, name) do
    send(lu.pid, {:midi, state.id, {:line_up, line_up_view(state, name)}})
    state
  end

  defp line_up_view(%{lineup: lu} = state, name) do
    order = auto_order(state, name)
    lined = Enum.reject(lu.knobs, &is_nil/1)
    known = %{order | seen: Enum.uniq(order.seen ++ lined)}

    slots =
      for {t, k} <- Enum.zip(Automap.knob_targets(), lu.knobs) do
        %{target: Automap.target_name(t), key: k, label: k && knob_label(name, known, k)}
      end

    %{source: name, step: lu.step, slots: slots}
  end

  defp knob_label(name, order, {ch, cc} = k) do
    msg = if ch == 1, do: "CC #{cc}", else: "CC #{cc} ch #{ch}"

    case Automap.hardware_name(name, order, k) do
      nil -> msg
      hw -> "#{hw} (#{msg})"
    end
  end

  defp line_up_end(%{lineup: nil} = state), do: state

  defp line_up_end(%{lineup: lu} = state) do
    Process.demonitor(lu.ref, [:flush])
    send(lu.pid, {:midi, state.id, {:line_up, nil}})
    reconfigure(%{state | lineup: nil})
  end

  ## Watchers (the I/O screen): which hardware control moved, for its table

  @touch_every_ms 150
  @seen_max 24

  # the CC or pad a parser output is about, or nil
  defp moved_key({kind, ev}) when kind in [:auto, :learned, :learn, :dropped], do: MidiMap.key(ev)
  defp moved_key({:midi, <<st, cc, _v>>}) when st in 0xB0..0xBF, do: {:cc, rem(st, 16) + 1, cc}
  defp moved_key(_out), do: nil

  defp moved(state, _name, nil), do: state

  defp moved(state, name, key) do
    state = remember_seen(state, name, key)

    if state.watchers == %{} do
      state
    else
      now = System.monotonic_time(:millisecond)

      case Map.get(state.touched, name) do
        {^key, at} when now - at < @touch_every_ms ->
          state

        _ ->
          notify_watchers(state, {:touched, name, key})
          %{state | touched: Map.put(state.touched, name, {key, now})}
      end
    end
  end

  # knob CCs that came from a source this session: its table lists them with what they do
  defp remember_seen(state, name, {:cc, _ch, cc} = key) do
    seen = Map.get(state.seen, name, [])

    if key in seen or not Automap.knob_cc?(cc) or length(seen) >= @seen_max do
      state
    else
      notify_watchers(state, {:changed, name})
      %{state | seen: Map.put(state.seen, name, Enum.take(seen ++ [key], @seen_max))}
    end
  end

  defp remember_seen(state, _name, _key), do: state

  defp notify_watchers(state, what), do: for(pid <- Map.keys(state.watchers), do: send(pid, {:midi, state.id, what}))

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
  defp event(state, _source, {:dropped, _ev}), do: state

  defp event(state, source, {:learned, ev}) do
    {inputs, shown, controls} = Controls.handle(state.controls, source_name(state, source), ev)
    show(%{state | controls: controls}, inputs, shown)
  end

  defp event(state, source, {:auto, ev}) do
    name = source_name(state, source)
    state = if automap?(state, name), do: first_touch(state, source, name, ev), else: state

    case Controls.handle_auto(state.controls, name, ev) do
      :unmapped -> default_path(state, name, ev)
      {inputs, shown, controls} -> show(%{state | controls: controls}, inputs, shown)
    end
  end

  defp event(state, source, {:learn, ev}) do
    name = source_name(state, source)

    case state do
      %{lineup: %{source: ^name}} -> line_up_take(state, name, ev)
      %{learn: %{} = l} -> learn_offer(state, l, name, ev)
      _ -> state
    end
  end

  defp learn_offer(state, l, name, ev) do
    case Learn.offer(l.learn, name, ev) do
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

  # a message first touch handed over that nothing took (the knobs are full): where it would have gone
  defp default_path(state, name, {:cc, ch, cc, v}) do
    drop =
      source_pref(state, name, :unmapped, :synth) == :drop and Automap.knob_cc?(cc) and
        not MapSet.member?(auto_open(state, name).pass, {ch, cc})

    if drop, do: state, else: input!(state, {:midi, <<0xB0 + ch - 1, cc, v>>})
  end

  defp default_path(state, _name, {:note, ch, n, v}), do: input!(state, {:midi, <<0x90 + ch - 1, n, v>>})
  defp default_path(state, _name, _ev), do: state

  defp input!(state, input) do
    Instance.input(state.id, input)
    state
  end

  # the inputs first, then (once the mailbox is through) what the surface shows
  defp show(state, inputs, shown) do
    state = deliver(state, inputs)

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
      %{
        control: c["id"],
        sub: sub,
        on: m["on"],
        device: m["device"],
        message: Learn.message(m),
        name: control_name(c, sub),
        match: Controls.match_of(m)
      }
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

  defp out(state, bytes, timestamp_ns), do: state.midi_out.({:send, state.virtual, bytes, timestamp_ns})

  ## MIDI out from the surface (FMutate.MIDI.Out)

  # instance inputs to the instance, `{:out, bytes}` to the outputs
  defp deliver(state, inputs) do
    Enum.reduce(inputs, state, fn
      {:out, bytes}, st -> to_outputs(st, bytes)
      input, st -> input!(st, input)
    end)
  end

  # to every output: the virtual port, and each device switched on whose port is open or opening (Android
  # queues what is sent while it opens)
  defp to_outputs(state, bytes) do
    state = %{state | out: Out.sent(state.out, bytes)}
    Enum.reduce(out_targets(state), state, fn {name, device}, st -> send_to(st, name, device, bytes) end)
  end

  defp out_targets(state) do
    port = if state.virtual, do: [{port_name(state.id), state.virtual}], else: []

    port ++
      for d <- state.devices, Map.get(state.opened, d.id) in [:open, :opening], do: {d.name, d.id}
  end

  defp send_to(state, name, device, bytes) do
    stats = Map.get(state.stats, name, %{sent: 0, bytes: 0, last: nil, error: nil})

    stats =
      case state.midi_out.({:send, device, bytes, state.at}) do
        {:error, reason} -> %{stats | error: reason}
        _sent -> %{stats | sent: stats.sent + 1, bytes: stats.bytes + byte_size(bytes), last: bytes, error: nil}
      end

    %{state | stats: Map.put(state.stats, name, stats)}
  end

  defp release_out_now(state) do
    {msgs, out} = Out.release(state.out)
    Enum.reduce(msgs, %{state | out: out}, &to_outputs(&2, &1))
  end

  # the devices switched on that are plugged in and have a port to write to get it opened; a device that went
  # away forgets its port (it comes back under a new id)
  defp sync_outputs(state) do
    present = MapSet.new(state.devices, & &1.id)
    opened = Map.filter(state.opened, fn {id, _} -> MapSet.member?(present, id) end)

    opened =
      for d <- state.devices,
          writable?(d),
          MapSet.member?(state.enabled, d.name),
          not Map.has_key?(opened, d.id),
          reduce: opened do
        acc ->
          state.midi_out.({:open, d.id})
          Map.put(acc, d.id, :opening)
      end

    %{state | opened: opened}
  end

  # a device switched off: its held notes let go, and its port closed unless the device plays the instance (closing
  # is per device) or is a Bluetooth one (closing disconnects it)
  defp output_off(state, d) do
    if Map.has_key?(state.opened, d.id) do
      state = Enum.reduce(Out.offs(state.out), state, &send_to(&2, d.name, d.id, &1))
      if not Map.get(d, :open, false) and Map.get(d, :type) != :bluetooth, do: state.midi_out.({:close, d.id})
      %{state | opened: Map.delete(state.opened, d.id)}
    else
      state
    end
  end

  defp writable?(d), do: Map.get(d, :inputs, 0) > 0

  defp outputs_view(state) do
    port = port_name(state.id)
    status = if state.virtual, do: :open, else: :unavailable
    first = Map.merge(%{name: port, type: :port, device: state.virtual, on: true, status: status}, out_stats(state, port))

    devices =
      for d <- state.devices, writable?(d) do
        on = MapSet.member?(state.enabled, d.name)
        status = if on, do: Map.get(state.opened, d.id, :opening), else: :off
        Map.merge(%{name: d.name, type: Map.get(d, :type, :usb), device: d.id, on: on, status: status}, out_stats(state, d.name))
      end

    [first | devices]
  end

  defp out_stats(state, name), do: Map.get(state.stats, name, %{sent: 0, bytes: 0, last: nil, error: nil})

  @impl true
  def terminate(_reason, state), do: release_out_now(state)

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
    data = %{clock: state.clock, bpm: state.bpm, sources: state.prefs, outputs: MapSet.to_list(state.enabled)}
    File.write!(Paths.midi_settings(state.id), :erlang.term_to_binary(data))
  end
end
