defmodule FMutate.MIDIOutTest do
  # MIDI out from the surface (FMutate.MIDI with a real instance, native/build_host.sh): a binding's destination
  # (synth, out, both) decides whether the engine gets its messages and the outputs do; rule 7 keeps the two
  # apart; what is held out is let go of; the outputs switched on are kept by name and opened when they come.
  # The mob_midi boundary for outputs is faked (`midi_out:`): every open, close and send comes to the test.
  use ExUnit.Case, async: false

  alias FMutate.{Instance, InstrumentView, MIDI}

  @moduletag :engine
  @port 100
  @box 8

  setup do
    unless File.exists?(FMutate.Paths.engine_bin()),
      do: raise("run native/build_host.sh first: no #{FMutate.Paths.engine_bin()}")

    dir = Path.join(System.tmp_dir!(), "fmutate_test_#{System.unique_integer([:positive])}")
    Application.put_env(:fmutate_app, :data_dir, dir)
    start_supervised!({Registry, keys: :unique, name: FMutate.Registry})
    start_supervised!(FMutate.Audio)
    start_supervised!({Instance, id: "a"}, id: {:instance, "a"})
    start_midi([box()])

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :fail})
      Application.delete_env(:fmutate_app, :data_dir)
      File.rm_rf(dir)
    end)

    :ok
  end

  # a USB MIDI device FMutate can write to (FMutate.IO's view of it)
  defp box(id \\ @box), do: %{id: id, name: "Box", type: :usb, inputs: 1, outputs: 1, open: false}

  defp start_midi(devices) do
    me = self()

    out = fn op ->
      send(me, {:midi_out, op})

      case {op, :persistent_term.get({__MODULE__, :fail}, nil)} do
        {{:send, _, _, _}, reason} when reason != nil -> {:error, reason}
        _ -> nil
      end
    end

    start_supervised!({MIDI, id: "a", surface: fn _ -> :ok end, midi_out: out}, id: {:midi, "a"})
    midi = GenServer.whereis(MIDI.via("a"))
    # the instance's virtual port opened (Android: FMutate A), and the devices FMutate.IO lists
    send(midi, {:midi, :opened, %{direction: :virtual, device: @port, name: "FMutate A"}})
    io(devices)
  end

  defp io(devices) do
    send(GenServer.whereis(MIDI.via("a")), {:io, %{midi: devices}})
    settle()
  end

  # the MIDI process has handled everything before, and its casts to the instance are in
  defp settle do
    _ = MIDI.settings("a")
    _ = Instance.held("a")
  end

  defp socket, do: Mob.Socket.new(InstrumentView) |> Mob.Socket.assign(instance: "a", owner: self())

  # an input from the surface, as the native view sends it
  defp surface(payload) do
    {:noreply, _} = InstrumentView.handle_event("in", payload, socket())
    settle()
  end

  defp cc(n, v, extra), do: Map.merge(%{"t" => "midi", "bytes" => [0xB0, n, round(v * 127)]}, extra)

  # an XY pad's axis or a knob on a MIDI CC (rule 7 through FMutate.MIDI)
  defp abs(n, v, control, to \\ nil) do
    key = if to == "out", do: "out:cc:1:#{n}", else: "cc:1:#{n}"
    extra = %{"abs" => key, "v" => v, "c" => control}
    cc(n, v, if(to, do: Map.put(extra, "to", to), else: extra))
  end

  defp engine_midi, do: for({_, :in, {:midi, bytes}, _} <- Instance.journal("a", 200), do: bytes)

  defp sent(device) do
    receive do
      {:midi_out, {:send, ^device, bytes, _at}} -> [bytes | sent(device)]
    after
      0 -> []
    end
  end

  defp flush_out do
    receive do
      {:midi_out, _} -> flush_out()
    after
      0 -> :ok
    end
  end

  test "Out reaches the outputs and not the engine, Both reaches both, Synth is as it was" do
    :ok = MIDI.set_output("a", "Box", true)
    assert_receive {:midi_out, {:open, @box}}
    send(GenServer.whereis(MIDI.via("a")), {:midi, :opened, %{device: @box, port: 0, direction: :output}})

    # an XY pad: X on CC 74 out, Y on CC 71 both; a knob on CC 10 to the synth
    surface(abs(74, 0.5, "xy", "out"))
    surface(abs(71, 0.25, "xy", "both"))
    surface(abs(10, 1.0, "knob"))

    assert sent(@port) == [<<0xB0, 74, 64>>, <<0xB0, 71, 32>>]
    assert sent(@box) == [<<0xB0, 74, 64>>, <<0xB0, 71, 32>>]
    assert <<0xB0, 71, 32>> in engine_midi() and <<0xB0, 10, 127>> in engine_midi()
    refute Enum.any?(engine_midi(), &match?(<<0xB0, 74, _>>, &1))

    # a button's note: out only, both, synth (straight from the surface, no rule 7)
    surface(%{"t" => "midi", "bytes" => [0x90, 60, 100], "to" => "out"})
    surface(%{"t" => "midi", "bytes" => [0x90, 62, 100], "to" => "both"})
    surface(%{"t" => "midi", "bytes" => [0x90, 64, 100]})
    assert sent(@port) == [<<0x90, 60, 100>>, <<0x90, 62, 100>>]
    assert <<0x90, 62, 100>> in engine_midi() and <<0x90, 64, 100>> in engine_midi()
    refute <<0x90, 60, 100>> in engine_midi()

    # what each output was sent
    [port, box] = MIDI.outputs("a")
    assert %{name: "FMutate A", on: true, status: :open, sent: 4, last: <<0x90, 62, 100>>} = port
    assert %{name: "Box", on: true, status: :open, sent: 4} = box
  end

  test "rule 7: a synth knob and an Out XY axis on the same CC number are two values, neither picks up from the other" do
    surface(abs(74, 0.1, "knob"))
    # far from the synth's 0.1: still sent at once (the DAW's CC 74 is its own value)
    surface(abs(74, 0.9, "xy", "out"))
    # and the knob still owns the synth's CC 74: no pickup
    surface(abs(74, 0.2, "knob"))
    assert [<<0xB0, 74, 13>>, <<0xB0, 74, 25>>] = Enum.filter(engine_midi(), &match?(<<0xB0, 74, _>>, &1)) |> Enum.reverse()
    assert sent(@port) == [<<0xB0, 74, 114>>]

    # two controls on the Out CC pick up from each other as on the synth
    surface(abs(74, 0.3, "xy2", "out"))
    surface(abs(74, 0.88, "xy2", "out"))
    assert sent(@port) == [<<0xB0, 74, 112>>]
  end

  test "stuck notes: release-all, a page change and the app stopping let go of what is held out" do
    surface(%{"t" => "midi", "bytes" => [0x91, 60, 100], "to" => "out"})
    surface(%{"t" => "midi", "bytes" => [0x91, 64, 100], "to" => "both"})
    surface(%{"t" => "midi", "bytes" => [0x81, 64, 0], "to" => "both"})
    flush_out()

    Instance.release_all("a")
    assert sent(@port) == [<<0x81, 60, 0>>, <<0xB1, 123, 0>>]
    # nothing went out since: nothing to let go of
    Instance.release_all("a")
    assert sent(@port) == []

    surface(%{"t" => "midi", "bytes" => [0x90, 48, 100], "to" => "out"})
    flush_out()
    {:noreply, _} = InstrumentView.handle_event("page", %{"id" => "p2"}, socket())
    assert_received {:instrument, "page", %{"id" => "p2"}}
    assert sent(@port) == [<<0x80, 48, 0>>, <<0xB0, 123, 0>>]

    surface(%{"t" => "midi", "bytes" => [0x90, 50, 100], "to" => "out"})
    flush_out()
    stop_supervised!({:midi, "a"})
    assert sent(@port) == [<<0x80, 50, 0>>, <<0xB0, 123, 0>>]
  end

  test "a page change lets go of the Out notes it takes off screen; the dock's stay held" do
    # a dock button plays note 60 out (channel 1); a page's buttons note 62 out on channel 1 and 64 on channel 2
    note = fn n, ch -> %{"to" => %{"midi" => %{"type" => "note", "channel" => ch, "number" => n, "to" => "out"}}} end
    dock = %{"id" => "d", "type" => "button", "bindings" => [note.(60, 1)]}
    layout = Map.put(FMutate.Layouts.classic(), "dock", [dock])
    MIDI.layout_saved("a", Instance.view("a").firmware, layout)

    surface(%{"t" => "midi", "bytes" => [0x90, 60, 100], "to" => "out"})
    surface(%{"t" => "midi", "bytes" => [0x90, 62, 100], "to" => "out"})
    surface(%{"t" => "midi", "bytes" => [0x91, 64, 100], "to" => "out"})
    flush_out()

    {:noreply, _} = InstrumentView.handle_event("page", %{"id" => "p2"}, socket())
    # no CC 123 on channel 1: the dock's note still sounds there
    assert sent(@port) == [<<0x80, 62, 0>>, <<0x81, 64, 0>>, <<0xB1, 123, 0>>]

    # the dock's note goes on release-all
    Instance.release_all("a")
    assert sent(@port) == [<<0x80, 60, 0>>, <<0xB0, 123, 0>>]
  end

  test "a sustain sent out is let go of before the notes it holds: on release-all, and on a page change but the dock's channel" do
    note = fn n, ch -> %{"to" => %{"midi" => %{"type" => "note", "channel" => ch, "number" => n, "to" => "out"}}} end
    layout = Map.put(FMutate.Layouts.classic(), "dock", [%{"id" => "d", "type" => "button", "bindings" => [note.(60, 1)]}])
    MIDI.layout_saved("a", Instance.view("a").firmware, layout)

    # a sustain toggle out on channels 1 and 2, the dock's note on 1, a page's note on 2
    for bytes <- [[0xB0, 64, 127], [0xB1, 64, 127], [0x90, 60, 100], [0x91, 62, 100]],
        do: surface(%{"t" => "midi", "bytes" => bytes, "to" => "out"})

    flush_out()

    {:noreply, _} = InstrumentView.handle_event("page", %{"id" => "p2"}, socket())
    assert sent(@port) == [<<0x81, 62, 0>>, <<0xB1, 64, 0>>, <<0xB1, 123, 0>>]

    Instance.release_all("a")
    assert sent(@port) == [<<0x80, 60, 0>>, <<0xB0, 64, 0>>, <<0xB0, 123, 0>>]

    # a sustain switched off already isn't sent again
    surface(%{"t" => "midi", "bytes" => [0xB2, 64, 127], "to" => "out"})
    surface(%{"t" => "midi", "bytes" => [0xB2, 64, 0], "to" => "out"})
    flush_out()
    Instance.release_all("a")
    assert sent(@port) == []
  end

  test "outputs: kept by name, opened when the device is plugged in again, switched off; errors on the row" do
    :ok = MIDI.set_output("a", "Box", true)
    assert_receive {:midi_out, {:open, @box}}

    # restarted (the app again): the device opens without asking
    stop_supervised!({:midi, "a"})
    start_midi([box()])
    assert_receive {:midi_out, {:open, @box}}

    # unplugged, then plugged in again under another id
    io([])
    assert [_port] = MIDI.outputs("a")
    io([box(12)])
    assert_receive {:midi_out, {:open, 12}}

    # it didn't open: said on its row, and nothing is sent to it
    send(GenServer.whereis(MIDI.via("a")), {:midi, :error, %{op: :open_output, device: 12, reason: :open_failed, dropped: 0}})
    assert [_, %{name: "Box", on: true, status: {:error, :open_failed}}] = MIDI.outputs("a")
    surface(abs(74, 0.5, "xy", "out"))
    assert sent(12) == []

    # off: forgotten (another restart doesn't open it), and its port closed (it doesn't play the instance)
    io([])
    io([box(13)])
    assert_receive {:midi_out, {:open, 13}}
    send(GenServer.whereis(MIDI.via("a")), {:midi, :opened, %{device: 13, port: 0, direction: :output}})
    :ok = MIDI.set_output("a", "Box", false)
    assert_receive {:midi_out, {:close, 13}}
    assert [_, %{name: "Box", on: false, status: :off}] = MIDI.outputs("a")
    stop_supervised!({:midi, "a"})
    flush_out()
    start_midi([box(13)])
    refute_received {:midi_out, {:open, _}}

    # a send that fails is said on the row too, not a crash
    :persistent_term.put({__MODULE__, :fail}, :no_listener)
    surface(abs(74, 0.6, "xy", "out"))
    assert [%{name: "FMutate A", error: :no_listener}, _] = MIDI.outputs("a")
  end
end
