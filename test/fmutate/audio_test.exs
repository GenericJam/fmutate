defmodule FMutate.AudioTest do
  # FMutate.Audio's output side: the stream it opens on mob_audio_io (here MobAudioIo.Fake, config/config.exs)
  # under a double of the mixer NIF, what stats/0 reports from the two, and start/0, stop/0 and running?/0, which
  # FMutate.Background uses as iOS's keep-alive.
  use ExUnit.Case, async: false

  alias FMutate.Audio
  alias MobAudioIo.Fake

  defmodule Mixer do
    # FMutate.AudioNif's functions, as the NIF answers them
    def processor, do: "fm1_mixer"
    def attach(_slot, _path), do: :ok
    def detach(_slot), do: :ok
    def gain(_slot, _permille, _ramp_ms), do: :ok

    def stats,
      do: %{
        frame: 4410,
        rate: 48_000,
        peak: 1234,
        running: true,
        callbacks: 25,
        fills: [700, 0, 0, 0],
        underruns: [2, 0, 0, 0]
      }
  end

  setup do
    Fake.reset()
    :ok = Fake.register_processor("fm1_mixer")
    :ok
  end

  defp start_audio, do: start_supervised!({Audio, mixer: Mixer})

  defp mixer_streams, do: Enum.filter(Fake.status().streams, &(&1.processor == "fm1_mixer"))

  # the stats a poll takes now (the next one would come within 100 ms)
  defp polled_stats(pid) do
    send(pid, :poll)
    Audio.stats()
  end

  test "opens one output for the mixer: a mixing iOS session, stereo" do
    start_audio()

    assert [%{direction: :output, session: :mix, channels: 2, running: true}] = mixer_streams()
  end

  test "stats/0: the mixer's clock, level and slots with the stream's latency, burst, buffer and device" do
    pid = start_audio()

    assert %{
             frame: 4410,
             rate: 48_000,
             peak: 1234,
             fills: [700, 0, 0, 0],
             underruns: [2, 0, 0, 0],
             running: true,
             latency_ms: 8.0,
             xruns: 0,
             sharing: :shared,
             burst: 192,
             buffer: 384,
             device_id: 0,
             at: at
           } = polled_stats(pid)

    assert is_integer(at)
  end

  test "stop/0 closes the output (stats as with none), start/0 opens it again, once" do
    pid = start_audio()
    assert Audio.running?()

    assert :ok = Audio.stop()
    assert mixer_streams() == []
    refute Audio.running?()

    assert %{
             running: false,
             latency_ms: nil,
             xruns: 0,
             burst: 0,
             buffer: 0,
             device_id: 0,
             sharing: :shared
           } =
             polled_stats(pid)

    # (the mixer's half goes on: the clock and the slots aren't the stream's)
    assert %{frame: 4410, fills: [700, 0, 0, 0]} = Audio.stats()

    assert :ok = Audio.start()
    assert :ok = Audio.start()
    assert [_one] = mixer_streams()
    assert Audio.running?()
    assert %{running: true, burst: 192} = polled_stats(pid)
  end

  test "a refused open: the app still starts, without output; start/0 says why, and a later start opens it" do
    :ok = Fake.fail_next_open({:session, "a call holds the session"})
    pid = start_audio()

    refute Audio.running?()
    assert %{running: false, latency_ms: nil} = polled_stats(pid)

    :ok = Fake.fail_next_open({:session, "a call holds the session"})
    assert {:error, {:session, "a call holds the session"}} = Audio.start()
    assert :ok = Audio.start()
    assert Audio.running?()
  end

  test "a stream an earlier owner left (a restarted Audio) is closed first: the mixer renders into one stream" do
    holder = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, stale} = MobAudioIo.open(holder, :output, processor: "fm1_mixer")

    start_audio()

    assert [%{id: id}] = mixer_streams()
    assert id != stale
  end

  test "a stream something else closed is forgotten: start/0 opens a new one" do
    start_audio()
    [%{id: stream}] = mixer_streams()

    :ok = MobAudioIo.close(stream)
    refute Audio.running?()

    assert :ok = Audio.start()
    assert [%{id: new}] = mixer_streams()
    assert new != stream
  end

  test "the stream's own events (a lost device, an interruption) leave it open: mob_audio_io reopens it" do
    start_audio()
    [%{id: stream}] = mixer_streams()

    for {kind, payload} <- [
          device_lost: %{},
          stopped: %{reason: :device_lost, posts_dropped: 0},
          interrupted: %{},
          stopped: %{reason: :interrupted, posts_dropped: 0},
          route_changed: %{reason: :new_rate},
          error: %{reason: :unavailable, detail: "x", while: :resume}
        ],
        do: :ok = Fake.inject(stream, kind, payload)

    assert :ok = Audio.start()
    assert [%{id: ^stream}] = mixer_streams()
  end
end
