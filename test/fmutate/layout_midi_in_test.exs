defmodule FMutate.LayoutMidiInTest do
  use ExUnit.Case, async: true

  alias FMutate.{LayoutEdit, Layouts}

  @panel "test/fixtures/panel.layout.json" |> File.read!() |> JSON.decode!()
  @cc74 %{"on" => "value", "type" => "cc", "channel" => 1, "number" => 74, "device" => "KeyStep"}
  @pad %{"on" => "press", "type" => "note", "channel" => 10, "number" => 36}

  test "learned inputs are part of the layout, schema-valid, and survive encode / decode" do
    {:ok, l} = LayoutEdit.set_midi_in(@panel, "knob1", nil, @cc74)
    assert Layouts.validate(l) == :ok
    {:ok, back} = l |> Layouts.encode() |> Layouts.decode()
    assert LayoutEdit.midi_in(back, "knob1") == [@cc74]
  end

  test "the schema refuses a bad input" do
    bad = fn m -> @panel |> LayoutEdit.put("knob1", %{"midi_in" => [m]}) |> elem(1) |> Layouts.validate() end
    assert {:error, _} = bad.(%{@cc74 | "channel" => 17})
    assert {:error, _} = bad.(Map.put(@cc74, "mode", "spin"))
    assert {:error, _} = bad.(Map.delete(@cc74, "type"))
  end

  test "one hardware control drives one layout control: learning takes it from the other" do
    {:ok, l} = LayoutEdit.set_midi_in(@panel, "knob1", nil, @cc74)
    assert [{%{"id" => "knob1"}, nil, _}] = LayoutEdit.midi_holders(l, "knob2", nil, @cc74)
    {:ok, l} = LayoutEdit.set_midi_in(l, "knob2", nil, @cc74)
    assert LayoutEdit.midi_in(l, "knob1") == []
    assert LayoutEdit.midi_in(l, "knob2") == [@cc74]
    # an any-device input takes every device's
    {:ok, l} = LayoutEdit.set_midi_in(l, "knob3", nil, Map.delete(@cc74, "device"))
    assert LayoutEdit.midi_in(l, "knob2") == []
    assert Layouts.validate(l) == :ok
  end

  test "one input per gesture; a control learns only its own gestures" do
    {:ok, l} = LayoutEdit.set_midi_in(@panel, "knob1", nil, @cc74)
    {:ok, l} = LayoutEdit.set_midi_in(l, "knob1", nil, %{@cc74 | "number" => 75})
    assert [%{"number" => 75}] = LayoutEdit.midi_in(l, "knob1")
    assert {:error, _} = LayoutEdit.set_midi_in(@panel, "knob1", nil, @pad)
    assert {:error, _} = LayoutEdit.set_midi_in(@panel, "screen", nil, @pad)
  end

  test "pads of a pad grid learn, each its own" do
    {:ok, l, page} = LayoutEdit.add_page(@panel)
    {:ok, l, id} = LayoutEdit.add(l, page, "pad_grid", 0, 1)
    {:ok, l} = LayoutEdit.put(l, id, %{"pad_grid" => %{"cols" => 2, "rows" => 2, "pads" => [%{}, %{}, %{}, %{}]}})
    {:ok, l} = LayoutEdit.set_midi_in(l, id, 2, @pad)
    assert LayoutEdit.midi_in(l, id, 2) == [@pad]
    assert LayoutEdit.midi_in(l, id, 1) == []
    assert {:error, _} = LayoutEdit.set_midi_in(l, id, nil, @pad)
    assert Layouts.validate(l) == :ok
  end

  test "the editing rules refuse two controls on one hardware control, or a wrong gesture" do
    both = fn l -> Map.update!(l, "pages", fn [p | r] -> [Map.update!(p, "controls", &Enum.map(&1, fn
      %{"id" => id} = c when id in ["knob1", "knob2"] -> Map.put(c, "midi_in", [@cc74])
      c -> c
    end)) | r] end) end

    assert {:error, [msg]} = Layouts.validate(both.(@panel))
    assert msg =~ "drives both knob1 and knob2"

    {:ok, wrong} = LayoutEdit.put(@panel, "arp", %{"midi_in" => [@cc74]})
    assert {:error, [_]} = Layouts.validate(wrong)
  end

  test "clear one gesture, or everything from a device" do
    {:ok, l} = LayoutEdit.set_midi_in(@panel, "knob1", nil, @cc74)
    {:ok, l} = LayoutEdit.set_midi_in(l, "arp", nil, @pad)
    {:ok, cleared} = LayoutEdit.clear_midi_in(l, "knob1", nil, "value")
    assert LayoutEdit.midi_ins(cleared) |> length() == 1
    {:ok, cleared} = LayoutEdit.clear_midi_device(l, "KeyStep")
    assert [{%{"id" => "arp"}, nil, @pad}] = LayoutEdit.midi_ins(cleared)
    refute Map.has_key?(elem(LayoutEdit.find(cleared, "knob1"), 1), "midi_in")
  end

  test "a page from a preset keeps only inputs no control has yet" do
    {:ok, preset} = LayoutEdit.set_midi_in(@panel, "knob1", nil, @cc74)
    {:ok, l, _page, _dropped} = LayoutEdit.add_page_from_preset(preset, preset)
    assert length(LayoutEdit.midi_ins(l)) == 1
    assert Layouts.validate(l) == :ok
  end
end
