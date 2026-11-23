defmodule FMutate.LayoutLibraryTest do
  # The layout library (saved on purpose, for any synth; import and export) and the one-step undo of the current
  # layout, as the Layouts sheet and the edit pill use them.
  use ExUnit.Case, async: false

  alias FMutate.{Editor, LayoutEdit, Layouts}

  setup do
    dir = Path.join(System.tmp_dir!(), "fmutate_layout_library_#{System.unique_integer([:positive])}")
    Application.put_env(:fmutate_app, :data_dir, dir)

    on_exit(fn ->
      Application.delete_env(:fmutate_app, :data_dir)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  # classic with FX moved to (11, 0), a free cell: a layout the player made
  defp custom(firmware) do
    {:ok, l} = LayoutEdit.move(Layouts.current("a", firmware), "fx", 11, 0)
    l
  end

  defp fx_col(layout), do: layout |> LayoutEdit.find("fx") |> elem(1) |> get_in(["at", "col"])

  defp socket(firmware) do
    Mob.Socket.new(FMutate.InstrumentScreen)
    |> Mob.Socket.assign(:editing, true)
    |> Editor.load("a", firmware)
  end

  defp write_file(dir, name, content) do
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  describe "the library" do
    test "every save is a new entry, stamped, listed newest first; nothing is overwritten" do
      mine = custom("obervave")
      {:ok, first} = Layouts.save_to_library(mine, "Mine")
      bytes = File.read!(Path.join(FMutate.Paths.saved_layouts(), first.file))
      {:ok, second} = Layouts.save_to_library(mine, "Mine")
      {:ok, _} = Layouts.save_to_library(mine, "  ")

      assert first.file != second.file
      assert File.read!(Path.join(FMutate.Paths.saved_layouts(), first.file)) == bytes

      assert [%{name: "Classic"}, %{name: "Mine", file: f2}, %{name: "Mine", file: f1}] = Layouts.library()
      assert {f2, f1} == {second.file, first.file}

      for e <- Layouts.library() do
        assert e.saved_at =~ ~r/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/
        assert e.firmware == "obervave"
      end
    end

    test "an older entry lists after a newer one; delete removes only that entry", %{dir: dir} do
      old = Layouts.classic() |> Map.put("name", "Old") |> Map.put("meta", %{"saved_at" => "2020-01-02T03:04:05Z"})
      {:ok, _} = Layouts.import_file(write_file(dir, "old.json", JSON.encode!(old)))
      {:ok, new} = Layouts.save_to_library(custom("obervave"), "New")

      assert [%{name: "New"}, %{name: "Old", saved_at: "2020-01-02T03:04:05Z"}] = Layouts.library()

      :ok = Layouts.delete_saved(new.file)
      assert [%{name: "Old"}] = Layouts.library()
    end

    test "a saved layout loads onto another synth, retargeted, and the load can be undone" do
      {:ok, entry} = Layouts.save_to_library(custom("obervave"), "Moved FX")

      assert {:ok, loaded} = Layouts.load_saved("a", "shineon", entry.file)
      assert loaded["firmware"] == %{"id" => "shineon"}
      assert fx_col(Layouts.current("a", "shineon")) == 11
      # the entry keeps where it came from
      assert [%{firmware: "obervave"}] = Layouts.library()
      # the other synth's layout is untouched
      assert fx_col(Layouts.current("a", "obervave")) == 8

      assert {:ok, back} = Layouts.undo("a", "shineon")
      assert back["id"] == "classic"
      refute Layouts.saved?("a", "shineon")
    end

    test "import refuses files that aren't valid layouts, with the reason", %{dir: dir} do
      assert {:error, [_]} = Layouts.import_file(write_file(dir, "a.json", "{not json"))
      assert {:error, [_]} = Layouts.import_file(write_file(dir, "b.json", "[1, 2]"))

      bad = Layouts.classic() |> Map.put("format", "fmutate.layout/9")
      assert {:error, [msg | _]} = Layouts.import_file(write_file(dir, "c.json", JSON.encode!(bad)))
      assert msg =~ "/format"

      overlapping = update_in(Layouts.classic(), ["pages", Access.at(0), "controls"], fn cs -> Enum.map(cs, &if(&1["id"] == "fx", do: put_in(&1, ["at", "col"], 9), else: &1)) end)
      assert {:error, [msg | _]} = Layouts.import_file(write_file(dir, "d.json", JSON.encode!(overlapping)))
      assert msg =~ "overlaps"

      assert Layouts.library() == []
    end

    test "import keeps the file's saved_at (in UTC) or stamps it now; it doesn't load it", %{dir: dir} do
      dated = Layouts.classic() |> Map.put("name", "Dated") |> Map.put("meta", %{"saved_at" => "2021-06-01T12:00:00+02:00"})
      assert {:ok, %{saved_at: "2021-06-01T10:00:00Z"}} = Layouts.import_file(write_file(dir, "x.json", JSON.encode!(dated)))

      plain = Map.put(Layouts.classic(), "name", "Plain")
      assert {:ok, %{saved_at: at}} = Layouts.import_file(write_file(dir, "y.json", JSON.encode!(plain)))
      {:ok, at, 0} = DateTime.from_iso8601(at)
      assert DateTime.diff(DateTime.utc_now(), at) in 0..5

      refute Layouts.saved?("a", "obervave")
    end

    test "export writes the saved layout as saved, not the surface-resolved copy", %{dir: dir} do
      {:ok, entry} = Layouts.save_to_library(custom("obervave"), "To share")
      {:ok, saved} = Layouts.read_saved(entry.file)

      assert {:ok, path} = Layouts.export_saved(entry.file, Path.join(dir, "exports"))
      assert Path.basename(path) == "to-share.layout.json"
      exported = path |> File.read!() |> JSON.decode!()
      assert exported == saved
      refute exported == LayoutEdit.surface(saved, true)

      # and it imports back as a new entry
      assert {:ok, %{name: "To share"}} = Layouts.import_file(path)
      assert length(Layouts.library()) == 2
    end
  end

  describe "one-step undo" do
    test "undo and redo swap the current layout, and survive a restart" do
      assert Layouts.undo_state("a", "obervave") == nil
      :ok = Layouts.change("a", "obervave", custom("obervave"))
      assert Layouts.undo_state("a", "obervave") == :undo

      {:ok, l} = Layouts.undo("a", "obervave")
      assert fx_col(l) == 8
      refute Layouts.saved?("a", "obervave")

      # a restart: the app reads it all back from the files
      s = socket("obervave")
      assert s.assigns.undo == :redo
      assert fx_col(s.assigns.layout) == 8

      s = Editor.event("edit_undo", %{}, s)
      assert fx_col(s.assigns.layout) == 11
      assert s.assigns.undo == :undo
      assert fx_col(Layouts.current("a", "obervave")) == 11
    end

    test "an edit on the surface is undone from the edit pill" do
      s = socket("obervave")
      s = Editor.event("edit_move", %{"id" => "fx", "col" => 11, "row" => 0}, s)
      assert fx_col(s.assigns.layout) == 11
      assert Editor.undo_prop(s.assigns) == "undo"

      s = Editor.event("edit_undo", %{}, s)
      assert fx_col(s.assigns.layout) == 8
      assert Editor.undo_prop(s.assigns) == "redo"
    end

    test "Original layout, then Undo, brings the player's layout back" do
      :ok = Layouts.change("a", "obervave", custom("obervave"))
      s = Editor.original(socket("obervave"))
      assert fx_col(s.assigns.layout) == 8
      refute Layouts.saved?("a", "obervave")

      s = Editor.undo(s)
      assert fx_col(s.assigns.layout) == 11
      assert fx_col(Layouts.current("a", "obervave")) == 11
    end

    test "typing into one text field is one step; another field starts a new one" do
      s = socket("obervave")
      s = Enum.reduce(["M", "My", "My l", "My lay"], s, &Editor.dispatch(:change, {:editor, :layout_name}, &1, &2))
      assert s.assigns.layout["name"] == "My lay"

      page = s.assigns.page
      s = Editor.dispatch(:change, {:editor, :page_name}, "Main", s)
      s = Editor.dispatch(:change, {:editor, :page_name}, "Mainly", s)

      # the page name goes back to before typing in it, the layout name stays
      s = Editor.undo(s)
      assert s.assigns.layout["name"] == "My lay"
      assert LayoutEdit.page(s.assigns.layout, page)["name"] != "Mainly"

      # the layout name as one step, after another edit
      s = Editor.undo(s)
      s = Editor.dispatch(:change, {:editor, :layout_name}, "X", s)
      s = Editor.dispatch(:change, {:editor, :layout_name}, "XY", s)
      s = Editor.undo(s)
      assert s.assigns.layout["name"] == "My lay"
    end

    test "a change that changes nothing keeps what Undo puts back" do
      :ok = Layouts.change("a", "obervave", custom("obervave"))
      :ok = Layouts.change("a", "obervave", Layouts.current("a", "obervave"))

      {:ok, l} = Layouts.undo("a", "obervave")
      assert fx_col(l) == 8
    end
  end
end
