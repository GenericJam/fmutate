defmodule FMutate.AftertouchTest do
  # FMutate's OberVave build (native/patches/obervave/poly-aftertouch.patch): MIDI polyphonic aftertouch sets a held
  # note's level, 0 silent .. 127 as played, other notes untouched. The native cartridge through FMutate.Engine, its
  # ring drained in real time by the host Audio (FMutate.PanelEdgesTest.Rig). The waits are on the firmware's own
  # clock: on a loaded host the drain, so the firmware, falls behind the wall clock (by a third in a full `mix test`
  # on a busy Mac), and a release tail read after 900 ms of wall time can be one only ~650 ms old.
  use ExUnit.Case, async: false

  alias FMutate.{Engine, Paths}
  alias FMutate.PanelEdgesTest.Rig

  @moduletag :engine

  setup do
    Rig.setup_data_dir("aftertouch")
    File.mkdir_p!(Paths.data_dir())
    start_supervised!(FMutate.Audio)
    prefix = Path.join(Paths.data_dir(), "at")
    flash = Path.join(Paths.data_dir(), "obervave.bin")
    pid = Rig.start_engine(Paths.engine_bin(), Paths.bundled_cart("obervave"), prefix, flash, 2_500)
    # program 71 (INIT): no arp (factory 01's arp plays notes that aren't the held key) and no effect tails
    Engine.commands(pid, [{:midi, 0xC0, 70, 0}])
    Rig.firmware_wait(pid, 300)
    {:ok, pid: pid, prefix: prefix}
  end

  test "pressure 0 silences a held note, 127 brings it back; a note it isn't for keeps sounding", %{pid: pid, prefix: prefix} do
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
end
