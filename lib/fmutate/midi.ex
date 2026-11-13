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

  Settings (clock mode, tempo, per-source channel and note mode) are kept per instance across restarts.
  Sources are known by name, so a device keeps its settings when it is plugged in again.
  """

  use GenServer
  require Logger

  alias FMutate.{Firmware, Instance, Paths}
  alias FMutate.MIDI.Map, as: MidiMap

  @latency_samples 256
  @clock_lead_ms 4
  @bpm_range 20..300

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
  `%{clock, bpm, bend, sources}`: `sources` maps a source name to `%{channel, notes}` (only the ones the
  player changed; others are `%{channel: :all, notes: :keys}`).
  """
  def settings(id), do: GenServer.call(via(id), :settings)

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
      ticker: nil
    }

    {:ok, start_clock(state)}
  end

  @impl true
  def handle_call(:settings, _from, state) do
    {:reply, Map.take(state, [:clock, :bpm, :bend]) |> Map.put(:sources, state.prefs), state}
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
    {inputs, parser} = MidiMap.feed(parser(state, source), bytes)
    for input <- inputs, do: Instance.input(state.id, input)
    sample = {(recv_ns - sent_ns) / 1.0e6, (now - recv_ns) / 1.0e6}
    samples = Enum.take([sample | state.samples], @latency_samples)
    {:noreply, %{state | parsers: Map.put(state.parsers, source, parser), samples: samples}}
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

  defp parser(state, source) do
    case Map.fetch(state.parsers, source) do
      {:ok, parser} -> parser
      :error -> MidiMap.new(options(state, source_name(state, source)))
    end
  end

  defp options(state, name) do
    pref = Map.get(state.prefs, name, %{})

    [
      channel: pref[:channel] || :all,
      notes: pref[:notes] || :keys,
      bend: state.bend,
      clock: state.clock
    ]
  end

  defp reconfigure(state) do
    parsers =
      Map.new(state.parsers, fn {src, p} ->
        {src, MidiMap.configure(p, options(state, source_name(state, src)))}
      end)

    %{state | parsers: parsers}
  end

  defp release_sources(state, sources) do
    Enum.reduce(sources, state, fn src, st ->
      {inputs, _} = MidiMap.release_all(st.parsers[src])
      for input <- inputs, do: Instance.input(st.id, input)
      %{st | parsers: Map.delete(st.parsers, src)}
    end)
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
