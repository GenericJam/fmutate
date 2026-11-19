defmodule FMutate.MIDI.LearnTest do
  use ExUnit.Case, async: true

  alias FMutate.MIDI.{Automap, Learn}
  alias FMutate.MIDI.Map, as: M

  defp inputs(map, bytes), do: map |> M.feed(IO.iodata_to_binary(bytes)) |> elem(0)

  describe "the parser with learned controls" do
    test "a learned message skips its default path; the same number on another channel doesn't" do
      # an MPK mini's pad (note 36, ch 10) learned; its keys play note 36 on ch 1
      map = M.new(learned: MapSet.new([{:note, 10, 36}]))
      assert inputs(map, [0x99, 36, 90, 0x89, 36, 0]) == [{:learned, {:note, 10, 36, 90}}, {:learned, {:note, 10, 36, 0}}]
      assert inputs(map, [0x90, 36, 90]) == [{:midi, <<0x90, 36, 90>>}]
      assert inputs(map, [0x90, 60, 90]) == [{:key, 7, :down}]
    end

    test "learned messages ignore the channel filter (it is for the default path)" do
      map = M.new(channel: 1, learned: MapSet.new([{:cc, 10, 20}]))
      assert inputs(map, [0xB9, 20, 5, 0xB9, 21, 5]) == [{:learned, {:cc, 10, 20, 5}}]
    end

    test "a note held by the default path before it was learned comes off there" do
      {_, map} = M.feed(M.new(), <<0x90, 60, 100>>)
      map = M.configure(map, learned: MapSet.new([{:note, 1, 60}]))
      assert inputs(map, [0x80, 60, 0]) == [{:key, 7, :up}]
      assert inputs(map, [0x90, 60, 1]) == [{:learned, {:note, 1, 60, 1}}]
    end

    test "while learning every channel message is offered and plays nothing; a note off still lets go" do
      {_, map} = M.feed(M.new(), <<0x90, 60, 100>>)
      map = M.configure(map, learning: true)

      assert inputs(map, [0xB0, 74, 3, 0xE1, 0, 64, 0xC2, 5, 0xD0, 9, 0xA0, 61, 7, 0x80, 60, 0]) == [
               {:learn, {:cc, 1, 74, 3}},
               {:learn, {:pitch_bend, 2, 8192}},
               {:learn, {:program, 3, 5}},
               {:learn, {:channel_pressure, 1, 9}},
               {:learn, {:poly_pressure, 1, 61, 7}},
               {:key, 7, :up}
             ]
    end
  end

  describe "learning" do
    test "a note learns at once, with its channel and the source" do
      assert {:done, m} = Learn.offer(Learn.new("press"), "MPK mini 3", {:note, 10, 36, 90})
      assert m == %{"on" => "press", "type" => "note", "channel" => 10, "number" => 36, "device" => "MPK mini 3"}
    end

    test "a press doesn't learn pitch bend; a value doesn't learn a program change" do
      assert Learn.offer(Learn.new("press"), "x", {:pitch_bend, 1, 9000}) == :ignore
      assert Learn.offer(Learn.new("value"), "x", {:program, 1, 3}) == :ignore
      assert Learn.offer(Learn.new("press"), "x", {:note, 1, 36, 0}) == :ignore
    end

    test "a CC listens for its window: a knob is absolute, an endless encoder its coding" do
      {:window, l} = Learn.offer(Learn.new("value"), "KeyStep", {:cc, 1, 74, 40})
      {:wait, l} = Learn.offer(l, "KeyStep", {:cc, 1, 74, 41})
      # another control during the window isn't taken
      assert Learn.offer(l, "KeyStep", {:cc, 1, 75, 3}) == :ignore
      assert Learn.finish(l) == %{"on" => "value", "type" => "cc", "channel" => 1, "number" => 74, "device" => "KeyStep"}

      enc =
        Enum.reduce([65, 65, 65], elem(Learn.offer(Learn.new("x"), "K", {:cc, 2, 10, 65}), 1), fn v, l ->
          elem(Learn.offer(l, "K", {:cc, 2, 10, v}), 1)
        end)

      assert Learn.finish(enc)["mode"] == "relative_offset"
    end

    test "codings from the values" do
      assert Learn.mode([10, 11, 12, 13]) == "absolute"
      assert Learn.mode([63, 63, 63]) == "relative_offset"
      assert Learn.mode([1, 1, 127, 127]) == "relative_twos"
      assert Learn.mode([1, 1, 65, 65]) == "relative_sign"
      assert Learn.mode([127, 127]) == "relative_twos"
      assert Learn.mode([0, 0, 0]) == "absolute"
    end

    test "steps" do
      assert {Learn.steps("relative_offset", 66), Learn.steps("relative_offset", 61)} == {2, -3}
      assert {Learn.steps("relative_twos", 3), Learn.steps("relative_twos", 126)} == {3, -2}
      assert {Learn.steps("relative_sign", 3), Learn.steps("relative_sign", 66)} == {3, -2}
    end

    test "what the player reads" do
      assert Learn.describe(%{"type" => "cc", "channel" => 1, "number" => 74, "device" => "Arturia KeyStep"}) ==
               "CC 74 ch 1 · Arturia KeyStep"

      assert Learn.describe(%{"type" => "note", "channel" => 10, "number" => 36}) == "note C2 (36) ch 10 · any device"
    end

    test "overlap: same message from the same device, or either is any device" do
      a = %{"type" => "cc", "channel" => 1, "number" => 74, "device" => "A"}
      assert Learn.overlap?(a, Map.delete(a, "device"))
      refute Learn.overlap?(a, %{a | "device" => "B"})
      refute Learn.overlap?(a, %{a | "channel" => 2})
    end
  end

  describe "automap" do
    test "known controllers by name, any case" do
      assert Automap.profile("MPK mini 3").name == "AKAI MPK mini mk3"
      assert Automap.profile("AKAI MPK Mini Mk II").name == "AKAI MPK mini mk2"
      assert Automap.profile("Arturia KeyStep") == nil
    end

    test "the MPK mini mk3: knobs CC 70-77 → KNOB1-4, SELECT, PRESETS, ALGO, MASTER; 14 pads, 15-16 play" do
      a = Automap.assignments("MPK mini 3", Automap.empty())
      knobs = for {{:cc, 1, cc}, _, :knob, t} <- a, do: {cc, Automap.target_name(t)}
      assert knobs == Enum.zip(70..77, ~w(KNOB1 KNOB2 KNOB3 KNOB4 SELECT PRESETS ALGO MASTER))
      pads = for {{:note, 10, n}, _, :pad, t} <- a, do: {n, Automap.target_name(t)}
      assert pads == Enum.zip(36..49, ~w(FX SEL ENV LFO EDIT GLO HOME SAVE ARP SEQ PLAY REC OCT− OCT+))
      assert Automap.open("MPK mini 3", Automap.empty()) == %{knobs: false, pads: false}
    end

    test "first touch: knobs in the order turned, pads (channel 10) in the order hit; not pedals, not keys" do
      o = Automap.empty()
      assert Automap.touch("Box", o, {:cc, 1, 64, 127}) == :same
      assert Automap.touch("Box", o, {:note, 1, 36, 90}) == :same
      {:new, o} = Automap.touch("Box", o, {:cc, 2, 20, 5})
      assert Automap.touch("Box", o, {:cc, 2, 20, 6}) == :same
      {:new, o} = Automap.touch("Box", o, {:cc, 2, 18, 5})
      {:new, o} = Automap.touch("Box", o, {:note, 10, 40, 90})
      assert o == %{knobs: [{2, 20}, {2, 18}], pads: [{10, 40}]}

      assert [{{:cc, 2, 20}, 1, :knob, %{"encoder" => "knob1"}}, {{:cc, 2, 18}, 2, :knob, %{"encoder" => "knob2"}},
              {{:note, 10, 40}, 1, :pad, %{"button" => "fx"}}] = Automap.assignments("Box", o)
    end

    test "first touch stops at 8 knobs and 14 pads" do
      o = %{knobs: for(c <- 20..27, do: {1, c}), pads: for(n <- 36..49, do: {10, n})}
      assert Automap.open("Box", o) == %{knobs: false, pads: false}
      assert Automap.touch("Box", o, {:cc, 1, 30, 1}) == :same
    end

    test "the parser hands automapped and first-touch messages over, inside the channel filter" do
      map = M.new(auto: MapSet.new([{:cc, 1, 70}]), auto_open: %{knobs: false, pads: true})
      # a new pad's note off in the same packet follows its note on
      assert inputs(map, [0xB0, 70, 9, 0xB0, 71, 9, 0x99, 37, 80, 0x89, 37, 0]) ==
               [{:auto, {:cc, 1, 70, 9}}, {:midi, <<0xB0, 71, 9>>}, {:auto, {:note, 10, 37, 80}}, {:auto, {:note, 10, 37, 0}}]

      filtered = M.configure(map, channel: 1)
      assert inputs(filtered, [0x99, 37, 80]) == []
      # a learned control wins over automap
      learned = M.configure(map, learned: MapSet.new([{:cc, 1, 70}]))
      assert inputs(learned, [0xB0, 70, 9]) == [{:learned, {:cc, 1, 70, 9}}]
    end
  end
end
