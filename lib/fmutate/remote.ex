defmodule FMutate.Remote do
  @moduledoc """
  The facade sibling apps talk to over distribution (protocol.md), one per instance: registered as
  `:fmutate_instance` on the instance's node and globally as `{:fmutate, id}`.

  Every message is `{:fmutate, 1, instance_id, payload}`, sent with `send/2` or `GenServer.cast/2`
  (inputs) or `GenServer.call/3` (everything that answers). Payloads:

      # inputs (§2), fire and forget
      {:key, n, :down, velocity} | {:key, n, :up} | {:encoder, id, clicks} | {:pot, :master, value}
      {:button, id, :down | :up} | {:midi, bytes} | {:midi_at, frame, bytes}

      # calls (§3, §4)
      {:subscribe, pid, topics} → :ok      topics ⊆ [:screen, :leds, :midi_out, :status, :layout]
      {:unsubscribe, pid} → :ok
      {:list_firmware} → {:ok, [%{id, name, version, status}]}
      {:list_layouts, firmware_id} → {:ok, [%{id, name, made_by}]}
      {:get_layout, layout_id} → {:ok, json} | {:error, :not_found}

  Events to subscribers (§3): `{:status, status}` (`:booting | :running | :crashed | :safe_mode |
  {:slow, clock_pct}`), `{:leds, keys_bitmap, buttons_map}` (on change), `{:screen, seq, frame}` (240×240
  RGB565, 115 200 bytes, changed frames only, at most 30 per second). `:midi_out` and `:layout` are
  accepted, but nothing produces them yet: the engine protocol has no firmware MIDI out, and layouts don't
  change from outside the editor.

  Calls from nodes the player hasn't allowed get `{:error, :not_allowed}` (`FMutate.Dist.permitted?/1`); in
  practice such nodes can't connect at all (see `FMutate.Dist`). A wrong instance id gets
  `{:error, :no_such_instance}`, another protocol version `{:error, :unsupported_version}`. Inputs that
  don't match §2 are dropped (and logged), never passed on.
  """

  use GenServer
  require Logger

  import Bitwise

  alias FMutate.{Dist, Firmware, Inputs, Instance, Layouts}

  @version 1
  @topics [:screen, :leds, :midi_out, :status, :layout]
  @frame_ms 33
  @fb_bytes 240 * 240 * 2

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def via(id), do: {:via, Registry, {FMutate.Registry, {:remote, id}}}

  @doc false
  # the §2 input as the instance takes it, or nil for anything else
  def to_input({:key, n, :down, vel}) when n in 0..26 and vel in 1..127, do: {:key, n, :down}
  def to_input({:key, n, :up}) when n in 0..26, do: {:key, n, :up}

  def to_input({:encoder, id, clicks}) when is_integer(clicks) do
    if id in Inputs.encoders(), do: {:encoder, id, clicks}
  end

  def to_input({:pot, :master, v}) when is_number(v) and v >= 0 and v <= 1,
    do: {:pot, :master, v / 1}

  def to_input({:button, id, dir}) when dir in [:down, :up] do
    if id in Inputs.buttons(), do: {:button, id, dir}
  end

  def to_input({:midi, bytes}) when is_binary(bytes), do: {:midi, bytes}

  def to_input({:midi_at, frame, bytes})
      when is_integer(frame) and frame >= 0 and is_binary(bytes),
      do: {:midi_at, frame, bytes}

  def to_input(_), do: nil

  @doc false
  # the instance's view → the §3 status (too slow is the instance's call: FMutate.Instance.Health)
  def status_of(%{phase: :running, slow: true, clock_pct: pct}) when is_integer(pct), do: {:slow, pct}
  def status_of(%{phase: phase}) when phase in [:booting, :running, :crashed, :safe_mode], do: phase
  def status_of(_view), do: :crashed

  @doc false
  def leds_of(%{led_keys: keys, led_buttons: buttons}) do
    map =
      for {id, bit} <- Enum.with_index(Inputs.buttons()),
          into: %{},
          do: {id, if((buttons >>> bit &&& 1) == 1, do: :on, else: :off)}

    {keys &&& 0x7FFFFFF, map}
  end

  ## Server

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    if Keyword.get(opts, :register_local, true), do: Process.register(self(), :fmutate_instance)
    :yes = :global.register_name({:fmutate, id}, self())
    view = Instance.subscribe(id, status: true)

    {:ok,
     %{
       id: id,
       view: view,
       subs: %{},
       last_status: nil,
       last_leds: nil,
       fb_seq: nil,
       frame_timer: nil
     }}
  end

  # a paired app forgetting its pairing (protocol §1.5): only its own, answered before the connection goes
  @impl true
  def handle_call({:fmutate, @version, id, {:unpair, name}}, {pid, _} = from, %{id: id} = state)
      when is_binary(name) or is_atom(name) do
    caller = node(pid)

    if to_string(name) == Atom.to_string(caller) do
      GenServer.reply(from, :ok)
      _ = Dist.unpair(caller)
      {:noreply, state}
    else
      {:reply, {:error, :not_allowed}, state}
    end
  end

  def handle_call({:fmutate, @version, id, payload}, {pid, _}, %{id: id} = state) do
    if Dist.permitted?(node(pid)),
      do: call(payload, state),
      else: {:reply, {:error, :not_allowed}, state}
  end

  def handle_call({:fmutate, @version, _other, _payload}, _from, state),
    do: {:reply, {:error, :no_such_instance}, state}

  def handle_call({:fmutate, _version, _id, _payload}, _from, state),
    do: {:reply, {:error, :unsupported_version}, state}

  def handle_call(_other, _from, state), do: {:reply, {:error, :bad_request}, state}

  @impl true
  def handle_cast(msg, state), do: {:noreply, input(msg, state)}

  @impl true
  def handle_info({:fmutate, _, _, _} = msg, state), do: {:noreply, input(msg, state)}

  def handle_info({:instance, id, {:state, view}}, %{id: id} = state),
    do: {:noreply, push_status(%{state | view: view})}

  def handle_info({:instance, id, {:status, status}}, %{id: id} = state) do
    state = push_leds(state, status)
    {:noreply, state}
  end

  def handle_info(:frame, state), do: {:noreply, push_screen(%{state | frame_timer: nil})}

  def handle_info({:DOWN, _ref, :process, pid, _}, state), do: {:noreply, drop(state, pid)}

  def handle_info(_msg, state), do: {:noreply, state}

  ## Calls

  defp call({:subscribe, pid, topics}, state) when is_pid(pid) and is_list(topics) do
    if topics -- @topics == [] do
      state = drop(state, pid)
      ref = Process.monitor(pid)
      state = put_in(state.subs[pid], %{ref: ref, topics: MapSet.new(topics), last_frame: 0})
      if :status in topics, do: send(pid, {:status, current_status(state)})

      if :leds in topics and state.last_leds,
        do: send(pid, Tuple.insert_at(state.last_leds, 0, :leds))

      {:reply, :ok, schedule_frames(state)}
    else
      {:reply, {:error, {:unknown_topics, topics -- @topics}}, state}
    end
  end

  defp call({:unsubscribe, pid}, state), do: {:reply, :ok, drop(state, pid)}

  defp call({:list_firmware}, state) do
    list =
      for fw <- Firmware.all() do
        status =
          cond do
            fw.id == state.view.firmware ->
              if(state.view.quarantined, do: :quarantined, else: :running)

            Firmware.runnable(fw.id) == nil ->
              :not_installed

            true ->
              :installed
          end

        %{id: fw.id, name: fw.name, version: fw.version, status: status}
      end

    {:reply, {:ok, list}, state}
  end

  defp call({:list_layouts, firmware_id}, state) when is_binary(firmware_id) do
    list =
      for l <- Layouts.for_firmware(firmware_id),
          do: %{id: l.id, name: l.name, made_by: made_by(l)}

    {:reply, {:ok, list}, state}
  end

  defp call({:get_layout, layout_id}, state) do
    case Layouts.preset(layout_id) do
      nil -> {:reply, {:error, :not_found}, state}
      layout -> {:reply, {:ok, Layouts.encode(layout.data)}, state}
    end
  end

  defp call(other, state) do
    Logger.info("remote #{state.id}: unsupported call #{inspect(other, limit: 5)}")
    {:reply, {:error, :unsupported}, state}
  end

  defp made_by(layout) do
    case layout.data do
      %{"meta" => %{"made_by" => by}} when is_binary(by) -> by
      _ -> "FMutate"
    end
  end

  ## Inputs

  defp input({:fmutate, @version, id, payload}, %{id: id} = state) do
    case to_input(payload) do
      nil ->
        Logger.debug("remote #{id}: dropping #{inspect(payload, limit: 5)}")

      event ->
        Instance.input(id, event)
        if Process.whereis(Dist), do: Dist.driving(id)
    end

    state
  end

  defp input(other, state) do
    Logger.debug("remote #{state.id}: dropping #{inspect(other, limit: 5)}")
    state
  end

  ## Events

  defp subscribers(state, topic),
    do: for({pid, %{topics: t}} <- state.subs, MapSet.member?(t, topic), do: pid)

  defp drop(state, pid) do
    case Map.pop(state.subs, pid) do
      {nil, _} -> state
      {%{ref: ref}, subs} -> Process.demonitor(ref, [:flush]) && %{state | subs: subs}
    end
  end

  defp current_status(state), do: status_of(state.view)

  defp push_status(state) do
    status = current_status(state)

    if status != state.last_status do
      for pid <- subscribers(state, :status), do: send(pid, {:status, status})
    end

    %{state | last_status: status}
  end

  defp push_leds(state, status) do
    leds = leds_of(status)

    if leds != state.last_leds do
      {keys, buttons} = leds
      for pid <- subscribers(state, :leds), do: send(pid, {:leds, keys, buttons})
    end

    %{state | last_leds: leds}
  end

  defp schedule_frames(%{frame_timer: nil} = state) do
    if subscribers(state, :screen) != [],
      do: %{state | frame_timer: Process.send_after(self(), :frame, @frame_ms)},
      else: state
  end

  defp schedule_frames(state), do: state

  # read the screen file when its seq moved; every screen subscriber gets the frame (≤ 30 fps)
  defp push_screen(state) do
    state =
      with path when is_binary(path) <- state.view.fb,
           pids when pids != [] <- subscribers(state, :screen),
           {:ok, fd} <- :file.open(path, [:read, :raw, :binary]) do
        try do
          case :file.pread(fd, 4, 4) do
            {:ok, <<seq::little-32>>} when seq != state.fb_seq ->
              {:ok, frame} = :file.pread(fd, 8, @fb_bytes)
              for pid <- pids, do: send(pid, {:screen, seq, frame})
              %{state | fb_seq: seq}

            _ ->
              state
          end
        after
          :file.close(fd)
        end
      else
        _ -> state
      end

    schedule_frames(state)
  end
end
