defmodule FMutate.MIDI.ControlsTest do
  use ExUnit.Case, async: true

  alias FMutate.{LayoutEdit, Layouts}
  alias FMutate.MIDI.{Automap, Controls}

  # the classic panel: master (pot), select / knob1 (encoders), arp (button), sustain (CC 72 toggle), bend
  @panel "test/fixtures/panel.layout.json" |> File.read!() |> JSON.decode!()

  defp learn(layout, id, m), do: elem(LayoutEdit.set_midi_in(layout, id, nil, m), 1)

  defp controls(learned) do
    layout = Enum.reduce(learned, @panel, fn {id, m}, l -> learn(l, id, m) end)
    assert Layouts.validate(layout) == :ok
    Controls.new() |> Controls.load(layout) |> Controls.seed_master(0.5)
  end

  defp cc(n, v, ch \\ 1), do: {:cc, ch, n, v}

  # feed events from a source, collecting inputs and surface
  defp run(c, events, source \\ "MPK mini 3") do
    Enum.reduce(events, {[], [], c}, fn ev, {ins, sur, c} ->
      {i, s, c} = Controls.handle(c, source, ev)
      {ins ++ i, sur ++ s, c}
    end)
  end

  defp auto(c, events, source \\ "MPK mini 3") do
    c = Controls.put_auto(c, source, Automap.assignments(source, Automap.empty()))

    Enum.reduce(events, {[], [], c}, fn ev, {ins, sur, c} ->
      {i, s, c} = Controls.handle_auto(c, source, ev)
      {ins ++ i, sur ++ s, c}
    end)
  end

  defp clicks(inputs, enc), do: inputs |> Enum.map(fn {:encoder, ^enc, n} -> n end) |> Enum.sum()

  test "an absolute knob turns an endless encoder: a whole sweep is 200 pt of drag, 33 clicks" do
    c = controls([{"knob1", %{"on" => "value", "type" => "cc", "channel" => 1, "number" => 74}}])
    {ins, sur, _} = run(c, for(v <- 0..127, do: cc(74, v)))
    assert clicks(ins, :knob1) == 33
    assert {:clicks, "knob1", 1} in sur
    {back, _, _} = run(c, for(v <- 127..0//-1, do: cc(74, v)))
    assert clicks(back, :knob1) == -33
  end

  test "relative codings: each step a click" do
    c = controls([{"select", %{"on" => "value", "type" => "cc", "channel" => 1, "number" => 10, "mode" => "relative_twos"}}])
    {ins, sur, _} = run(c, [cc(10, 3), cc(10, 127), cc(10, 0)])
    assert ins == [{:encoder, :select, 3}, {:encoder, :select, -1}]
    assert sur == [{:clicks, "select", 3}, {:clicks, "select", -1}]
  end

  test "MASTER: the hardware picks up the value, and the on-screen knob picks up from the hardware (rule 7)" do
    c = controls([{"master", %{"on" => "value", "type" => "cc", "channel" => 1, "number" => 7}}])
    # the instance has MASTER at 0.5: a knob at the bottom doesn't jump it
    {[], [], c} = run(c, [cc(7, 10)])
    {ins, sur, c} = run(c, [cc(7, 40), cc(7, 64)])
    assert [{:pot, :master, v}] = ins
    assert_in_delta v, 64 / 127, 0.001
    assert [{:value, "master", "pot:master", _}] = sur

    # the finger takes it from there (relative, from the current value) up to 0.8
    c = Enum.reduce(Enum.map(51..80, &(&1 / 100)), c, fn v, c -> elem(Controls.touch(c, %{"t" => "pot", "v" => v, "c" => "master"}), 1) end)
    assert {{:pot, :master, 0.8}, c} = Controls.touch(c, %{"t" => "pot", "v" => 0.8, "c" => "master"})

    # the hardware is stale until it passes 0.8
    {[], [], c} = run(c, [cc(7, 70), cc(7, 90)])
    {ins, _, _} = run(c, [cc(7, 105)])
    assert [{:pot, :master, v}] = ins
    assert_in_delta v, 105 / 127, 0.001
  end

  test "a pad presses a button momentarily; the keys' note of the same number isn't it" do
    c = controls([{"arp", %{"on" => "press", "type" => "note", "channel" => 10, "number" => 36, "device" => "MPK mini 3"}}])
    assert Controls.keys(c, "MPK mini 3") == MapSet.new([{:note, 10, 36}])
    assert Controls.keys(c, "Other") == MapSet.new()
    {ins, sur, c} = run(c, [{:note, 10, 36, 90}, {:note, 10, 36, 90}, {:note, 10, 36, 0}])
    assert ins == [{:button, :arp, :down}, {:button, :arp, :up}]
    assert sur == [{:press, "arp", true}, {:press, "arp", false}]
    assert run(c, [{:note, 1, 36, 90}]) |> elem(0) == []
  end

  test "a CC button presses from 64; a toggle flips on each press, sharing the surface's toggle" do
    sustain = %{"to" => %{"midi" => %{"type" => "cc", "number" => 72, "on" => 108, "off" => 60}}, "mode" => "toggle"}
    {:ok, l} = LayoutEdit.set_bindings(@panel, "seq", nil, [sustain])
    l = learn(l, "seq", %{"on" => "press", "type" => "cc", "channel" => 1, "number" => 64})
    c = Controls.load(Controls.new(), l)
    {ins, sur, c} = run(c, [cc(64, 127), cc(64, 127), cc(64, 0)])
    assert ins == [{:midi, <<0xB0, 72, 108>>}]
    assert sur == [{:press, "seq", true}, {:toggle, "seq", true}, {:press, "seq", false}]
    {ins, _, c} = run(c, [cc(64, 100), cc(64, 3)])
    assert ins == [{:midi, <<0xB0, 72, 60>>}]
    # the surface turned it on by touch: the next press turns it off
    c = Controls.toggled(c, "seq", true)
    assert run(c, [cc(64, 127)]) |> elem(0) == [{:midi, <<0xB0, 72, 60>>}]
  end

  test "a program change is a tap; a page action is the surface's alone" do
    {:ok, l, page} = LayoutEdit.add_page(@panel)
    {:ok, l, id} = LayoutEdit.add(l, page, "button", 0, 1)
    {:ok, l} = LayoutEdit.set_bindings(l, id, nil, [%{"to" => %{"page" => "next"}}])
    l = learn(l, id, %{"on" => "press", "type" => "program", "channel" => 1, "number" => 4})
    l = learn(l, "arp", %{"on" => "press", "type" => "program", "channel" => 1, "number" => 5})
    c = Controls.load(Controls.new(), l)
    assert {[], [{:press, ^id, true}, {:press, ^id, false}], _} = run(c, [{:program, 1, 4}])
    assert {[{:button, :arp, :down}, {:button, :arp, :up}], _, _} = run(c, [{:program, 1, 5}])
  end

  test "a device's own input wins over an any-device one; a source that goes lets go" do
    {:ok, l} = LayoutEdit.set_midi_in(@panel, "arp", nil, %{"on" => "press", "type" => "note", "channel" => 10, "number" => 36, "device" => "A"})
    l = Map.update!(l, "pages", fn [p | rest] -> [put_in(p["controls"], Enum.map(p["controls"], fn
      %{"id" => "seq"} = s -> Map.put(s, "midi_in", [%{"on" => "press", "type" => "note", "channel" => 10, "number" => 36}])
      other -> other
    end)) | rest] end)

    c = Controls.load(Controls.new(), l)
    assert {[{:button, :arp, :down}], _, c} = run(c, [{:note, 10, 36, 90}], "A")
    assert {[{:button, :seq, :down}], _, c} = run(c, [{:note, 10, 36, 90}], "B")
    assert {[{:button, :arp, :up}], [{:press, "arp", false}], _} = Controls.release_source(c, "A")
  end

  test "automap: MPK mini mk3 knobs and pads drive the panel; the on-screen controls show it" do
    c = controls([])
    {ins, sur, c} = auto(c, [cc(70, 0), cc(70, 127), {:note, 10, 44, 100}, {:note, 10, 44, 0}, {:note, 10, 49, 80}])
    assert clicks(Enum.filter(ins, &match?({:encoder, _, _}, &1)), :knob1) == 33
    assert {:button, :arp, :down} in ins and {:button, :arp, :up} in ins
    assert {:button, :oct_up, :down} in ins
    assert {:clicks, "knob1", 33} in sur
    assert {:shine, "arp", true} in sur and {:shine, "arp", false} in sur
    assert {:octave, 1} in sur
    # pad 15 isn't automapped: it keeps playing
    assert Controls.auto_keys(c, "MPK mini 3") |> MapSet.member?({:note, 10, 50}) == false
  end

  test "automap: knob 8 is MASTER, with pickup against the on-screen MASTER" do
    c = controls([])
    {[], [], c} = auto(c, [cc(77, 0)])
    {ins, sur, c} = auto(c, [cc(77, 63)])
    assert [{:pot, :master, _}] = ins
    # the on-screen MASTER is stale (another participant owns it) and shows the value
    assert [{:value, "midi", "pot:master", _}] = sur
    {nil, _} = Controls.touch(c, %{"t" => "pot", "v" => 0.9, "c" => "master"})
    assert {{:pot, :master, 0.5}, _} = Controls.touch(c, %{"t" => "pot", "v" => 0.5, "c" => "master"})
  end

  test "automap: a knob that repeats as an endless encoder is taken as one" do
    c = controls([])
    {ins, _, _} = auto(c, [cc(71, 1), cc(71, 1), cc(71, 1), cc(71, 1), cc(71, 1), cc(71, 127)])
    assert Enum.take(ins, -2) == [{:encoder, :knob2, 1}, {:encoder, :knob2, -1}]
  end

  test "what the surface is told, as text" do
    text =
      Controls.surface_text([{:press, "pads#3", true}, {:value, "master", "pot:master", 0.5}, {:clicks, "knob1", -2}, {:octave, -1}])

    assert IO.iodata_to_binary(text) == "p\tpads#3\t1\nv\tmaster\tpot:master\t0.5000\ne\tknob1\t-2\no\t-1"
  end
end
