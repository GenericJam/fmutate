defmodule FMutate.AftertouchTest do
  # FMutate's OberVave build (native/patches/obervave/poly-aftertouch.patch): MIDI polyphonic aftertouch sets a held
  # note's level, 0 silent .. 127 as played, other notes untouched; and a note's velocity (what a keyboard strip
  # sends from where a key is struck) sets how loud it starts. The cartridge as each platform runs it: the engine
  # executable (Android) and in-process on a thread of the app (iOS: native/build_ios.sh's host build,
  # c_src/fm1host.c, macOS only), each through FMutate.Engine with its ring drained in real time by the host Audio
  # (FMutate.PanelEdgesTest.Rig). The waits are on the firmware's own clock: on a loaded host the drain, so the
  # firmware, falls behind the wall clock (by a third in a full `mix test` on a busy Mac), and a release tail read
  # after 900 ms of wall time can be one only ~650 ms old. Levels are the ring's RMS: OberVave's detuned
  # oscillators beat, so a window's level wanders by a fifth or so; the margins below are wider than that.
  use ExUnit.Case, async: false

  alias FMutate.{Engine, EngineNif, Paths}
  alias FMutate.PanelEdgesTest.Rig

  @moduletag :engine
  @nif Path.expand("native/build/host/fm1host.so")

  setup ctx do
    Rig.setup_data_dir("aftertouch")
    File.mkdir_p!(Paths.data_dir())
    start_supervised!(FMutate.Audio)
    prefix = Path.join(Paths.data_dir(), "at")
    flash = Path.join(Paths.data_dir(), "obervave.bin")

    pid =
      case ctx.engine do
        :executable ->
          Rig.start_engine(
            Paths.engine_bin(),
            Paths.bundled_cart("obervave"),
            prefix,
            flash,
            2_500
          )

        :inproc ->
          # (when the test process ends, the engine goes with it and the NIF closes its pipe; the next test's
          # start waits for the cartridge if its thread is still ending)
          :ok = EngineNif.load_host(@nif)
          Rig.start_engine(:inproc, "obervave", prefix, flash, 2_500, backend: :native)
      end

    {:ok, pid: pid, prefix: prefix}
  end

  defp program(pid, n) do
    Engine.commands(pid, [{:midi, 0xC0, n, 0}])
    Rig.firmware_wait(pid, 300)
  end

  # the level `ms` long, once the firmware has played on for `wait` ms
  defp level_after(pid, prefix, wait, ms \\ 300) do
    Rig.firmware_wait(pid, wait)
    Rig.rms_during(prefix, ms)
  end

  for engine <- [:executable, :inproc] do
    describe "#{engine}" do
      @describetag engine: engine
      if engine == :inproc and not File.exists?(@nif) do
        @describetag skip: "run TARGETS=host native/build_ios.sh (macOS): no #{@nif}"
      end

      # program 71 (INIT): no arp (factory 01's arp plays notes that aren't the held key) and no effect tails
      test "pressure 0 silences a held note, 127 brings it back; a note it isn't for keeps sounding",
           %{pid: pid, prefix: prefix} do
        program(pid, 70)
        Engine.commands(pid, [{:midi, 0x90, 60, 127}])
        Rig.firmware_wait(pid, 300)
        held = Rig.peak_during(prefix, 300)
        assert held > 1000

        # the voice goes silent at once; what's left is the program's effects dying away, as after a note-off
        Engine.commands(pid, [{:midi, 0xA0, 60, 0}])
        Rig.firmware_wait(pid, 900)
        assert Rig.peak_during(prefix, 300) < held / 8

        Engine.commands(pid, [{:midi, 0xA0, 60, 127}])
        Rig.firmware_wait(pid, 150)
        assert Rig.peak_during(prefix, 300) > held / 2

        # pressure on a key that isn't sounding changes nothing
        Engine.commands(pid, [{:midi, 0xA0, 64, 0}])
        Rig.firmware_wait(pid, 150)
        assert Rig.peak_during(prefix, 300) > held / 2
        Engine.commands(pid, [{:midi, 0x80, 60, 0}])
      end

      # what a finger sliding back on a held key and forward again sends (square law: 64 is a quarter, 16 1/63)
      test "a held note's level falls as the pressure falls and rises again with it", %{
        pid: pid,
        prefix: prefix
      } do
        program(pid, 70)
        Engine.commands(pid, [{:midi, 0x90, 60, 127}])
        full = level_after(pid, prefix, 300)

        Engine.commands(pid, [{:midi, 0xA0, 60, 64}])
        half = level_after(pid, prefix, 150)
        Engine.commands(pid, [{:midi, 0xA0, 60, 16}])
        low = level_after(pid, prefix, 150)
        Engine.commands(pid, [{:midi, 0xA0, 60, 127}])
        back = level_after(pid, prefix, 150)
        Engine.commands(pid, [{:midi, 0x80, 60, 0}])

        assert full > 500
        assert half < full * 0.7
        assert low < half * 0.8 and low < full * 0.35
        assert back > low * 3 and back > full * 0.45
      end

      # what a strike at a key's front edge (velocity 127) and at its back edge (40, a strip's default softest)
      # sends; factory program 01 (VEL>AMP 60, VEL>FLT 40)
      test "a note struck at the front edge's velocity starts louder than one at the back edge's",
           %{pid: pid, prefix: prefix} do
        program(pid, 0)

        strike = fn vel ->
          Engine.commands(pid, [{:midi, 0x90, 60, vel}])
          level = level_after(pid, prefix, 300, 600)
          Engine.commands(pid, [{:midi, 0x80, 60, 0}])
          Rig.firmware_wait(pid, 1_200)
          level
        end

        front = strike.(127)
        back = strike.(40)
        assert front > 500
        assert back < front * 0.8
      end
    end
  end
end
