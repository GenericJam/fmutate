defmodule FMutate.NoteLevelTest do
  # Note level (a keyboard strip's velocity.pressure): on by default, what the surface is handed, the note-level
  # toggle on the surface (binding target {"action": "note_level"}) and what it saves.
  use ExUnit.Case, async: false

  alias FMutate.{Editor, LayoutEdit, Layouts}
  alias FMutate.Layouts.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "fmutate_note_level_#{System.unique_integer([:positive])}")
    Application.put_env(:fmutate_app, :data_dir, dir)

    on_exit(fn ->
      Application.delete_env(:fmutate_app, :data_dir)
      File.rm_rf(dir)
    end)

    :ok
  end

  defp strip(vel), do: %{"id" => "k", "type" => "keyboard", "keyboard" => %{"velocity" => vel}}

  # classic with its keyboard's velocity as given (strike position unless it says otherwise) and FX turned into a
  # note-level toggle
  defp layout(vel \\ %{}, source \\ "position") do
    l = Layouts.classic()

    {:ok, l} =
      LayoutEdit.put(l, "keys", %{
        "keyboard" =>
          Map.put(
            LayoutEdit.find(l, "keys") |> elem(1) |> Map.get("keyboard"),
            "velocity",
            Map.put(vel, "source", source)
          )
      })

    {:ok, l} =
      LayoutEdit.set_bindings(l, "fx", nil, [
        %{"to" => %{"action" => "note_level"}, "mode" => "toggle"}
      ])

    l
  end

  defp fixed_classic, do: layout(%{}, "fixed")

  defp velocity(layout, id),
    do: layout |> LayoutEdit.find(id) |> elem(1) |> get_in(["keyboard", "velocity"])

  # the surface's view of a strip: what InstrumentView.kt / FMutateInstrumentView.swift read
  defp surface_pressure(socket, id),
    do: socket.assigns.layout_json |> JSON.decode!() |> velocity(id) |> Map.fetch!("pressure")

  defp socket(firmware) do
    Mob.Socket.new(FMutate.InstrumentScreen)
    |> Mob.Socket.assign(:editing, false)
    |> Editor.load("a", firmware)
  end

  describe "the default" do
    test "a strike-position strip follows the finger unless the layout says otherwise" do
      assert LayoutEdit.note_level?(strip(%{"source" => "position"}), true)
      assert LayoutEdit.note_level?(strip(%{"source" => "position", "pressure" => true}), true)
      refute LayoutEdit.note_level?(strip(%{"source" => "position", "pressure" => false}), true)
    end

    test "an explicit swell wins over the default; an explicit pressure wins over swell" do
      refute LayoutEdit.note_level?(strip(%{"source" => "position", "swell" => true}), true)

      assert LayoutEdit.note_level?(
               strip(%{"source" => "position", "swell" => true, "pressure" => true}),
               true
             )

      assert LayoutEdit.note_level?(strip(%{"source" => "position", "swell" => false}), true)
    end

    test "never without per-note pressure in the firmware, nor on a fixed-velocity strip" do
      refute LayoutEdit.note_level?(strip(%{"source" => "position"}), false)
      refute LayoutEdit.note_level?(strip(%{"source" => "position", "pressure" => true}), false)
      refute LayoutEdit.note_level?(strip(%{"source" => "fixed", "pressure" => true}), true)
      refute LayoutEdit.note_level?(strip(%{"source" => "fixed"}), true)
      refute LayoutEdit.note_level?(%{"id" => "b", "type" => "button"}, true)
    end

    test "a strip that names no velocity source plays by strike position; an explicit source stays" do
      for s <- [strip(%{}), strip(%{"min" => 20}), %{"id" => "k", "type" => "keyboard"}] do
        assert LayoutEdit.velocity_source(s) == "position"
        assert LayoutEdit.note_level?(s, true)
      end

      assert LayoutEdit.velocity_source(strip(%{"source" => "fixed"})) == "fixed"
      assert LayoutEdit.velocity_source(strip(%{"source" => "position"})) == "position"
    end

    test "the surface gets each strip's effective setting, the saved layout keeps it absent" do
      l = layout()
      assert :ok = Layouts.save("a", "obervave", l)
      refute Map.has_key?(velocity(Layouts.current("a", "obervave"), "keys"), "pressure")

      # OberVave takes poly aftertouch: on; ShineOn doesn't: off (its swell would apply instead)
      assert surface_pressure(socket("obervave"), "keys") == true
      assert :ok = Layouts.save("a", "shineon", layout(%{"swell" => true}))
      assert surface_pressure(socket("shineon"), "keys") == false
    end

    test "the bundled classic layout, unedited: velocity from strike position, note level on OberVave only" do
      classic = Layouts.classic()
      refute Map.has_key?(velocity(classic, "keys") || %{}, "source")

      for {fw, level} <- [{"obervave", true}, {"shineon", false}] do
        s = socket(fw)
        surface = s.assigns.layout_json |> JSON.decode!() |> velocity("keys")
        assert {fw, surface["source"], surface["pressure"]} == {fw, "position", level}
        # what the editor shows, from the same layout
        assert LayoutEdit.velocity_source(LayoutEdit.find(s.assigns.layout, "keys") |> elem(1)) ==
                 "position"
      end

      # a saved layout that never set velocity gets the default too, and saving doesn't write it
      assert :ok = Layouts.save("a", "obervave", classic)
      assert surface_pressure(socket("obervave"), "keys") == true
      refute Map.has_key?(velocity(Layouts.current("a", "obervave"), "keys") || %{}, "source")
    end

    test "an explicit fixed strip stays fixed: firmware key presses, no note level" do
      assert :ok = Layouts.save("a", "obervave", fixed_classic())
      surface = socket("obervave").assigns.layout_json |> JSON.decode!() |> velocity("keys")
      assert {surface["source"], surface["pressure"]} == {"fixed", false}
    end
  end

  describe "the note-level toggle on the surface" do
    test "on the unedited classic layout it is live: a press turns note level off and keeps strike velocity" do
      s = socket("obervave")
      assert LayoutEdit.note_level_on?(s.assigns.layout, true)

      s = Editor.event("note_level", %{}, s)
      surface = s.assigns.layout_json |> JSON.decode!() |> velocity("keys")
      assert {surface["source"], surface["pressure"]} == {"position", false}
      assert velocity(Layouts.current("a", "obervave"), "keys") == %{"pressure" => false}

      s = Editor.event("note_level", %{}, s)
      assert surface_pressure(s, "keys") == true
    end

    test "a press switches every strike-position strip, saved, and the surface gets the new setting" do
      {:ok, l, page} = LayoutEdit.add_page(layout())
      {:ok, l, k2} = LayoutEdit.add(l, page, "keyboard", 0, 2)

      {:ok, l} =
        LayoutEdit.put(l, k2, %{
          "keyboard" =>
            Map.put(LayoutEdit.find(l, k2) |> elem(1) |> Map.get("keyboard"), "velocity", %{
              "source" => "position",
              "pressure" => false
            })
        })

      assert :ok = Layouts.save("a", "obervave", l)

      # one strip on (by default), one off: it shows on, and a press turns both off
      s = socket("obervave")
      assert LayoutEdit.note_level_on?(s.assigns.layout, true)
      s = Editor.event("note_level", %{}, s)
      assert {surface_pressure(s, "keys"), surface_pressure(s, k2)} == {false, false}
      saved = Layouts.current("a", "obervave")

      assert {velocity(saved, "keys")["pressure"], velocity(saved, k2)["pressure"]} ==
               {false, false}

      # the next press turns both on; the editor's toggle reads the same layout
      s = Editor.event("note_level", %{}, s)
      assert {surface_pressure(s, "keys"), surface_pressure(s, k2)} == {true, true}

      assert LayoutEdit.note_level?(
               LayoutEdit.find(Layouts.current("a", "obervave"), k2) |> elem(1),
               true
             )

      # and it survives a restart (a new screen loads what was saved)
      assert surface_pressure(socket("obervave"), k2) == true
    end

    test "off brings back the strip's swell; on takes over from it" do
      assert :ok = Layouts.save("a", "obervave", layout(%{"swell" => true}))
      s = socket("obervave")
      refute LayoutEdit.note_level_on?(s.assigns.layout, true)

      s = Editor.event("note_level", %{}, s)
      assert surface_pressure(s, "keys") == true
      assert velocity(s.assigns.layout, "keys")["swell"] == true

      s = Editor.event("note_level", %{}, s)
      assert surface_pressure(s, "keys") == false

      assert LayoutEdit.note_level?(LayoutEdit.find(s.assigns.layout, "keys") |> elem(1), true) ==
               false
    end

    test "changes nothing on a firmware without per-note pressure" do
      assert :ok = Layouts.save("a", "shineon", layout())
      s = Editor.event("note_level", %{}, socket("shineon"))
      assert velocity(Layouts.current("a", "shineon"), "keys") == %{"source" => "position"}
      assert {_, "This firmware doesn't take per-note pressure"} = s.assigns.toast
    end

    test "changes nothing without a strike-position strip" do
      assert :ok = Layouts.save("a", "obervave", fixed_classic())
      s = Editor.event("note_level", %{}, socket("obervave"))
      assert velocity(Layouts.current("a", "obervave"), "keys") == %{"source" => "fixed"}
      assert {_, "No keyboard strip plays by strike position"} = s.assigns.toast
    end
  end

  describe "validation" do
    test "the note-level action and an explicit pressure are valid; other actions and non-booleans are not" do
      assert :ok = Layouts.validate(layout(%{"pressure" => false, "swell" => true}))

      {:ok, bad} =
        LayoutEdit.set_bindings(layout(), "fx", nil, [%{"to" => %{"action" => "note_levels"}}])

      assert {:error, _} = Schema.validate(bad)

      assert {:error, _} = Schema.validate(layout(%{"pressure" => "yes"}))
    end
  end
end
