defmodule FMutate.Instance do
  @moduledoc """
  One emulated FM-1 (HANDOFF §3): its firmware, the engine running it, crash recovery, and the inputs.
  v1 has one, `"a"`; everything is keyed by instance id so a second is another process.

  ## Engines

  The firmware runs in an `FMutate.Engine` (its own OS process) whose ring plays through an
  `FMutate.Audio` slot. Switching firmware starts the new engine in a second slot, crossfades when it is
  READY, then stops the old one. If the running engine dies (crash, hang, killed), it is restarted in the
  same slot with the same flash file. A firmware that dies twice within a minute is **quarantined**: it
  isn't restarted or autostarted until the player chooses "Run anyway" (`run_anyway/1`).

  ## Inputs

  `input/2` takes the same events from touch controls and sibling apps (protocol.md §2):

      {:key, n, :down | :up}               n 0..26
      {:button, id, :down | :up}           id from FMutate.Inputs.buttons/0
      {:encoder, id, clicks}               id from FMutate.Inputs.encoders/0
      {:pot, :master, value}               0.0..1.0
      {:midi, binary}                      raw MIDI, now
      {:midi_at, frame, binary}            raw MIDI at a mixer frame (FMutate.Audio.stats/0 :frame)

  Keys held when the engine changes are released first, so nothing sticks.

  ## Subscribers

  `subscribe/1` delivers `{:instance, id, event}`: `{:state, view}` whenever `view/1` changes and
  `{:status, status}` (LEDs, firmware clock) every 100 ms.
  """

  use GenServer
  require Logger

  alias FMutate.{Audio, Engine, Firmware, Inputs, Paths}

  @crossfade_ms 150
  @restart_window_ms 60_000
  @quarantine_after 2

  defstruct id: nil,
            firmware: nil,
            phase: :stopped,
            live: nil,
            next: nil,
            master: 1.0,
            held_keys: MapSet.new(),
            restarts: 0,
            failures: [],
            quarantined: MapSet.new(),
            last_exit: nil,
            status: nil,
            subscribers: %{},
            stopping: %{}

  ## API

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def via(id), do: {:via, Registry, {FMutate.Registry, {:instance, id}}}

  @doc "Send an input event (see the module doc)."
  def input(id, event), do: GenServer.cast(via(id), {:input, event})

  @doc "Switch to another firmware. `{:error, :quarantined | :not_installed}` without switching."
  def switch_firmware(id, firmware_id), do: GenServer.call(via(id), {:switch, firmware_id})

  @doc "Start a quarantined firmware anyway (clears its quarantine)."
  def run_anyway(id), do: GenServer.call(via(id), :run_anyway)

  @doc "What the UI shows: firmware, phase, the screen file, restarts, quarantine."
  def view(id), do: GenServer.call(via(id), :view)

  @doc "Subscribe the caller to `{:instance, id, event}` messages."
  def subscribe(id), do: GenServer.call(via(id), {:subscribe, self()})

  @doc "Debug: crash, hang or kill -9 the running engine."
  def debug(id, what) when what in [:crash, :hang, :kill9], do: GenServer.cast(via(id), {:debug, what})

  ## Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    id = Keyword.fetch!(opts, :id)
    saved = load_state(id)

    state = %__MODULE__{
      id: id,
      firmware: saved[:firmware] || Firmware.default_id(),
      master: saved[:master] || 1.0,
      quarantined: MapSet.new(saved[:quarantined] || [])
    }

    {:ok, state, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    if MapSet.member?(state.quarantined, state.firmware),
      do: {:noreply, publish(%{state | phase: :safe_mode})},
      else: {:noreply, state |> start_engine(:live, state.firmware) |> publish()}
  end

  @impl true
  def handle_call({:switch, fw}, _from, state) do
    cond do
      Firmware.runnable(fw) == nil ->
        {:reply, {:error, :not_installed}, state}

      MapSet.member?(state.quarantined, fw) ->
        {:reply, {:error, :quarantined}, state}

      fw == state.firmware and state.phase in [:booting, :running] ->
        {:reply, :ok, state}

      true ->
        state = if state.next, do: drop_engine(state, :next), else: state
        state = %{state | firmware: fw, restarts: 0, failures: []}
        state = if state.live, do: start_engine(state, :next, fw), else: start_engine(state, :live, fw)
        save_state(state)
        {:reply, :ok, publish(state)}
    end
  end

  def handle_call(:run_anyway, _from, state) do
    state = %{state | quarantined: MapSet.delete(state.quarantined, state.firmware), failures: []}
    save_state(state)
    state = if state.live, do: state, else: start_engine(state, :live, state.firmware)
    {:reply, :ok, publish(state)}
  end

  def handle_call(:view, _from, state), do: {:reply, view_of(state), state}

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, view_of(state), %{state | subscribers: Map.put(state.subscribers, pid, ref)}}
  end

  @impl true
  def handle_cast({:input, event}, state), do: {:noreply, apply_input(state, event)}

  def handle_cast({:debug, what}, %{live: %{pid: pid}} = state) do
    case what do
      :kill9 -> Engine.kill9(pid)
      other -> Engine.commands(pid, [other])
    end

    {:noreply, state}
  end

  def handle_cast({:debug, _}, state), do: {:noreply, state}

  @impl true
  def handle_info({:engine, pid, event}, state) do
    case which(state, pid) do
      nil -> {:noreply, state}
      :stopping -> {:noreply, stopping_event(state, pid, event)}
      role -> {:noreply, engine_event(state, role, event)}
    end
  end

  def handle_info({:finish_switch, pid}, state) do
    Engine.stop(pid)
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    engines = Enum.reject([state.live, state.next], &is_nil/1) ++ Map.values(state.stopping)

    for eng <- engines do
      Engine.stop(eng.pid)
      Audio.release(eng.slot)
    end

    :ok
  end

  ## Engines

  defp start_engine(state, role, fw) do
    with {bin, cart} <- Firmware.runnable(fw) || nil,
         {:ok, slot} <- Audio.claim() do
      prefix = Paths.shm_prefix(state.id, slot)

      {:ok, pid} =
        Engine.start_link(
          owner: self(),
          tag: {state.id, fw, slot},
          bin: bin,
          cart: cart,
          prefix: prefix,
          flash: Paths.flash(state.id, fw),
          fill: Audio.engine_fill()
        )

      eng = %{pid: pid, firmware: fw, slot: slot, prefix: prefix, ready: false}
      phase = if role == :live, do: :booting, else: state.phase
      Map.put(%{state | phase: phase}, role, eng)
    else
      nil ->
        Logger.error("instance #{state.id}: #{fw} can't run here (no cartridge, package or emulator)")
        %{state | phase: :not_installed}

      {:error, reason} ->
        Logger.error("instance #{state.id}: cannot start #{fw}: #{inspect(reason)}")
        %{state | phase: :crashed}
    end
  end

  # Engines being stopped (after a switch, or a superseded `next`) stay in `stopping` until they exit;
  # their audio slot goes back then.
  defp drop_engine(state, role) do
    eng = Map.fetch!(state, role)
    Engine.stop(eng.pid)
    Audio.gain(eng.slot, 0, 30)
    state |> Map.put(role, nil) |> Map.update!(:stopping, &Map.put(&1, eng.pid, eng))
  end

  defp which(state, pid) do
    cond do
      state.live && state.live.pid == pid -> :live
      state.next && state.next.pid == pid -> :next
      Map.has_key?(state.stopping, pid) -> :stopping
      true -> nil
    end
  end

  defp stopping_event(state, pid, {:exit, _}) do
    {eng, stopping} = Map.pop(state.stopping, pid)
    Audio.release(eng.slot)
    %{state | stopping: stopping}
  end

  defp stopping_event(state, _pid, _event), do: state

  defp engine_event(state, role, {:ready, ms}) do
    eng = Map.fetch!(state, role)
    Logger.info("instance #{state.id}: #{eng.firmware} ready in #{ms} ms (slot #{eng.slot})")
    :ok = Audio.attach(eng.slot, Paths.ring(eng.prefix))
    eng = %{eng | ready: true}
    Engine.commands(eng.pid, [{:master, round(state.master * 1024)}])

    case role do
      :live ->
        Audio.gain(eng.slot, 1000, 20)
        publish(%{state | live: eng, phase: :running})

      :next ->
        old = state.live
        state = release_keys(state, old)
        Audio.gain(eng.slot, 1000, @crossfade_ms)
        Audio.gain(old.slot, 0, @crossfade_ms)
        Process.send_after(self(), {:finish_switch, old.pid}, @crossfade_ms + 50)
        state = %{state | stopping: Map.put(state.stopping, old.pid, old)}
        publish(%{state | live: eng, next: nil, phase: :running})
    end
  end

  defp engine_event(state, :live, {:status, status}) do
    for {pid, _} <- state.subscribers, do: send(pid, {:instance, state.id, {:status, status}})
    %{state | status: status}
  end

  defp engine_event(state, _role, {:status, _}), do: state

  defp engine_event(state, _role, {:flash_saved, _bytes}), do: state
  defp engine_event(state, _role, {:spawned, _os_pid}), do: state

  defp engine_event(state, role, {:exit, reason}) do
    eng = Map.fetch!(state, role)
    Audio.release(eng.slot)
    Logger.warning("instance #{state.id}: #{eng.firmware} (#{role}) exited: #{inspect(reason)}")
    state = Map.put(state, role, nil)
    now = System.monotonic_time(:millisecond)
    failures = [now | Enum.filter(state.failures, &(now - &1 < @restart_window_ms))]
    state = %{state | failures: failures, last_exit: reason, held_keys: MapSet.new()}

    cond do
      role == :next ->
        # the new firmware died while booting: stay on the old one
        publish(quarantine_if(state, eng.firmware))

      length(failures) >= @quarantine_after ->
        state = %{state | quarantined: MapSet.put(state.quarantined, eng.firmware), phase: :safe_mode}
        save_state(state)
        publish(state)

      true ->
        state = %{state | restarts: state.restarts + 1, phase: :crashed}
        state |> publish() |> start_engine(:live, eng.firmware) |> publish()
    end
  end

  defp quarantine_if(state, fw) do
    if length(state.failures) >= @quarantine_after do
      state = %{state | quarantined: MapSet.put(state.quarantined, fw)}
      save_state(state)
      state
    else
      state
    end
  end

  ## Inputs

  defp apply_input(%{live: %{ready: true} = eng} = state, event) do
    {cmds, state} = to_commands(event, state)
    Engine.commands(eng.pid, cmds)
    state
  end

  defp apply_input(state, {:pot, :master, v}), do: %{state | master: clamp01(v)}
  defp apply_input(state, _event), do: state

  defp to_commands({:key, n, :down}, state) when n in 0..26,
    do: {[{:key, n, true}], %{state | held_keys: MapSet.put(state.held_keys, n)}}

  defp to_commands({:key, n, :up}, state) when n in 0..26,
    do: {[{:key, n, false}], %{state | held_keys: MapSet.delete(state.held_keys, n)}}

  defp to_commands({:button, id, dir}, state) when dir in [:down, :up],
    do: {[{:button, Inputs.button(id), dir == :down}], state}

  defp to_commands({:encoder, id, clicks}, state) when is_integer(clicks),
    do: {[{:enc, Inputs.encoder(id), clicks}], state}

  defp to_commands({:pot, :master, v}, state) do
    v = clamp01(v)
    {[{:master, round(v * 1024)}], %{state | master: v}}
  end

  defp to_commands({:midi, bytes}, state) when is_binary(bytes), do: {midi_cmds(bytes, nil), state}

  defp to_commands({:midi_at, frame, bytes}, state) when is_integer(frame) and is_binary(bytes),
    do: {midi_cmds(bytes, frame), state}

  defp to_commands(other, state) do
    Logger.debug("instance #{state.id}: ignoring input #{inspect(other)}")
    {[], state}
  end

  # Raw MIDI → 3-byte messages (shorter ones padded); sysex is not passed on in v1. Clock, start, continue,
  # stop and song position pass (FMutate.MIDI's clock follow/send).
  defp midi_cmds(bytes, frame) do
    for msg <- split_midi(bytes, []) do
      [st, d1, d2] = msg ++ List.duplicate(0, 3 - length(msg))
      if frame, do: {:midi_at, frame, st, d1, d2}, else: {:midi, st, d1, d2}
    end
  end

  defp split_midi(<<>>, acc), do: Enum.reverse(acc)

  defp split_midi(<<st, rest::binary>>, acc) when st >= 0x80 and st < 0xF0 do
    n = if div(st, 16) in [0xC, 0xD], do: 1, else: 2

    case rest do
      <<data::binary-size(^n), tail::binary>> -> split_midi(tail, [[st | :binary.bin_to_list(data)] | acc])
      _ -> Enum.reverse(acc)
    end
  end

  defp split_midi(<<st, rest::binary>>, acc) when st in [0xF8, 0xFA, 0xFB, 0xFC], do: split_midi(rest, [[st] | acc])

  defp split_midi(<<0xF2, lsb, msb, rest::binary>>, acc) when lsb < 0x80 and msb < 0x80,
    do: split_midi(rest, [[0xF2, lsb, msb] | acc])

  defp split_midi(<<_skip, rest::binary>>, acc), do: split_midi(rest, acc)

  defp release_keys(state, nil), do: state

  defp release_keys(state, eng) do
    Engine.commands(eng.pid, for(k <- state.held_keys, do: {:key, k, false}))
    %{state | held_keys: MapSet.new()}
  end

  defp clamp01(v) when is_number(v), do: v |> max(0.0) |> min(1.0)

  ## View, persistence

  defp view_of(state) do
    %{
      id: state.id,
      firmware: state.firmware,
      phase: state.phase,
      fb: state.live && state.live.ready && Paths.fb(state.live.prefix),
      quarantined: MapSet.member?(state.quarantined, state.firmware),
      restarts: state.restarts,
      last_exit: state.last_exit,
      master: state.master
    }
  end

  defp publish(state) do
    view = view_of(state)

    if Process.get(:last_view) != view do
      Process.put(:last_view, view)
      for {pid, _} <- state.subscribers, do: send(pid, {:instance, state.id, {:state, view}})
    end

    state
  end

  defp load_state(id) do
    case File.read(Paths.instance_state(id)) do
      {:ok, bin} -> :erlang.binary_to_term(bin, [:safe])
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp save_state(state) do
    data = %{firmware: state.firmware, master: state.master, quarantined: MapSet.to_list(state.quarantined)}
    File.write!(Paths.instance_state(state.id), :erlang.term_to_binary(data))
  end
end
