defmodule FMutate.MIDILearnFlowTest do
  # FMutate.MIDI with a real instance (native/build_host.sh): MIDI learn from the editor's sheet, learned and
  # automapped controls reaching the instance, persistence, and what the surface is told.
  use ExUnit.Case, async: false

  alias FMutate.{Editor, Instance, LayoutEdit, Layouts, MIDI}

  @moduletag :engine
  @mpk 7

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
    send(GenServer.whereis(MIDI.via("a")), {:io, %{midi: [%{id: @mpk, name: "MPK mini 3"}, %{id: 8, name: "Box"}]}})
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
    assert Enum.sum(clicks) == 16
    refute Enum.any?(inputs(200), &match?({:midi, <<0xB0, 74, _>>}, &1))
    assert_receive {:surface, "e\tknob1\t" <> _}

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
    assert Enum.sum(for {:encoder, :knob1, n} <- inputs(), do: n) == 33
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
    assert %{assigned: [{"CC 20 ch 3", "KNOB1"}, {"CC 18 ch 3", "KNOB2"}, {"note 40 ch 10", "FX"}]} =
             MIDI.settings("a").automap["Box"]

    stop_supervised!({:midi, "a"})
    start_midi(self())
    play(8, [0xB2, 18, 0, 0xB2, 18, 127])
    assert Enum.sum(for {:encoder, :knob2, n} <- inputs(), do: n) == 33

    :ok = MIDI.reset_automap("a", "Box")
    play(8, [0xB2, 18, 0, 0xB2, 18, 10])
    assert Enum.take(inputs(), 1) == [{:encoder, :knob1, 2}]
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
end
