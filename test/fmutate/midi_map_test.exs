defmodule FMutate.MIDI.MapTest do
  use ExUnit.Case, async: true

  alias FMutate.MIDI.Map, as: M

  defp feed(map, bytes), do: M.feed(map, IO.iodata_to_binary(bytes))
  defp inputs(map, bytes), do: map |> feed(bytes) |> elem(0)

  describe "notes" do
    test "F3..G5 press the firmware's keys, without velocity" do
      {down, map} = feed(M.new(), [0x90, 53, 100, 0x90, 79, 1])
      assert down == [{:key, 0, :down}, {:key, 26, :down}]
      assert inputs(map, [0x80, 53, 0, 0x90, 79, 0]) == [{:key, 0, :up}, {:key, 26, :up}]
    end

    test "notes outside the keyboard go to the firmware's MIDI in, velocity kept, and come off there" do
      {[on], map} = feed(M.new(), [0x91, 52, 90])
      assert on == {:midi, <<0x91, 52, 90>>}
      assert inputs(map, [0x81, 52, 64]) == [{:midi, <<0x81, 52, 0>>}]
      assert inputs(M.new(), [0x90, 80, 10]) == [{:midi, <<0x90, 80, 10>>}]
    end

    test "notes: :firmware sends every note as MIDI" do
      assert inputs(M.new(notes: :firmware), [0x90, 60, 77]) == [{:midi, <<0x90, 60, 77>>}]
    end

    test "a note off goes where its note on went, even after a settings change" do
      {_, map} = feed(M.new(), [0x90, 60, 100])
      map = M.configure(map, notes: :firmware)
      assert inputs(map, [0x80, 60, 0]) == [{:key, 7, :up}]
    end

    test "a repeated note on lets go first" do
      {_, map} = feed(M.new(), [0x90, 60, 100])
      assert inputs(map, [0x90, 60, 100]) == [{:key, 7, :up}, {:key, 7, :down}]
    end

    test "running status, and messages split across packets" do
      {first, map} = feed(M.new(), [0x90, 60])
      assert first == []
      {rest, _} = feed(map, [100, 62, 100, 64, 0])
      assert rest == [{:key, 7, :down}, {:key, 9, :down}, {:key, 11, :up}]
    end

    test "real-time bytes inside a message don't break it" do
      assert inputs(M.new(clock: :off), [0x90, 0xF8, 60, 0xF8, 100]) == [{:key, 7, :down}]
    end

    test "sysex is skipped and ends running status" do
      assert inputs(M.new(), [0x90, 60, 100, 0xF0, 1, 2, 3, 0xF7, 62, 100]) == [{:key, 7, :down}]
    end

    test "release_all lets go of everything held" do
      {_, map} = feed(M.new(), [0x90, 60, 100, 0x90, 30, 100])
      {ups, map} = M.release_all(map)
      assert ups == [{:midi, <<0x80, 30, 0>>}, {:key, 7, :up}]
      assert map.held == %{}
    end

    test "all notes off (CC 123) releases held keys and passes on" do
      {_, map} = feed(M.new(), [0x90, 60, 100])
      assert inputs(map, [0xB0, 123, 0]) == [{:key, 7, :up}, {:midi, <<0xB0, 123, 0>>}]
    end
  end

  describe "channel filter" do
    test "only the chosen channel plays" do
      map = M.new(channel: 2)
      assert inputs(map, [0x90, 60, 100]) == []
      assert inputs(map, [0x91, 60, 100]) == [{:key, 7, :down}]
      assert inputs(map, [0xB0, 1, 64, 0xB1, 1, 65]) == [{:midi, <<0xB1, 1, 65>>}]
    end

    test ":all takes every channel" do
      assert inputs(M.new(), [0x9F, 60, 100]) == [{:key, 7, :down}]
    end

    test "clock isn't a channel message: the filter doesn't drop it" do
      assert inputs(M.new(channel: 5), [0xF8]) == [{:midi, <<0xF8>>}]
    end
  end

  describe "pitch bend" do
    test "goes to the firmware when it bends" do
      assert inputs(M.new(bend: true), [0xE0, 0, 0x50]) == [{:midi, <<0xE0, 0, 0x50>>}]
    end

    test "is dropped when the firmware ignores bend" do
      assert inputs(M.new(bend: false), [0xE0, 0, 0x50]) == []
    end
  end

  describe "clock modes" do
    @clock [0xFA, 0xF8, 0xF8, 0xFC, 0xFB, 0xF2, 0x10, 0x02]

    test "follow passes clock, start, stop, continue and song position" do
      assert inputs(M.new(clock: :follow), @clock) ==
               [{:midi, <<0xFA>>}, {:midi, <<0xF8>>}, {:midi, <<0xF8>>}, {:midi, <<0xFC>>}, {:midi, <<0xFB>>},
                {:midi, <<0xF2, 0x10, 0x02>>}]
    end

    test "send and off drop incoming clock" do
      assert inputs(M.new(clock: :send), @clock) == []
      assert inputs(M.new(clock: :off), @clock) == []
    end

    test "active sensing and reset are always dropped" do
      assert inputs(M.new(), [0xFE, 0xFF]) == []
    end
  end

  test "bad settings raise" do
    assert_raise ArgumentError, fn -> M.new(channel: 17) end
    assert_raise ArgumentError, fn -> M.new(clock: :maybe) end
  end
end
