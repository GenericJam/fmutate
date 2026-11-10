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
  The last stats: `%{frame, rate, peak, latency_ms, xruns, running, sharing, fills, underruns}`, plus
  `:at` (monotonic ms when sampled). `peak` is the loudest sample in the last 100 ms.
  """
  def stats, do: GenServer.call(__MODULE__, :stats)

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
    else
      Process.send_after(self(), :drain, @drain_ms)
    end

    {:ok, %{native: native, owners: %{}, drains: %{}, stats: empty_stats()}}
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
        {:reply, :ok, %{state | drains: Map.put(drains, slot, {fd, now()})}}

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

  # host: consume each attached ring at 44.1 kHz (the audio is discarded)
  def handle_info(:drain, state) do
    Process.send_after(self(), :drain, @drain_ms)
    t = now()

    drains =
      Map.new(state.drains, fn {slot, {fd, last}} ->
        frames = div((t - last) * 44_100, 1000)

        with true <- frames > 0,
             {:ok, <<w::little-64, r::little-64>>} <- :file.pread(fd, 16, 16) do
          :file.pwrite(fd, 24, <<min(w, r + frames)::little-64>>)
          {slot, {fd, last + div(frames * 1000, 44_100)}}
        else
          _ -> {slot, {fd, last}}
        end
      end)

    {:noreply, %{state | drains: drains}}
  end

  defp close_drain(drains, slot) do
    case Map.pop(drains, slot) do
      {nil, drains} -> drains
      {{fd, _}, drains} -> :file.close(fd) && drains
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
      running: false,
      sharing: :none,
      fills: List.duplicate(0, @slots),
      underruns: List.duplicate(0, @slots),
      at: now()
    }
  end
end
