defmodule FMutate.Audio do
  @moduledoc """
  The audio output: owns the mixer NIF (`FMutate.AudioNif`, an AAudio stream), hands out its four
  ring slots, and samples its stats every 100 ms for the UI (level meter, latency, the clock).

  On a host without the NIF (tests, desktop development) there is no sound, but attached rings are still
  drained at 44.1 kHz by advancing their read index, so firmwares keep running as they would on a
  device.
  """

  use GenServer
  require Logger

  alias FMutate.AudioNif

  @slots 4
  @poll_ms 100
  @drain_ms 5

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Claim a free slot (0..3) for an engine ring; `{:error, :no_free_slot}` when all are taken."
  def claim(owner \\ self()), do: GenServer.call(__MODULE__, {:claim, owner})

  @doc "Give a slot back (detaches its ring)."
  def release(slot), do: GenServer.call(__MODULE__, {:release, slot})

  @doc "Map an engine's ring into the slot; silent until `gain/3`."
  def attach(slot, ring_path), do: GenServer.call(__MODULE__, {:attach, slot, ring_path})

  @doc "Ramp a slot's gain (0..1000) over `ramp_ms`."
  def gain(slot, permille, ramp_ms \\ 0), do: GenServer.cast(__MODULE__, {:gain, slot, permille, ramp_ms})

  @doc """
  The last stats: `%{frame, rate, peak, latency_ms, xruns, running, sharing, fills, underruns, burst,
  buffer, device_id}`, plus `:at` (monotonic ms when sampled). `peak` is the loudest sample in the last
  100 ms; `burst` the device's callback size in device frames; `device_id` the Android audio device the
  stream plays to (`AudioDeviceInfo` id, 0 when unknown; `FMutate.IO.audio_route/0` names it).
  """
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc """
  How far ahead (44.1 kHz frames) an engine should keep its ring: two of the device's callbacks plus a
  margin, at least 1024. The device takes audio in bursts; a ring shallower than two of them underruns
  (a Moto G Power 2021 in shared mode did, at 1024). iOS (engines in-process, RemoteIO's steady 5 ms
  callbacks) takes a 256-frame margin and no 1024 floor: about 700 frames, 16 ms (an iPhone SE played a
  minute of chords at 704 with no underrun, and input reached the mixer ~9 ms sooner than at 1024); Auto
  still climbs if one comes.
  """
  def engine_fill do
    {margin, floor} = if FMutate.Paths.inproc?(), do: {256, 512}, else: {512, 1024}

    case stats() do
      %{burst: burst, rate: rate} when burst > 0 and rate > 0 ->
        (2 * burst * 44_100 / rate + margin) |> round() |> max(floor) |> min(3072)

      _ ->
        1024
    end
  end

  ## Server

  @impl true
  def init(_opts) do
    native = AudioNif.loaded?()

    if native do
      case AudioNif.start() do
        :ok -> :ok
        {:error, reason} -> Logger.error("audio output did not start: #{reason}")
      end

      Process.send_after(self(), :poll, @poll_ms)
      {:ok, %{native: true, owners: %{}, drains: %{}, stats: Map.put(AudioNif.stats(), :at, now())}}
    else
      Process.send_after(self(), :drain, @drain_ms)
      {:ok, %{native: false, owners: %{}, drains: %{}, stats: empty_stats()}}
    end
  end

  @impl true
  def handle_call({:claim, owner}, _from, state) do
    case Enum.find(0..(@slots - 1), &(not Map.has_key?(state.owners, &1))) do
      nil -> {:reply, {:error, :no_free_slot}, state}
      slot -> {:reply, {:ok, slot}, put_in(state.owners[slot], owner)}
    end
  end

  def handle_call({:release, slot}, _from, state) do
    if state.native, do: AudioNif.detach(slot)
    {:reply, :ok, %{state | owners: Map.delete(state.owners, slot), drains: close_drain(state.drains, slot)}}
  end

  def handle_call({:attach, slot, path}, _from, %{native: true} = state),
    do: {:reply, AudioNif.attach(slot, path), state}

  def handle_call({:attach, slot, path}, _from, state) do
    drains = close_drain(state.drains, slot)

    case :file.open(path, [:read, :write, :binary, :raw]) do
      {:ok, fd} ->
        {:ok, <<w::little-64>>} = :file.pread(fd, 16, 8)
        :ok = :file.pwrite(fd, 24, <<w::little-64>>)
        {:reply, :ok, %{state | drains: Map.put(drains, slot, {fd, now(), 0})}}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | drains: drains}}
    end
  end

  def handle_call(:stats, _from, state), do: {:reply, state.stats, state}

  @impl true
  def handle_cast({:gain, slot, permille, ramp_ms}, state) do
    if state.native, do: AudioNif.gain(slot, permille, ramp_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, %{state | stats: Map.put(AudioNif.stats(), :at, now())}}
  end

  # host: consume each attached ring at 44.1 kHz (the audio is discarded). Frames are counted from the attach
  # time, so rounding doesn't drift the rate; like an output, it doesn't wait for an engine that is behind.
  def handle_info(:drain, state) do
    Process.send_after(self(), :drain, @drain_ms)
    t = now()

    drains =
      Map.new(state.drains, fn {slot, {fd, t0, taken}} ->
        due = div((t - t0) * 44_100, 1000)

        with true <- due > taken,
             {:ok, <<w::little-64, r::little-64>>} <- :file.pread(fd, 16, 16) do
          :file.pwrite(fd, 24, <<min(w, r + due - taken)::little-64>>)
          {slot, {fd, t0, due}}
        else
          _ -> {slot, {fd, t0, taken}}
        end
      end)

    {:noreply, %{state | drains: drains}}
  end

  defp close_drain(drains, slot) do
    case Map.pop(drains, slot) do
      {nil, drains} -> drains
      {{fd, _, _}, drains} -> :file.close(fd) && drains
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp empty_stats do
    %{
      frame: 0,
      rate: 44_100,
      peak: 0,
      latency_ms: nil,
      xruns: 0,
      # (the host drain consumes the rings as an output would)
      running: true,
      sharing: :none,
      fills: List.duplicate(0, @slots),
      underruns: List.duplicate(0, @slots),
      burst: 0,
      buffer: 0,
      device_id: 0,
      at: now()
    }
  end
end
