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

  ## Health

  The running engine's speed and its ring fill (`FMutate.Instance.Health`): the view carries `clock_pct`
  (firmware time against wall time, whole percent, nil until measured), `slow` (too slow, with hysteresis),
  `fill` (the engine's target ring fill, frames) and `buffer` (`:auto` or a fixed fill, `set_buffer/2`,
  saved with the instance). On `:auto` the fill rises when the slot underruns and settles back when it
  stops; it is set on the running engine (port op `0x07`), no restart. For a firmware in the emulator engine
  also `cpu_mhz` (the emulated CPU's clock, op `0x08`) and `cpu_mode` (`:auto` or fixed MHz, `set_cpu/2`):
  on `:auto` the clock steps down while the engine is too slow and is kept per firmware (`cpu` in the saved
  state), so its next engine starts there. `advice` says what the instrument shows beside "Too slow".

  ## Subscribers

  `subscribe/1` delivers `{:instance, id, event}`: `{:state, view}` whenever `view/1` changes and
  `{:status, status}` (LEDs, firmware clock) every 100 ms.
  """

  use GenServer
  require Logger

  alias FMutate.{Audio, Engine, Firmware, Inputs, Paths}
  alias FMutate.Instance.Health

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
            held_buttons: MapSet.new(),
            # the last inputs and surface diagnostics, newest first (journal/2); trimmed to @journal_keep
            journal: [],
            journal_n: 0,
            restarts: 0,
            failures: [],
            quarantined: MapSet.new(),
            last_exit: nil,
            status: nil,
            subscribers: %{},
            stopping: %{},
            buffer: :auto,
            # per firmware (emulator engine): the CPU clock kept by FMutate.Instance.Health.memory/1
            cpu: %{},
            health: nil

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

  @doc """
  Subscribe the caller to `{:instance, id, {:state, view}}` (on every change of the view). With
  `status: true` also `{:instance, id, {:status, status}}` on every engine STATUS (ten a second): only for
  processes that use it (FMutate.Remote), since a screen re-renders on every message it gets.
  """
  def subscribe(id, opts \\ []), do: GenServer.call(via(id), {:subscribe, self(), Keyword.get(opts, :status, false)})

  @doc "Debug: crash, hang or kill -9 the running engine."
  def debug(id, what) when what in [:crash, :hang, :kill9], do: GenServer.cast(via(id), {:debug, what})

  @doc """
  Diagnostics: the last `n` inputs (and surface reports) as `{ms, kind, event, outcome}`, newest first. `ms` is
  monotonic milliseconds; `outcome` is `:sent` (to the running engine) or `:dropped` (no engine ready).
  """
  def journal(id, n \\ 100), do: GenServer.call(via(id), {:journal, n})

  @doc "Diagnostics: the keys and buttons the firmware currently has held down (sent down, not yet up)."
  def held(id), do: GenServer.call(via(id), :held)

  @doc "Diagnostics from the instrument surface (stuck fingers it let go of, …), kept in the journal and logged."
  def note(id, what), do: GenServer.cast(via(id), {:note, what})

  @doc """
  Let go of everything: up for every held key and button, MIDI all notes off, pitch bend centred, volume full.
  The way out when something is stuck.
  """
  def release_all(id), do: GenServer.cast(via(id), :release_all)

  @doc """
  The engine buffer: `:auto` (the computed fill, raised while the engine underruns) or a fixed ring fill in
  frames (`FMutate.Instance.Health.fixed_buffers/0`). Applies to the running engine at once; saved.
  """
  def set_buffer(id, buffer) when buffer == :auto or (is_integer(buffer) and buffer > 0),
    do: GenServer.call(via(id), {:buffer, buffer})

  @doc """
  The emulated CPU clock for the current firmware (emulator engine): `:auto` (lowered while the engine is too
  slow, `FMutate.Instance.Health`) or fixed MHz (`FMutate.Instance.Health.clocks/0`). Applies to the running
  engine at once; saved per firmware.
  """
  def set_cpu(id, mode) when mode == :auto or (is_integer(mode) and mode > 0),
    do: GenServer.call(via(id), {:cpu, mode})

  # --- library hooks (FMutate.Library / LibraryScreen) ---
  @doc "The firmwares quarantined on this instance (any, not only the current one)."
  @spec quarantined(String.t()) :: [String.t()]
  def quarantined(id), do: GenServer.call(via(id), :quarantined)

  @doc "Clear a firmware's quarantine and switch to it (the library's Run anyway)."
  def run_anyway(id, firmware_id) do
    :ok = GenServer.call(via(id), {:unquarantine, firmware_id})
    switch_firmware(id, firmware_id)
  end

  # --- end library hooks ---

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
      quarantined: MapSet.new(saved[:quarantined] || []),
      buffer: saved[:buffer] || :auto,
      cpu: saved[:cpu] || %{}
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

  def handle_call({:buffer, buffer}, _from, state) do
    state = %{state | buffer: buffer}
    save_state(state)

    state =
      case {state.health, state.live} do
        {%Health{} = h, %{ready: true, pid: pid}} ->
          {h, fill} = Health.buffer(h, buffer)
          Engine.commands(pid, [{:fill, fill}])
          %{state | health: h}

        _ ->
          state
      end

    {:reply, :ok, publish(state)}
  end

  def handle_call({:cpu, mode}, _from, state) do
    state =
      case {state.health, state.live} do
        {%Health{cpu: %{}} = h, %{ready: true} = eng} ->
          {h, mhz} = Health.cpu_mode(h, mode)
          Engine.commands(eng.pid, [{:cpu_mhz, mhz}])
          remember_cpu(%{state | health: h}, eng.firmware)

        _ ->
          mem = state.cpu |> Map.get(state.firmware, %{}) |> Map.put(:mode, mode)
          mem = if is_integer(mode), do: Map.put(mem, :mhz, mode), else: mem
          %{state | cpu: Map.put(state.cpu, state.firmware, mem)}
      end

    save_state(state)
    {:reply, :ok, publish(state)}
  end

  # library hooks
  def handle_call(:quarantined, _from, state), do: {:reply, MapSet.to_list(state.quarantined), state}

  def handle_call({:unquarantine, fw}, _from, state) do
    state = %{state | quarantined: MapSet.delete(state.quarantined, fw), failures: []}
    save_state(state)
    {:reply, :ok, state}
  end

  def handle_call({:subscribe, pid, status?}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, view_of(state), %{state | subscribers: Map.put(state.subscribers, pid, {ref, status?})}}
  end

  def handle_call({:journal, n}, _from, state), do: {:reply, Enum.take(state.journal, n), state}

  def handle_call(:held, _from, state),
    do: {:reply, %{keys: Enum.sort(state.held_keys), buttons: Enum.sort(state.held_buttons)}, state}

  @impl true
  def handle_cast({:input, event}, state), do: {:noreply, apply_input(state, event)}

  def handle_cast({:note, what}, state) do
    Logger.warning("instance #{state.id}: surface: #{inspect(what)}")
    {:noreply, journal(state, :surface, what, :noted)}
  end

  def handle_cast(:release_all, state) do
    ups =
      Enum.map(state.held_keys, &{:key, &1, :up}) ++ Enum.map(state.held_buttons, &{:button, &1, :up}) ++
        [{:midi, <<0xB0, 123, 0, 0xB0, 7, 127, 0xE0, 0, 64>>}]

    state = journal(state, :surface, :release_all, :noted)
    {:noreply, Enum.reduce(ups, state, &apply_input(&2, &1))}
  end

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

  # `carry`: the fill the previous engine of this firmware ended with (a restart keeps what auto learnt)
  defp start_engine(state, role, fw, carry \\ nil) do
    with %{engine: bin, file: cart, backend: backend} <- Firmware.runnable(fw) || nil,
         {:ok, slot} <- Audio.claim() do
      prefix = Paths.shm_prefix(state.id, slot)
      fill = Health.start_fill(state.buffer, Audio.engine_fill(), carry)

      {:ok, pid} =
        Engine.start_link(
          owner: self(),
          tag: {state.id, fw, slot},
          bin: bin,
          cart: cart,
          prefix: prefix,
          flash: Paths.flash(state.id, fw, backend),
          fill: fill,
          # (development: e.g. [{"FM1_NO_JIT", "1"}] to see a slow phone's behaviour on a fast one)
          env: if(backend == :emu, do: Application.get_env(:fmutate_app, :emu_env, []), else: [])
        )

      eng = %{pid: pid, firmware: fw, slot: slot, prefix: prefix, ready: false, fill: fill, backend: backend}
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

    # the emulator engine's CPU clock: where it was last kept for this firmware
    cpu = if eng.backend == :emu, do: Map.get(state.cpu, eng.firmware, %{})
    health = Health.new(state.buffer, Audio.engine_fill(), eng.fill, cpu)
    if cpu, do: Engine.commands(eng.pid, [{:cpu_mhz, Health.cpu_mhz(health)}])

    case role do
      :live ->
        Audio.gain(eng.slot, 1000, 20)
        publish(%{state | live: eng, phase: :running, health: health})

      :next ->
        old = state.live
        state = release_keys(state, old)
        Audio.gain(eng.slot, 1000, @crossfade_ms)
        Audio.gain(old.slot, 0, @crossfade_ms)
        Process.send_after(self(), {:finish_switch, old.pid}, @crossfade_ms + 50)
        state = %{state | stopping: Map.put(state.stopping, old.pid, old)}
        publish(%{state | live: eng, next: nil, phase: :running, health: health})
    end
  end

  # (published only when the health shows something new: the view also carries `master`, which pot moves
  # change without a publish, and a publish re-renders the instrument)
  defp engine_event(state, :live, {:status, status}) do
    for {pid, {_, true}} <- state.subscribers, do: send(pid, {:instance, state.id, {:status, status}})
    new = health(%{state | status: status}, status)
    if health_view(new) != health_view(state), do: publish(new), else: new
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
    state = %{state | failures: failures, last_exit: reason, held_keys: MapSet.new(), held_buttons: MapSet.new()}
    state = journal(state, :engine, {:exit, role, reason}, :noted)

    cond do
      role == :next ->
        # the new firmware died while booting: stay on the old one
        publish(quarantine_if(state, eng.firmware))

      length(failures) >= @quarantine_after ->
        state = %{state | quarantined: MapSet.put(state.quarantined, eng.firmware), phase: :safe_mode}
        save_state(state)
        publish(state)

      true ->
        carry = state.health && state.health.fill
        state = %{state | restarts: state.restarts + 1, phase: :crashed}
        state |> publish() |> start_engine(:live, eng.firmware, carry) |> publish()
    end
  end

  # the engine's speed every window, and its fill from the slot's underruns (FMutate.Instance.Health)
  defp health(%{health: %Health{} = h, live: %{ready: true} = eng} = state, status) do
    now = System.monotonic_time(:millisecond)

    case Health.status(h, now, status.ms) do
      {h, :none} ->
        %{state | health: h}

      {h, :window} ->
        case Audio.stats() do
          %{running: true, underruns: underruns} ->
            {h, fill} = Health.underruns(h, now, Enum.at(underruns, eng.slot, 0))

            if fill do
              Logger.info("instance #{state.id}: engine fill #{fill} frames (underruns #{h.underruns})")
              Engine.commands(eng.pid, [{:fill, fill}])
            end

            {h, mhz} =
              if status[:cpu_mhz], do: Health.cpu(h, now, status.stale, status.cpu_ms), else: {h, nil}

            if mhz do
              Logger.info("instance #{state.id}: emulated CPU #{mhz} MHz (speed #{h.pct} %)")
              Engine.commands(eng.pid, [{:cpu_mhz, mhz}])
            end

            remember_cpu(%{state | health: h}, eng.firmware)

          _ ->
            %{state | health: Health.pause(h)}
        end
    end
  end

  defp health(state, _status), do: state

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
    journal(state, :in, event, :sent)
  end

  defp apply_input(state, {:pot, :master, v} = event), do: journal(%{state | master: clamp01(v)}, :in, event, :dropped)
  defp apply_input(state, event), do: journal(state, :in, event, :dropped)

  @journal_keep 300

  # newest first; trimmed in batches so an input costs O(1)
  defp journal(state, kind, event, outcome) do
    entry = {System.monotonic_time(:millisecond), kind, event, outcome}

    if state.journal_n >= 2 * @journal_keep,
      do: %{state | journal: [entry | Enum.take(state.journal, @journal_keep)], journal_n: @journal_keep + 1},
      else: %{state | journal: [entry | state.journal], journal_n: state.journal_n + 1}
  end

  defp to_commands({:key, n, :down}, state) when n in 0..26,
    do: {[{:key, n, true}], %{state | held_keys: MapSet.put(state.held_keys, n)}}

  defp to_commands({:key, n, :up}, state) when n in 0..26,
    do: {[{:key, n, false}], %{state | held_keys: MapSet.delete(state.held_keys, n)}}

  defp to_commands({:button, id, dir}, state) when dir in [:down, :up] do
    held = if dir == :down, do: MapSet.put(state.held_buttons, id), else: MapSet.delete(state.held_buttons, id)
    {[{:button, Inputs.button(id), dir == :down}], %{state | held_buttons: held}}
  end

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
    Engine.commands(eng.pid, for(b <- state.held_buttons, do: {:button, Inputs.button(b), false}))
    %{state | held_keys: MapSet.new(), held_buttons: MapSet.new()}
  end

  defp clamp01(v) when is_number(v), do: v |> max(0.0) |> min(1.0)

  ## View, persistence

  defp view_of(state) do
    Map.merge(
      %{
        id: state.id,
        firmware: state.firmware,
        phase: state.phase,
        fb: state.live && state.live.ready && Paths.fb(state.live.prefix),
        quarantined: MapSet.member?(state.quarantined, state.firmware),
        restarts: state.restarts,
        last_exit: state.last_exit,
        master: state.master,
        buffer: state.buffer
      },
      health_view(state)
    )
  end

  # speed, fill and emulated CPU clock of the running engine (nil / false while nothing runs); `advice`: what
  # the instrument says beside "Too slow" (FMutate.Instance.Health.advice/1)
  defp health_view(%{phase: :running, health: %Health{} = h}) do
    %{
      clock_pct: h.pct,
      slow: h.slow,
      fill: h.fill,
      cpu_mhz: Health.cpu_mhz(h),
      cpu_mode: h.cpu && h.cpu.mode,
      advice: Health.advice(h)
    }
  end

  defp health_view(_state), do: %{clock_pct: nil, slow: false, fill: nil, cpu_mhz: nil, cpu_mode: nil, advice: nil}

  # keep the emulator engine's clock for its firmware (saved when it changed)
  defp remember_cpu(state, fw) do
    case Health.memory(state.health) do
      nil ->
        state

      mem ->
        if Map.get(state.cpu, fw) == mem do
          state
        else
          state = %{state | cpu: Map.put(state.cpu, fw, mem)}
          save_state(state)
          state
        end
    end
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
    data = %{
      firmware: state.firmware,
      master: state.master,
      quarantined: MapSet.to_list(state.quarantined),
      buffer: state.buffer,
      cpu: state.cpu
    }

    File.write!(Paths.instance_state(state.id), :erlang.term_to_binary(data))
  end
end
