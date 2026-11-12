defmodule FMutate.LayoutEditTest do
  use ExUnit.Case, async: true

  alias FMutate.{LayoutEdit, Layouts}

  defp classic, do: Layouts.classic()
  defp at(layout, id), do: layout |> LayoutEdit.find(id) |> elem(1) |> Map.get("at")
  defp valid!(layout), do: assert(Layouts.validate(layout) == :ok)

  describe "move" do
    test "to free cells keeps the size" do
      {:ok, l} = LayoutEdit.move(classic(), "fx", 12, 1)
      assert at(l, "fx") == LayoutEdit.cell(12, 1, 1, 1)
      valid!(l)
    end

    test "onto another control, or off the grid, is refused" do
      assert {:error, "Overlaps another control"} = LayoutEdit.move(classic(), "fx", 7, 1)
      assert {:error, "Off the grid"} = LayoutEdit.move(classic(), "knob1", 13, 0)
      assert {:error, "Off the grid"} = LayoutEdit.move(classic(), "fx", -1, 0)
    end

    test "page controls may not cover the dock; a dock control may not cover any page" do
      assert {:error, _} = LayoutEdit.move(classic(), "fx", 0, 0)
      {:ok, l, page} = LayoutEdit.add_page(classic())
      {:ok, l, _} = LayoutEdit.add(l, page, "button", 13, 5)
      # free on the classic page, taken on the new one
      assert {:error, _} = LayoutEdit.move(l, "menu", 13, 5)
      assert {:ok, l} = LayoutEdit.move(l, "menu", 12, 1)
      valid!(l)
    end

    test "the creature moves" do
      {:ok, l} = LayoutEdit.move(classic(), "menu", 13, 1)
      assert at(l, "menu") == LayoutEdit.cell(13, 1, 1, 1)
      valid!(l)
    end
  end

  describe "resize" do
    test "snaps to whole cells and can move the origin" do
      {:ok, l} = LayoutEdit.resize(classic(), "fx", LayoutEdit.cell(12, 1, 2, 2))
      assert at(l, "fx") == LayoutEdit.cell(12, 1, 2, 2)
    end

    test "never below the minimum size" do
      l = classic()
      assert {:error, "Keyboard strip needs at least 4×2"} = LayoutEdit.resize(l, "keys", LayoutEdit.cell(0, 3, 14, 1))
      {:ok, l, _} = LayoutEdit.add(l, hd(l["pages"])["id"], "slider", 12, 1)
      [slider] = for c <- hd(l["pages"])["controls"], c["type"] == "slider", do: c
      assert {:error, "Slider needs at least 1×2"} = LayoutEdit.resize(l, slider["id"], LayoutEdit.cell(12, 1, 1, 1))
    end

    test "a horizontal slider's minimum is 2×1" do
      assert LayoutEdit.min_size(%{"type" => "slider", "slider" => %{"orientation" => "horizontal"}}) == {2, 1}
      assert LayoutEdit.min_size(%{"type" => "keyboard", "keyboard" => %{"orientation" => "vertical"}}) == {2, 4}
    end

    test "overlap is refused; the creature never resizes" do
      assert {:error, "Overlaps another control"} = LayoutEdit.resize(classic(), "fx", LayoutEdit.cell(6, 1, 2, 1))
      assert {:error, "The creature stays 1×1"} = LayoutEdit.resize(classic(), "menu", LayoutEdit.cell(0, 0, 2, 1))
    end
  end

  describe "add" do
    test "Add here lists what fits the free run and disables the rest" do
      menu = LayoutEdit.add_menu(classic(), "panel", 12, 1)
      fits = Map.new(menu, &{&1.type, &1.fits})
      assert fits["button"] and fits["xy_pad"] and fits["screen"]
      refute fits["keyboard"]
      refute fits["strum"]
      assert Enum.find(menu, &(&1.type == "keyboard")).size == "4×2"
      assert LayoutEdit.room(classic(), "panel", 12, 1) == {2, 2}
      assert LayoutEdit.room(classic(), "panel", 7, 1) == {0, 0}
    end

    test "places the control over the tapped cell, at its default size when there is room" do
      {:ok, l, page} = LayoutEdit.add_page(classic())
      {:ok, l, id} = LayoutEdit.add(l, page, "xy_pad", 5, 2)
      assert at(l, id) == LayoutEdit.cell(5, 2, 2, 2)
      {:ok, l, id2} = LayoutEdit.add(l, page, "screen", 13, 5)
      # 3×3 by default, shifted up/left so it covers the tapped corner cell
      assert at(l, id2) == LayoutEdit.cell(11, 3, 3, 3)
      valid!(l)
    end

    test "falls back to the minimum size, and refuses when even that doesn't fit" do
      {:ok, l, id} = LayoutEdit.add(classic(), "panel", "screen", 12, 1)
      assert at(l, id) == LayoutEdit.cell(12, 1, 2, 2)
      assert {:error, "Keyboard strip needs 4×2 here"} = LayoutEdit.add(classic(), "panel", "keyboard", 12, 1)
    end

    test "ids stay unique" do
      {:ok, l, a} = LayoutEdit.add(classic(), "panel", "button", 12, 1)
      {:ok, l, b} = LayoutEdit.add(l, "panel", "button", 13, 1)
      assert a != b
      valid!(l)
    end
  end

  describe "delete" do
    test "removes a control; the creature is undeletable" do
      {:ok, l} = LayoutEdit.delete(classic(), "fx")
      assert LayoutEdit.find(l, "fx") == nil
      assert {:error, "The creature can't be deleted"} = LayoutEdit.delete(classic(), "menu")
    end
  end

  describe "pages" do
    test "dragging onto the edge moves a control to the next page, creating it" do
      {:ok, l, page} = LayoutEdit.to_page(classic(), "fx", 1)
      assert length(l["pages"]) == 2
      assert {{:page, ^page}, _} = LayoutEdit.find(l, "fx")
      assert at(l, "fx") == LayoutEdit.cell(6, 1, 1, 1)
      valid!(l)
      # and back, to the existing first page
      {:ok, l, "panel"} = LayoutEdit.to_page(l, "fx", -1)
      assert length(l["pages"]) == 2
    end

    test "it takes the first free spot when its cell is taken there, and dock controls stay" do
      {:ok, l, page} = LayoutEdit.add_page(classic())
      {:ok, l, _} = LayoutEdit.add(l, page, "button", 6, 1)
      {:ok, l, ^page} = LayoutEdit.to_page(l, "fx", 1)
      assert at(l, "fx") == LayoutEdit.cell(1, 0, 1, 1)
      assert {:error, _} = LayoutEdit.to_page(l, "menu", 1)
    end

    test "a page from a preset keeps clear of this layout's dock" do
      {:ok, l, page, dropped} = LayoutEdit.add_page_from_preset(classic(), Layouts.preset("drum-pads").data)
      assert LayoutEdit.page(l, page)["name"] == "Beat"
      valid!(l)
      # the 8×6 pads would cover the creature at (0,0): they give up a column and move right
      assert dropped == 0
      assert at(l, "pads") == LayoutEdit.cell(1, 0, 7, 6)
    end

    test "rename, reorder, delete (never the last page)" do
      {:ok, l, p2} = LayoutEdit.add_page(classic())
      {:ok, l} = LayoutEdit.rename_page(l, p2, "  A very long page name ")
      assert LayoutEdit.page(l, p2)["name"] == "A very long "
      {:ok, l} = LayoutEdit.move_page(l, p2, -1)
      assert hd(l["pages"])["id"] == p2
      {:ok, l} = LayoutEdit.delete_page(l, p2)
      assert {:error, _} = LayoutEdit.delete_page(l, "panel")
    end
  end

  describe "switcher look" do
    test "names adds a dock switcher where it is free on every page; dots restyles it; hidden removes it" do
      {:ok, l} = LayoutEdit.set_switcher(classic(), "names")
      [sw] = for c <- l["dock"], c["type"] == "page_switcher", do: c
      assert sw["at"] == LayoutEdit.cell(12, 1, 2, 1)
      valid!(l)
      {:ok, l} = LayoutEdit.set_switcher(l, "dots")
      assert [%{"page_switcher" => %{"look" => "dots"}}] = for(c <- l["dock"], c["type"] == "page_switcher", do: c)
      {:ok, l} = LayoutEdit.set_switcher(l, "hidden")
      assert Enum.all?(l["dock"], &(&1["type"] != "page_switcher"))
    end
  end

  describe "frame" do
    test "turning a layout transposes it onto the turned grid and back" do
      {:ok, p} = LayoutEdit.set_frame(classic(), "portrait")
      assert p["grid"] == %{"cols" => 6, "rows" => 14}
      assert at(p, "keys") == LayoutEdit.cell(3, 0, 3, 14)
      assert get_in(LayoutEdit.find(p, "keys") |> elem(1), ["keyboard", "orientation"]) == "vertical"
      valid!(p)
      {:ok, back} = LayoutEdit.set_frame(p, "landscape")
      assert at(back, "keys") == at(classic(), "keys")
    end
  end

  describe "bindings" do
    test "set on a control or on one pad of a pad grid; never on the creature" do
      to = [%{"to" => %{"button" => "play"}}]
      {:ok, l} = LayoutEdit.set_bindings(classic(), "fx", nil, to)
      assert LayoutEdit.bindings(l, "fx") == to
      assert {:error, _} = LayoutEdit.set_bindings(classic(), "menu", nil, to)

      drums = Layouts.preset("drum-pads").data
      {:ok, d} = LayoutEdit.set_bindings(drums, "pads", 3, to)
      assert LayoutEdit.bindings(d, "pads", 3) == to
      assert LayoutEdit.bindings(d, "pads", 2) == [%{"to" => %{"key" => 14}}]
    end
  end
end
