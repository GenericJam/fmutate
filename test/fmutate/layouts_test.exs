defmodule FMutate.LayoutsTest do
  use ExUnit.Case, async: false

  alias FMutate.{LayoutEdit, Layouts}
  alias FMutate.Layouts.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "fmutate_layouts_#{System.unique_integer([:positive])}")
    Application.put_env(:fmutate_app, :data_dir, dir)

    on_exit(fn ->
      Application.delete_env(:fmutate_app, :data_dir)
      File.rm_rf(dir)
    end)

    :ok
  end

  describe "presets" do
    test "every shipped preset validates (schema and editing rules)" do
      ids = Enum.map(Layouts.presets(), & &1.id)
      assert "classic" in ids and "drum-pads" in ids and "sound-designer" in ids and "chord-harp" in ids
      for p <- Layouts.presets(), do: assert(Layouts.validate(p.data) == :ok, "#{p.id}: #{inspect(Layouts.validate(p.data))}")
    end

    test "a portrait preset ships" do
      assert Enum.any?(Layouts.presets(), &(&1.frame == "portrait"))
    end
  end

  describe "schema" do
    test "rejects wrong format, bad ids, unknown top-level keys and bad bindings" do
      l = Layouts.classic()
      assert {:error, [{"/format", _}]} = Schema.validate(%{l | "format" => "other"})
      assert {:error, [{"/id", _}]} = Schema.validate(%{l | "id" => "Has Spaces"})
      assert {:error, [{"/extra", "not allowed"}]} = Schema.validate(Map.put(l, "extra", 1))
      assert {:error, _} = Schema.validate(%{l | "pages" => []})

      bad = put_in(l, ["dock"], [%{"id" => "menu", "type" => "menu", "at" => LayoutEdit.cell(0, 0, 1, 1), "bindings" => [%{"to" => %{"key" => 30}}]}])
      assert {:error, [{"/dock/0/bindings/0/to", _}]} = Schema.validate(bad)
    end

    test "a binding target is exactly one form" do
      l = Layouts.classic()
      two = [%{"to" => %{"key" => 1, "button" => "fx"}}]
      {:ok, l} = LayoutEdit.set_bindings(l, "fx", nil, two)
      assert {:error, _} = Schema.validate(l)
    end
  end

  describe "per instance and firmware" do
    test "without a saved layout it is the classic one, for that firmware" do
      l = Layouts.current("a", "obervave")
      assert l["id"] == "classic"
      assert l["firmware"] == %{"id" => "obervave"}
      refute Layouts.saved?("a", "obervave")
    end

    test "a saved layout comes back for its instance and firmware only" do
      # (11, 0) is free in the classic layout (the room right of KNOB4)
      {:ok, l} = LayoutEdit.move(Layouts.current("a", "obervave"), "fx", 11, 0)
      assert :ok = Layouts.save("a", "obervave", l)

      assert Layouts.current("a", "obervave") |> LayoutEdit.find("fx") |> elem(1) |> Map.get("at") ==
               LayoutEdit.cell(11, 0, 1, 1)

      # another firmware, another instance: still classic
      assert Layouts.current("a", "shineon") |> LayoutEdit.find("fx") |> elem(1) |> get_in(["at", "col"]) == 8
      assert Layouts.current("b", "obervave") |> LayoutEdit.find("fx") |> elem(1) |> get_in(["at", "col"]) == 8
    end

    test "an invalid layout is not saved" do
      l = Layouts.current("a", "obervave")
      # FX onto SEL's cell
      overlapping = update_in(l, ["pages", Access.at(0), "controls"], fn cs -> Enum.map(cs, &if(&1["id"] == "fx", do: put_in(&1, ["at", "col"], 9), else: &1)) end)
      assert {:error, [msg | _]} = Layouts.save("a", "obervave", overlapping)
      assert msg =~ "overlaps"
      refute Layouts.saved?("a", "obervave")
    end

    test "a corrupt saved file falls back to classic; reset forgets the saved layout" do
      File.write!(FMutate.Paths.layout("a", "obervave"), "{not json")
      assert Layouts.current("a", "obervave")["id"] == "classic"

      {:ok, l} = LayoutEdit.rename(Layouts.current("a", "obervave"), "Mine")
      :ok = Layouts.save("a", "obervave", l)
      assert Layouts.current("a", "obervave")["name"] == "Mine"
      assert Layouts.reset("a", "obervave")["name"] == "Classic"
      refute Layouts.saved?("a", "obervave")
    end

    test "a new layout from a preset is retargeted to the running firmware" do
      l = Layouts.from_preset("drum-pads", "obervave")
      assert l["firmware"] == %{"id" => "obervave"}
      assert :ok = Layouts.save("a", "obervave", l)
      assert Layouts.current("a", "obervave")["id"] == "drum-pads"
    end
  end
end
