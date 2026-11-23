defmodule FMutate.Audio do
  @moduledoc """
  The audio output: owns the mixer (`FMutate.AudioNif`, the `mob_audio_io` processor `"fm1_mixer"`) and the
  output stream it renders into (`MobAudioIo.open/3`: AAudio on Android, RemoteIO on iOS), hands out the
  mixer's four ring slots, and samples its stats every 100 ms for the UI (level meter, latency, the clock).

  The stream is opened when this process starts, and by `start/0` after `stop/0` (`FMutate.Background` on
  iOS, where the output is the keep-alive). It asks for an exclusive AAudio stream (falling back to shared)
  and, on iOS, a session that mixes with other apps' audio (`session: :mix`: playback, `mixWithOthers`, a
  5 ms IO buffer). `mob_audio_io` keeps it going: it reopens the stream on a new device (headphones in or
  out, a USB device), when an iOS interruption ends or the app returns to the foreground after one, and after
  a new rate or a media-services reset; this process only owns it (the stream closes if this process exits).

  On a host without the NIF (tests, desktop development) there is no sound, but attached rings are still
  drained at 44.1 kHz by advancing their read index, so firmwares keep running as they would on a
  device. `mixer: module` (tests) puts a double of `FMutate.AudioNif` under a real `MobAudioIo` stream (the
  plugin's `MobAudioIo.Fake` on the host).
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
  buffer, device_id}`, plus `:at` (monotonic ms when sampled).

  From the mixer: `frame` (the clock, 44.1 kHz frames mixed), `rate` (the output's rate at its last start),
  `peak` (the loudest sample in the last 100 ms, 0..32767), `fills` and `underruns` (per slot). From the
  output stream (`MobAudioIo.status/1`; `running: false` while it is closed, interrupted or being reopened,
  and then `latency_ms: nil`, `xruns`, `burst`, `buffer`, `device_id` 0 and `sharing: :shared`):
  `latency_ms` (what a rendered frame waits before it is heard: on Android 12+ from AAudio's timestamps, on
  Android 8-11 the frames written but not yet read, on iOS the session's output latency and IO buffer),
  `xruns` (since the stream's platform stream opened), `sharing`, `burst` (the device's callback size in
  device frames: AAudio's burst; iOS: the last callback's frames, 4096 with the screen locked), `buffer`
  (AAudio's buffer; iOS: as `burst`) and `device_id` (the Android audio device the stream plays to,
  `AudioDeviceInfo` id, 0 when unknown or on iOS; `FMutate.IO.audio_route/0` names it).
  """
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc """
  Open the output stream if it isn't open: `:ok` or `{:error, reason}` (`MobAudioIo.open/3`'s). A stream
  already open is left alone, running or not (an interruption or a lost device it is recovering from).
  """
  def start, do: GenServer.call(__MODULE__, :start, 15_000)

  @doc "Close the output stream (on iOS the audio session goes back to other apps once nothing plays). `:ok`."
  def stop, do: GenServer.call(__MODULE__, :stop, 15_000)

  @doc "Whether the output runs now (asked of the stream, not the last stats)."
  def running?, do: GenServer.call(__MODULE__, :running?)

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
  def init(opts) do
    mixer = Keyword.get_lazy(opts, :mixer, fn -> if AudioNif.loaded?(), do: AudioNif end)
    state = %{mixer: mixer, stream: nil, platform: nil, owners: %{}, drains: %{}, stats: nil}

    if mixer do
      {_result, state} = open_output(state)
      Process.send_after(self(), :poll, @poll_ms)
      {:ok, %{state | stats: sample(state)}}
    else
      Process.send_after(self(), :drain, @drain_ms)
      {:ok, %{state | stats: empty_stats()}}
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
    if state.mixer, do: state.mixer.detach(slot)
    {:reply, :ok, %{state | owners: Map.delete(state.owners, slot), drains: close_drain(state.drains, slot)}}
  end

  def handle_call({:attach, slot, path}, _from, %{mixer: mixer} = state) when mixer != nil,
    do: {:reply, mixer.attach(slot, path), state}

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

  # (the host's drain plays the part of an output that always runs)
  def handle_call(:start, _from, %{mixer: nil} = state), do: {:reply, :ok, state}

  def handle_call(:start, _from, %{stream: stream} = state) when stream != nil,
    do: {:reply, :ok, state}

  def handle_call(:start, _from, state) do
    {result, state} = open_output(state)
    {:reply, result, state}
  end

  def handle_call(:stop, _from, %{stream: nil} = state), do: {:reply, :ok, state}

  def handle_call(:stop, _from, state) do
    _ = MobAudioIo.close(state.stream)
    {:reply, :ok, %{state | stream: nil}}
  end

  def handle_call(:running?, _from, %{mixer: nil} = state),
    do: {:reply, state.stats.running, state}

  def handle_call(:running?, _from, state),
    do: {:reply, match?(%{running: true}, output_status(state)), state}

  @impl true
  def handle_cast({:gain, slot, permille, ramp_ms}, state) do
    if state.mixer, do: state.mixer.gain(slot, permille, ramp_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, %{state | stats: sample(state)}}
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

  # The stream's own news (mob_audio_io logs each with a [mob_audio_io] prefix, and reopens the stream itself
  # after a lost device, an interruption or a new rate): the stats poll reads what it did. Only the stream's
  # end matters here, when something else closed it (stop/0 forgets it first).
  def handle_info(
        {:mob_audio_io, :stopped, stream, %{reason: :closed}},
        %{stream: stream} = state
      ) do
    Logger.warning("[fm1audio] output stream #{stream} closed under the mixer")
    {:noreply, %{state | stream: nil}}
  end

  def handle_info({:mob_audio_io, _kind, _stream, _payload}, state), do: {:noreply, state}

  # Open the output for the mixer: {:ok | {:error, reason}, state}. A stream an earlier owner left (this
  # process restarted; mob_audio_io closes it within a few ms of its owner's exit) is closed first: the mixer
  # is one stream's.
  defp open_output(state) do
    processor = state.mixer.processor()
    close_stale(processor)

    opts = [
      processor: processor,
      module: state.mixer,
      channels: 2,
      sharing: :exclusive,
      session: :mix
    ]

    case MobAudioIo.open(self(), :output, opts) do
      {:ok, stream} ->
        {:ok, %{state | stream: stream, platform: platform(state.platform)}}

      {:error, reason} = error ->
        Logger.error("[fm1audio] audio output did not start: #{inspect(reason)}")
        {error, state}
    end
  end

  defp close_stale(processor) do
    case MobAudioIo.status() do
      %{streams: streams} ->
        for %{id: id, processor: ^processor} <- streams, do: MobAudioIo.close(id)

      _ ->
        :ok
    end
  end

  defp platform(nil) do
    case MobAudioIo.status() do
      %{platform: platform} -> platform
      _ -> nil
    end
  end

  defp platform(known), do: known

  defp output_status(%{stream: nil}), do: nil

  defp output_status(%{stream: stream}) do
    case MobAudioIo.status(stream) do
      %{} = status -> status
      {:error, _} -> nil
    end
  end

  # the stats/0 map: the mixer's half and the output stream's
  defp sample(state) do
    mix = state.mixer.stats()

    out =
      case output_status(state) do
        %{running: true} = status -> status
        _ -> nil
      end

    burst = callback_frames(out, state.platform)

    %{
      frame: mix.frame,
      rate: mix.rate,
      peak: mix.peak,
      fills: mix.fills,
      underruns: mix.underruns,
      running: out != nil,
      latency_ms: out && out.latency_ms,
      xruns: if(out, do: out.xruns, else: 0),
      sharing: if(out, do: out.sharing, else: :shared),
      burst: burst,
      buffer: if(out && state.platform != :ios, do: out.buffer, else: burst),
      device_id: if(out, do: out.device_id, else: 0),
      at: now()
    }
  end

  # iOS calls the render with the IO buffer's frames, but with the screen locked with 4096 at a time: the
  # frames the last callback had, as the device takes them (the burst until one has run)
  defp callback_frames(nil, _platform), do: 0
  defp callback_frames(%{cb_frames: n}, :ios) when n > 0, do: n
  defp callback_frames(out, _platform), do: out.burst

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
