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
      assert %{knobs: true, pads: false} = Automap.open("MPK mini 3", Automap.empty())
    end

    test "first touch: knobs in the order turned, pads (channel 10) in the order hit; not pedals, not keys" do
      o = Automap.empty()
      assert Automap.touch("Box", o, {:cc, 1, 64, 127}) == :same
      assert Automap.touch("Box", o, {:note, 1, 36, 90}) == :same
      {:new, o} = Automap.touch("Box", o, {:cc, 2, 20, 5})
      assert Automap.touch("Box", o, {:cc, 2, 20, 6}) == :same
      {:new, o} = Automap.touch("Box", o, {:cc, 2, 18, 5})
      {:new, o} = Automap.touch("Box", o, {:note, 10, 40, 90})
      assert o == %{knobs: [{2, 20}, {2, 18}], pads: [{10, 40}], seen: [{2, 20}, {2, 18}], by: :auto}

      assert [{{:cc, 2, 20}, 1, :knob, %{"encoder" => "knob1"}}, {{:cc, 2, 18}, 2, :knob, %{"encoder" => "knob2"}},
              {{:note, 10, 40}, 1, :pad, %{"button" => "fx"}}] = Automap.assignments("Box", o)
    end

    test "first touch stops at 8 knobs and 14 pads" do
      o = Automap.normalize(%{knobs: for(c <- 20..27, do: {1, c}), pads: for(n <- 36..49, do: {10, n})})
      assert %{knobs: false, pads: false} = Automap.open("Box", o)
      assert Automap.touch("Box", o, {:cc, 1, 30, 1}) == :same
    end

    # Kevin's MPK mini mk2 (test/fixtures/mpk-mini-mk2-knobs.txt, a CoreMIDI capture): K1..K8 turned in order
    defp kevin do
      for line <- File.stream!("test/fixtures/mpk-mini-mk2-knobs.txt"),
          [_, cc, v] <- [Regex.run(~r/ch1 cc (\d+) val (\d+)/, line)],
          do: {String.to_integer(cc), [String.to_integer(v)]}
    end

    defp turn(name, order, cc_values) do
      Enum.reduce(cc_values, order, fn {cc, values}, o ->
        Enum.reduce(values, o, fn v, o ->
          case Automap.touch(name, o, {:cc, 1, cc, v}) do
            {:new, o} -> o
            :same -> o
          end
        end)
      end)
    end

    defp knob_targets(name, order) do
      for {{:cc, 1, cc}, _, :knob, t} <- Automap.assignments(name, order),
          do: {Automap.hardware_name(name, order, {1, cc}) || "CC #{cc}", Automap.target_name(t)}
    end

    test "MPK mini mk2, Kevin's knobs (factory PROG 2): K1..K8 → KNOB1..4, SELECT, PRESETS, ALGO, MASTER" do
      name = "MPK Mini Mk II"
      o = turn(name, Automap.empty(), kevin())

      assert Automap.program(name, o).name == "PROG 2"
      assert o.by == :auto

      assert knob_targets(name, o) ==
               Enum.zip(~w(K1 K2 K3 K4 K5 K6 K7 K8), ~w(KNOB1 KNOB2 KNOB3 KNOB4 SELECT PRESETS ALGO MASTER))

      # only the knobs: the order is complete after K1 already (the program tells all eight)
      o1 = turn(name, Automap.empty(), Enum.take(kevin(), 1))
      assert knob_targets(name, o1) == knob_targets(name, o)
    end

    test "MPK mini mk2: its programs from the knobs seen; the joystick (CC 1) decides nothing" do
      name = "MPK Mini Mk II"
      # nothing seen: PROG 1, K1 = CC 1 (the joystick sends CC 1 too, and drives KNOB1 there)
      assert Automap.program(name, Automap.empty()).name == "PROG 1"
      assert Automap.touch(name, Automap.empty(), {:cc, 1, 1, 64}) == :same
      # K1, K5 of PROG 3/4 (CC 20, 24): PROG 3; the joystick still CC 1, not a knob there
      o = turn(name, Automap.empty(), [{20, [1]}, {24, [1]}])
      assert Automap.program(name, o).name == "PROG 3"
      assert MapSet.member?(Automap.open(name, o).pass, {1, 1})
      refute Automap.candidate?({:cc, 1, 1, 5}, Automap.open(name, o))
      # PROG 4's joystick (CC 30) tells it apart
      assert Automap.program(name, turn(name, o, [{30, [3]}])).name == "PROG 4"
      # off its programs (PROG 4 seen, then a stranger CC): no joystick CC of any program becomes a knob
      t = turn(name, o, [{30, [3]}, {40, [1]}, {31, [2]}])
      assert t.by == :touch and {1, 30} not in t.knobs and {1, 31} not in t.knobs
      assert MapSet.member?(Automap.open(name, t).pass, {1, 31})
    end

    test "a known controller off its factory programs: the first CC that fits none switches it to first touch" do
      name = "MPK Mini Mk II"
      # K1, K2 of PROG 2, then a CC no program has: first touch, in the order the knobs came
      o = turn(name, Automap.empty(), [{20, [1]}, {21, [1]}, {40, [1]}, {41, [1]}, {1, [9]}])
      assert o.by == :touch
      assert o.knobs == [{1, 20}, {1, 21}, {1, 40}, {1, 41}]
      assert knob_targets(name, o) == [{"CC 20", "KNOB1"}, {"CC 21", "KNOB2"}, {"CC 40", "KNOB3"}, {"CC 41", "KNOB4"}]
      # PROG 2's K5 (CC 16) is just the next knob now
      assert {:new, %{knobs: [_, _, _, _, {1, 16}]}} = Automap.touch(name, o, {:cc, 1, 16, 3})

      # the same for the mk3 (one program: CC 70–77)
      assert %{by: :touch, knobs: [{1, 20}]} = turn("MPK mini 3", Automap.empty(), [{20, [5]}])
      # Reset: the profile again
      assert Automap.program(name, Automap.empty()).name == "PROG 1"
    end

    test "a lined-up order holds: skipped targets drive nothing, no knob joins by first touch" do
      name = "MPK Mini Mk II"
      o = Automap.line_up(Automap.empty(), [{1, 16}, nil, {1, 20}, nil, nil, nil, nil, nil])
      assert o.knobs == [{1, 16}, nil, {1, 20}]
      refute Automap.open(name, o).knobs
      assert Automap.touch(name, o, {:cc, 1, 21, 9}) == :same
      assert knob_targets(name, o) == [{"K5", "KNOB1"}, {"K1", "KNOB3"}]

      # one knob placed on a slot: a swap with the knob that had it
      o2 = Automap.place(name, o, {1, 20}, 1)
      assert Enum.take(o2.knobs, 3) == [{1, 20}, nil, {1, 16}]
      # from a profile's program: its slots are the starting point
      p2 = turn(name, Automap.empty(), [{20, [1]}])
      assert Automap.place(name, p2, {1, 16}, 1).knobs |> Enum.take(5) == [{1, 16}, {1, 21}, {1, 22}, {1, 23}, {1, 20}]
    end

    test "orders saved before programs and line-ups load as first touch" do
      o = Automap.normalize(%{knobs: [{1, 20}], pads: [{10, 36}]})
      assert o == %{knobs: [{1, 20}], pads: [{10, 36}], seen: [], by: :auto}
      assert knob_targets("Box", o) == [{"CC 20", "KNOB1"}]
    end

    test "unmapped knobs: to the firmware by default; dropped when off, but not pedals or a joystick" do
      bytes = [0xB0, 20, 9, 0xB0, 64, 127, 0xB0, 1, 50, 0xB0, 7, 100]
      assert length(inputs(M.new(), bytes)) == 4
      map = M.new(unmapped: :drop, auto_open: %{knobs: false, pads: false, pass: MapSet.new([{1, 1}])})
      # a dropped CC is still told (the I/O table lists it), but plays nothing
      assert inputs(map, bytes) ==
               [{:dropped, {:cc, 1, 20, 9}}, {:midi, <<0xB0, 64, 127>>}, {:midi, <<0xB0, 1, 50>>}, {:dropped, {:cc, 1, 7, 100}}]
      # automapped and learned CCs aren't unmapped
      assert inputs(M.configure(map, auto: MapSet.new([{:cc, 1, 20}])), [0xB0, 20, 9]) == [{:auto, {:cc, 1, 20, 9}}]
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
