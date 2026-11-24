defmodule FMutate.AftertouchTest do
  # FMutate's OberVave and Shine On builds (native/patches/{obervave,shineon}/poly-aftertouch.patch): MIDI polyphonic
  # aftertouch sets a held note's level, 0 silent .. 127 as played, other notes untouched; and a note's velocity (what
  # a keyboard strip sends from where a key is struck) sets how loud it starts. The cartridge as each platform runs it:
  # the engine executable (Android) and in-process on a thread of the app (iOS: native/build_ios.sh's host build,
  # c_src/fm1host.c, macOS only), each through FMutate.Engine with its ring drained in real time by the host Audio
  # (FMutate.PanelEdgesTest.Rig). The waits are on the firmware's own clock: on a loaded host the drain, so the
  # firmware, falls behind the wall clock (by a third in a full `mix test` on a busy Mac), and a release tail read
  # after 900 ms of wall time can be one only ~650 ms old. Levels are the ring's RMS: OberVave's detuned
  # oscillators and Shine On's ensemble beat, so a window's level wanders by a fifth or so; the margins below are
  # wider than that.
  use ExUnit.Case, async: false

  alias FMutate.{Engine, EngineNif, Paths}
  alias FMutate.PanelEdgesTest.Rig

  @moduletag :engine
  @nif Path.expand("native/build/host/fm1host.so")

  @firmwares [
    %{
      id: "obervave",
      # program 71 (INIT): no arp (factory 01's arp plays notes that aren't the held key) and no effect tails
      steady: 70,
      strikes: [{"INIT", 70}, {"factory 01", 0}],
      # factory 08 ARP SEQ: up, 2 octaves, so every other step is the key an octave up, another pitch
      arp: 7,
      # factory 03 SYNC LEAD (MONO): a second key slides the voice over and letting it go hands it back
      mono: 2
    },
    %{
      id: "shineon",
      # program 15 (STACCATO): fast attack/release, no arp (INIT/factory 01 have a slow string swell)
      steady: 14,
      strikes: [{"INIT", 32}, {"factory 01", 0}],
      # factory 18 ARP STRINGS: up, 2 octaves
      arp: 17,
      mono: nil
    }
  ]

  setup ctx do
    Rig.setup_data_dir("aftertouch")
    File.mkdir_p!(Paths.data_dir())
    start_supervised!(FMutate.Audio)
    fw = ctx.fw
    prefix = Path.join(Paths.data_dir(), "at")
    flash = Path.join(Paths.data_dir(), "#{fw}.bin")

    pid =
      case ctx.engine do
        :executable ->
          Rig.start_engine(
            Paths.engine_bin(),
            Paths.bundled_cart(fw),
            prefix,
            flash,
            2_500
          )

        :inproc ->
          # (when the test process ends, the engine goes with it and the NIF closes its pipe; the next test's
          # start waits for the cartridge if its thread is still ending)
          :ok = EngineNif.load_host(@nif)
          Rig.start_engine(:inproc, fw, prefix, flash, 2_500, backend: :native)
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

  for fw <- @firmwares, engine <- [:executable, :inproc] do
    describe "#{fw.id} #{engine}" do
      @describetag fw: fw.id, engine: engine
      if engine == :inproc and not File.exists?(@nif) do
        @describetag skip: "run TARGETS=host native/build_ios.sh (macOS): no #{@nif}"
      end

      test "pressure 0 silences a held note, 127 brings it back; a note it isn't for keeps sounding",
           %{pid: pid, prefix: prefix} do
        program(pid, unquote(fw.steady))
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

      # per-note isolation: holding two notes on the same part, silencing one drops it while the other stays at its
      # level, and 127 restores the silenced note (notes 72/76 settle past decay and span >1 beat cycle in 1 s)
      test "pressure on one of two held notes leaves the other at its level and 127 restores it",
           %{pid: pid, prefix: prefix} do
        program(pid, unquote(fw.steady))
        db = fn a, b -> 20 * :math.log10(a / b) end

        Engine.commands(pid, [{:midi, 0x90, 72, 127}])
        solo = level_after(pid, prefix, 800, 1_000)

        Engine.commands(pid, [{:midi, 0x90, 76, 127}])
        both = level_after(pid, prefix, 800, 1_000)

        Engine.commands(pid, [{:midi, 0xA0, 76, 0}])
        muted = level_after(pid, prefix, 900, 1_000)

        Engine.commands(pid, [{:midi, 0xA0, 76, 127}])
        restored = level_after(pid, prefix, 400, 1_000)

        Engine.commands(pid, [{:midi, 0x80, 72, 0}, {:midi, 0x80, 76, 0}])

        assert solo > 500
        assert db.(both, solo) >= 1.2
        assert db.(muted, both) <= -1.2
        assert abs(db.(muted, solo)) <= 1.5
        assert db.(restored, muted) >= 1.2
        assert abs(db.(restored, both)) <= 1.5
      end

      # what a finger sliding back on a held key and forward again sends (square law: 64 is a quarter, 16 1/63)
      test "a held note's level falls as the pressure falls and rises again with it", %{
        pid: pid,
        prefix: prefix
      } do
        program(pid, unquote(fw.steady))
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

      # what a strip at its default range sends for a strike at the top of a key (its back edge), the middle and the
      # bottom (the front edge): velocity 40, 84 and 127, each with its strike level (MIDI polyphonic aftertouch; 49,
      # 79 and 127: StrikeMath.kt). OberVave's and Shine On's own velocity response is modest on INIT and factory 01;
      # the level makes the strike heard.
      for {name, n} <- fw.strikes do
        test "a strike at the top of a key plays clearly quieter than one in the middle, the middle than the bottom (#{name})",
             %{pid: pid, prefix: prefix} do
          program(pid, unquote(n))

          strike = fn vel, level ->
            Engine.commands(pid, [{:midi, 0x90, 60, vel}, {:midi, 0xA0, 60, level}])
            rms = level_after(pid, prefix, 250, 500)
            Engine.commands(pid, [{:midi, 0x80, 60, 0}])
            Rig.firmware_wait(pid, 1_500)
            rms
          end

          bottom = strike.(127, 127)
          middle = strike.(84, 79)
          top = strike.(40, 49)
          db = fn a, b -> 20 * :math.log10(a / b) end

          assert bottom > 500
          assert db.(top, bottom) <= -12
          assert db.(middle, bottom) <= -4 and db.(top, middle) <= -4
        end
      end

      # a held key's arp plays its steps in every octave at the key's level; the quiet strike first, so the full one's
      # echoes don't land in its window
      test "an arp's octave steps play at their key's level", %{pid: pid, prefix: prefix} do
        program(pid, unquote(fw.arp))

        hold = fn level ->
          Engine.commands(pid, [{:midi, 0x90, 60, 127}, {:midi, 0xA0, 60, level}])
          rms = level_after(pid, prefix, 300, 1_200)
          Engine.commands(pid, [{:midi, 0x80, 60, 0}])
          Rig.firmware_wait(pid, 2_500)
          rms
        end

        quiet = hold.(49)
        full = hold.(127)
        assert full > 300
        assert 20 * :math.log10(quiet / full) <= -12
      end

      if fw.mono do
        # MONO: a second key slides the voice over and letting it go hands the voice back to the first key, each at
        # its own level, with no new note-on (or pressure) for the key taking over
        test "a mono voice plays the level of the key it sounds", %{pid: pid, prefix: prefix} do
          program(pid, unquote(fw.mono))
          db = fn a, b -> 20 * :math.log10(a / b) end

          Engine.commands(pid, [{:midi, 0x90, 60, 127}, {:midi, 0xA0, 60, 49}])
          first = level_after(pid, prefix, 300, 500)
          Engine.commands(pid, [{:midi, 0x90, 62, 127}, {:midi, 0xA0, 62, 127}])
          second = level_after(pid, prefix, 300, 500)
          Engine.commands(pid, [{:midi, 0x80, 62, 0}])
          back = level_after(pid, prefix, 300, 500)
          Engine.commands(pid, [{:midi, 0x80, 60, 0}])

          assert second > 300
          assert db.(first, second) <= -12
          assert db.(back, second) <= -12
        end
      end
    end
  end
end
