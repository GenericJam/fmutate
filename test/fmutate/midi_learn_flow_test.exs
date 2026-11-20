defmodule FMutate.MIDILearnFlowTest do
  # FMutate.MIDI with a real instance (native/build_host.sh): MIDI learn from the editor's sheet, learned and
  # automapped controls reaching the instance, persistence, and what the surface is told.
  use ExUnit.Case, async: false

  alias FMutate.{Editor, Instance, LayoutEdit, Layouts, MIDI}

  @moduletag :engine
  @mpk 7
  @mk2 9

  setup do
    unless File.exists?(FMutate.Paths.engine_bin()),
      do: raise("run native/build_host.sh first: no #{FMutate.Paths.engine_bin()}")

    dir = Path.join(System.tmp_dir!(), "fmutate_test_#{System.unique_integer([:positive])}")
    Application.put_env(:fmutate_app, :data_dir, dir)
    start_supervised!({Registry, keys: :unique, name: FMutate.Registry})
    start_supervised!(FMutate.Audio)
    start_supervised!({Instance, id: "a"}, id: {:instance, "a"})
    me = self()
    start_midi(me)

    on_exit(fn ->
      Application.delete_env(:fmutate_app, :data_dir)
      File.rm_rf(dir)
    end)

    {:ok, firmware: Instance.view("a").firmware}
  end

  defp start_midi(me) do
    start_supervised!({MIDI, id: "a", surface: &send(me, {:surface, IO.iodata_to_binary(&1)})}, id: {:midi, "a"})
    # a USB controller called "MPK mini 3" is plugged in, and another one
    send(GenServer.whereis(MIDI.via("a")), {:io, %{midi: [%{id: @mpk, name: "MPK mini 3"}, %{id: 8, name: "Box"}, %{id: @mk2, name: "MPK Mini Mk II"}]}})
  end

  defp play(device, bytes) do
    t = System.monotonic_time(:nanosecond)
    send(GenServer.whereis(MIDI.via("a")), {:midi, :raw, %{device: device, port: 0, bytes: IO.iodata_to_binary(bytes), timestamp: t, received: t}})
    # settle: the MIDI process has handled it and its casts to the instance are in
    _ = MIDI.settings("a")
    _ = Instance.held("a")
  end

  defp inputs(n \\ 50), do: for({_, :in, event, _} <- Instance.journal("a", n), do: event)

  defp socket(firmware) do
    Mob.Socket.new(FMutate.InstrumentScreen)
    |> Mob.Socket.assign(:editing, true)
    |> Editor.load("a", firmware)
  end

  test "learn from the sheet: the CC drives KNOB1, the knob shows it, and the CC no longer reaches the firmware",
       %{firmware: fw} do
    s = Editor.event("edit_open", %{"id" => "knob1"}, socket(fw))
    s = Editor.dispatch(:tap, {:editor, {:learn, "value"}}, nil, s)
    assert s.assigns.learning == {"knob1", nil, "value"}

    # learning plays nothing
    play(8, [0xB0, 74, 40, 0xB0, 74, 41])
    refute Enum.any?(inputs(), &match?({:midi, _}, &1))
    assert_receive {:midi_learn, "a", {:ok, m}}, 2_000
    assert m == %{"on" => "value", "type" => "cc", "channel" => 1, "number" => 74, "device" => "Box"}

    s = Editor.learned(s, {:ok, m})
    assert LayoutEdit.midi_in(s.assigns.layout, "knob1") == [m]
    assert LayoutEdit.midi_in(Layouts.current("a", fw), "knob1") == [m]

    play(8, for(v <- 0..64, do: [0xB0, 74, v]))
    clicks = for {:encoder, :knob1, n} <- inputs(200), do: n
    assert Enum.sum(clicks) == 32
    refute Enum.any?(inputs(200), &match?({:midi, <<0xB0, 74, _>>}, &1))
    # the knob's bubble names the hardware control
    assert_receive {:surface, "g\tknob1\tCC74\ne\tknob1\t" <> _}

    # the same CC from the MPK mini isn't the learned one (another device): there it is knob 5, automapped to
    # SELECT; a CC the MPK doesn't automap (CC 1) is still raw MIDI to the firmware
    play(@mpk, [0xB0, 74, 3, 0xB0, 74, 30])
    assert Enum.any?(inputs(), &match?({:encoder, :select, _}, &1))
    play(@mpk, [0xB0, 1, 3])
    assert {:midi, <<0xB0, 1, 3>>} in inputs()
  end

  test "a learned pad presses ARP; the keys' note of the same number still plays; I/O clears it", %{firmware: fw} do
    {:ok, l} = LayoutEdit.set_midi_in(Layouts.current("a", fw), "arp", nil, %{"on" => "press", "type" => "note", "channel" => 10, "number" => 50, "device" => "MPK mini 3"})
    :ok = Layouts.save("a", fw, l)

    play(@mpk, [0x99, 50, 100, 0x89, 50, 0, 0x90, 60, 100, 0x80, 60, 0])
    assert Enum.take(inputs(), 4) |> Enum.reverse() == [{:button, :arp, :down}, {:button, :arp, :up}, {:key, 7, :down}, {:key, 7, :up}]
    assert_receive {:surface, "p\tarp\t1" <> _}

    assert [%{control: "arp", device: "MPK mini 3", message: "note D3 (50) ch 10"}] = MIDI.settings("a").learned
    :ok = MIDI.clear_learned("a", {:device, "MPK mini 3"})
    assert MIDI.settings("a").learned == []
    play(@mpk, [0x99, 50, 100])
    # pad 15 of an MPK mini mk3 isn't automapped: a note to the firmware again
    assert hd(inputs()) == {:midi, <<0x99, 50, 100>>}
  end

  test "automap: MPK mini mk3 knobs and pads drive the panel, keys keep playing; off and on again" do
    play(@mpk, [0xB0, 70, 0, 0xB0, 70, 127, 0x99, 36, 90, 0x89, 36, 0, 0x90, 60, 90])
    assert Enum.sum(for {:encoder, :knob1, n} <- inputs(), do: n) == 64
    assert {:button, :fx, :down} in inputs() and {:button, :fx, :up} in inputs()
    assert hd(inputs()) == {:key, 7, :down}

    :ok = MIDI.set_automap("a", "MPK mini 3", false)
    play(@mpk, [0x99, 36, 90])
    assert hd(inputs()) == {:midi, <<0x99, 36, 90>>}
    assert %{on: false} = MIDI.settings("a").automap["MPK mini 3"]
  end

  test "automap, first touch: an unknown controller's knobs and pads in the order touched, kept across restarts" do
    play(8, [0xB0, 64, 127, 0xB2, 20, 5, 0xB2, 18, 5, 0x99, 40, 90, 0x89, 40, 0])
    # the pedal isn't a knob: raw to the firmware
    assert {:midi, <<0xB0, 64, 127>>} in inputs()
    assert {:button, :fx, :down} in inputs()
    assert [{nil, "CC 20 ch 3", :automap, "KNOB1"}, {nil, "CC 18 ch 3", :automap, "KNOB2"}] = rows("Box")
    assert [%{msg: "note 40 ch 10", to: "FX"}] = Enum.filter(MIDI.settings("a").automap["Box"].rows, &(&1.kind == :pad))

    stop_supervised!({:midi, "a"})
    start_midi(self())
    play(8, [0xB2, 18, 0, 0xB2, 18, 127])
    assert Enum.sum(for {:encoder, :knob2, n} <- inputs(), do: n) == 64

    :ok = MIDI.reset_automap("a", "Box")
    play(8, [0xB2, 18, 0, 0xB2, 18, 10])
    assert Enum.take(inputs(), 1) == [{:encoder, :knob1, 5}]
  end

  test "automap knob 8 is MASTER, with pickup against the on-screen MASTER" do
    # the instance has MASTER at 1.0: the knob at the bottom is ignored until it comes up
    play(@mpk, [0xB0, 77, 0, 0xB0, 77, 60])
    refute Enum.any?(inputs(), &match?({:pot, _, _}, &1))
    play(@mpk, [0xB0, 77, 126])
    assert {:pot, :master, v} = hd(inputs())
    assert_in_delta v, 126 / 127, 0.001
    assert_receive {:surface, "v\tmidi\tpot:master\t0.9921"}

    # a finger on the on-screen MASTER (rule 7 through FMutate.MIDI) takes it down; the knob is stale again
    for v <- [0.97, 0.9, 0.8], do: MIDI.surface_in("a", %{"t" => "pot", "v" => v, "c" => "master"})
    play(@mpk, [0xB0, 77, 120])
    assert hd(inputs()) == {:pot, :master, 0.8}
  end

  ## Lining up a controller's knobs (FMutate.MIDI.Automap, Mapping, Params; the I/O screen's table)

  # Kevin's MPK mini mk2 capture (test/fixtures/mpk-mini-mk2-knobs.txt): K1..K8 turned in order, channel 1
  defp kevin_bytes do
    for line <- File.stream!("test/fixtures/mpk-mini-mk2-knobs.txt"),
        [_, cc, v] <- [Regex.run(~r/ch1 cc (\d+) val (\d+)/, line)],
        do: [0xB0, String.to_integer(cc), String.to_integer(v)]
  end

  defp rows(name), do: for(r <- MIDI.settings("a").automap[name].rows, r.kind == :knob, do: {r.hw, r.msg, r.via, r.to})

  defp moved?(match), do: Enum.any?(inputs(400), match)

  test "Kevin's MPK mini mk2 (PROG 2): K1..K8 drive KNOB1..4, SELECT, PRESETS, ALGO, MASTER; none reaches the firmware" do
    play(@mk2, kevin_bytes())
    for enc <- ~w(knob1 knob2 knob3 knob4 select presets algorithm)a, do: assert(moved?(&match?({:encoder, ^enc, _}, &1)), "#{enc}")
    refute moved?(&match?({:midi, <<0xB0, cc, _>>} when cc in 16..23, &1))

    assert rows("MPK Mini Mk II") ==
             for({k, cc, to} <- Enum.zip([~w(K1 K2 K3 K4 K5 K6 K7 K8), [20, 21, 22, 23, 16, 17, 18, 19], ~w(KNOB1 KNOB2 KNOB3 KNOB4 SELECT PRESETS ALGO MASTER)]),
                 do: {k, "CC #{cc}", :automap, to})

    assert %{profile: "AKAI MPK mini mk2", program: "PROG 2"} = MIDI.settings("a").automap["MPK Mini Mk II"]
    # K8 is MASTER, with pickup: the knob comes up to the instance's MASTER (1.0) before it moves it
    play(@mk2, [0xB0, 19, 127, 0xB0, 19, 64])
    assert {:pot, :master, v} = hd(inputs())
    assert_in_delta v, 64 / 127, 0.001
  end

  test "a known controller off its factory programs: first touch from its first stranger CC, kept by name" do
    play(@mk2, [0xB0, 20, 1, 0xB0, 40, 1, 0xB0, 41, 1])
    assert %{by: :touch} = MIDI.settings("a").automap["MPK Mini Mk II"]
    assert [{nil, "CC 20", :automap, "KNOB1"}, {nil, "CC 40", :automap, "KNOB2"}, {nil, "CC 41", :automap, "KNOB3"} | _] = rows("MPK Mini Mk II")

    stop_supervised!({:midi, "a"})
    start_midi(self())
    play(@mk2, [0xB0, 41, 0, 0xB0, 41, 20])
    assert Enum.sum(for {:encoder, :knob3, n} <- inputs(), do: n) == 10

    :ok = MIDI.reset_automap("a", "MPK Mini Mk II")
    assert %{by: :auto, program: "PROG 1"} = MIDI.settings("a").automap["MPK Mini Mk II"]
  end

  test "line up: turn the knob for KNOB1, skip KNOB2, the next for KNOB3; kept as the device's order" do
    :ok = MIDI.line_up("a", "MPK Mini Mk II")
    assert_receive {:midi, "a", {:line_up, %{step: 0, slots: [%{target: "KNOB1", key: nil} | _]}}}

    # lining up drives nothing; a knob turned on and on takes one target
    play(@mk2, [0xB0, 16, 3, 0xB0, 16, 9])
    assert_receive {:midi, "a", {:line_up, %{step: 1, slots: [%{key: {1, 16}} | _]}}}
    refute moved?(&match?({:encoder, _, _}, &1))
    refute_received {:midi, "a", {:line_up, %{step: 2}}}

    :ok = MIDI.line_up_skip("a")
    play(@mk2, [0xB0, 20, 3])
    assert_receive {:midi, "a", {:line_up, %{step: 3, slots: [_, %{key: nil}, %{key: {1, 20}, label: "K1 (CC 20)"} | _]}}}
    :ok = MIDI.line_up_done("a")
    assert_receive {:midi, "a", {:line_up, nil}}

    assert [{"K1", "CC 20", :automap, "KNOB3"}, {"K2", "CC 21", :synth, _} | _] = rows("MPK Mini Mk II")
    assert {"K5", "CC 16", :automap, "KNOB1"} in rows("MPK Mini Mk II")
    assert "KNOB2" in MIDI.settings("a").automap["MPK Mini Mk II"].free
    play(@mk2, [0xB0, 16, 0, 0xB0, 16, 20, 0xB0, 21, 5])
    assert Enum.sum(for {:encoder, :knob1, n} <- inputs(), do: n) == 10
    # K2 (CC 21) was skipped: it is no knob of the panel now, and goes to the firmware (OberVave: OSC 1 · PW)
    assert {:midi, <<0xB0, 21, 5>>} in inputs()
    assert {"K2", "CC 21", :synth, "OberVave: OSC 1 · PW"} in rows("MPK Mini Mk II")

    # kept across restarts; Reset forgets it
    stop_supervised!({:midi, "a"})
    start_midi(self())
    assert {"K5", "CC 16", :automap, "KNOB1"} in rows("MPK Mini Mk II")
    :ok = MIDI.reset_automap("a", "MPK Mini Mk II")
    assert %{by: :auto} = MIDI.settings("a").automap["MPK Mini Mk II"]
  end

  test "a line-up whose screen goes away ends; cancel keeps the order the device had" do
    task = Task.async(fn -> MIDI.line_up("a", "MPK Mini Mk II") end)
    :ok = Task.await(task)
    ref = Process.monitor(task.pid)
    assert_receive {:DOWN, ^ref, :process, _, _}
    Process.sleep(50)
    play(@mk2, [0xB0, 20, 3])
    assert %{program: "PROG 2"} = MIDI.settings("a").automap["MPK Mini Mk II"]

    :ok = MIDI.line_up("a", "MPK Mini Mk II")
    play(@mk2, [0xB0, 16, 3])
    :ok = MIDI.line_up_cancel("a")
    assert %{by: :auto} = MIDI.settings("a").automap["MPK Mini Mk II"]
    # K1 (3 → 13) still turns KNOB1: 5 clicks
    play(@mk2, [0xB0, 20, 13])
    assert Enum.sum(for {:encoder, :knob1, n} <- inputs(), do: n) == 5
  end

  test "pin a knob to a synth parameter: its CC to the firmware, per firmware, kept; learned > pin > automap",
       %{firmware: fw} do
    play(@mk2, [0xB0, 20, 0])
    assert {:error, :unknown} = MIDI.pin("a", "MPK Mini Mk II", {1, 20}, "NOPE · NOTHING")
    :ok = MIDI.pin("a", "MPK Mini Mk II", {1, 20}, "PERFORM · CUTOFF")
    assert {"K1", "CC 20", :pin, "PERFORM · CUTOFF"} in rows("MPK Mini Mk II")
    assert "KNOB1" in MIDI.settings("a").automap["MPK Mini Mk II"].free

    # K1 sends OberVave's CUTOFF (CC 74), the value as the knob has it; KNOB1 no longer turns
    play(@mk2, [0xB0, 20, 100])
    assert hd(inputs()) == {:midi, <<0xB0, 74, 100>>}
    refute moved?(&match?({:encoder, :knob1, _}, &1))

    # a control's learned input wins over the pin
    {:ok, l} = LayoutEdit.set_midi_in(Layouts.current("a", fw), "knob2", nil, %{"on" => "value", "type" => "cc", "channel" => 1, "number" => 20, "device" => "MPK Mini Mk II"})
    :ok = Layouts.save("a", fw, l)
    play(@mk2, [0xB0, 20, 0, 0xB0, 20, 10])
    assert moved?(&match?({:encoder, :knob2, _}, &1))
    assert {"K1", "CC 20", :learned, _} = List.keyfind(rows("MPK Mini Mk II"), "K1", 0)
    :ok = MIDI.clear_learned("a", {:device, "MPK Mini Mk II"})

    # kept across restarts
    stop_supervised!({:midi, "a"})
    start_midi(self())
    play(@mk2, [0xB0, 20, 30])
    assert hd(inputs()) == {:midi, <<0xB0, 74, 30>>}

    # on another firmware it isn't there: K1 drives KNOB1 again (30 → 40: 5 clicks); back on OberVave it is
    :ok = Instance.switch_firmware("a", "shineon")
    play(@mk2, [0xB0, 20, 40])
    assert Enum.sum(for {:encoder, :knob1, n} <- inputs(), do: n) == 5
    assert {"K1", "CC 20", :automap, "KNOB1"} in rows("MPK Mini Mk II")
    :ok = Instance.switch_firmware("a", fw)
    play(@mk2, [0xB0, 20, 31])
    assert hd(inputs()) == {:midi, <<0xB0, 74, 31>>}

    # unpinned: the panel knob again; placing a pinned knob on a panel target unpins it
    :ok = MIDI.pin("a", "MPK Mini Mk II", {1, 20}, nil)
    assert {"K1", "CC 20", :automap, "KNOB1"} in rows("MPK Mini Mk II")
    :ok = MIDI.pin("a", "MPK Mini Mk II", {1, 21}, "FILTER · RESO")
    :ok = MIDI.place("a", "MPK Mini Mk II", {1, 21}, 1)
    assert {"K2", "CC 21", :automap, "KNOB1"} in rows("MPK Mini Mk II")
  end

  test "unmapped knobs: to the firmware's own MIDI map (said in the table), or nowhere when switched off" do
    :ok = MIDI.set_automap("a", "MPK Mini Mk II", false)
    play(@mk2, [0xB0, 20, 9, 0xB0, 64, 127])
    assert {:midi, <<0xB0, 20, 9>>} in inputs()
    assert {"K1", "CC 20", :synth, "OberVave: OSC 1 · WAVE"} in rows("MPK Mini Mk II")

    :ok = MIDI.set_unmapped("a", "MPK Mini Mk II", :drop)
    play(@mk2, [0xB0, 20, 10, 0xB0, 64, 0, 0xB0, 1, 30])
    refute {:midi, <<0xB0, 20, 10>>} in inputs()
    # the sustain pedal and the joystick (mod wheel) still go
    assert {:midi, <<0xB0, 64, 0>>} in inputs() and {:midi, <<0xB0, 1, 30>>} in inputs()
    assert {"K1", "CC 20", :dropped, _} = List.keyfind(rows("MPK Mini Mk II"), "K1", 0)
  end

  test "the I/O screen hears which hardware control moved, at most every 150 ms for the same one" do
    :ok = MIDI.watch("a")
    play(@mk2, [0xB0, 20, 1, 0xB0, 20, 2, 0xB0, 20, 3, 0xB0, 21, 1])
    assert_receive {:midi, "a", {:touched, "MPK Mini Mk II", {:cc, 1, 20}}}
    assert_receive {:midi, "a", {:touched, "MPK Mini Mk II", {:cc, 1, 21}}}
    refute_receive {:midi, "a", {:touched, _, {:cc, 1, 20}}}, 50
  end
end
