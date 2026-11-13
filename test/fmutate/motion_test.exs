defmodule FMutate.MotionTest do
  use ExUnit.Case, async: true

  alias FMutate.{LayoutEdit, Layouts, Motion}
  alias FMutate.Layouts.Schema

  @panel "test/fixtures/panel.layout.json" |> File.read!() |> JSON.decode!()

  defp sensor(type, name), do: %{type: type, name: name, vendor: "v", unit: nil, max_range: 1.0, resolution: 0.1, wake_up: false}

  defp full, do: [sensor(:accelerometer, "Accel"), sensor(:gyroscope, "Gyro"), sensor(:proximity, "Prox"), sensor(:light, "Light")]

  # a motion control added to an empty page, with bindings
  defp with_motion(bindings, motion \\ nil) do
    {:ok, l, page} = LayoutEdit.add_page(@panel)
    {:ok, l, id} = LayoutEdit.add(l, page, "motion", 4, 2)
    {:ok, l} = LayoutEdit.set_bindings(l, id, nil, bindings)
    {:ok, l} = if motion, do: LayoutEdit.put(l, id, %{"motion" => motion}), else: {:ok, l}
    {l, id}
  end

  describe "layouts" do
    test "a motion control with its settings and gesture bindings is a valid layout" do
      {l, _} =
        with_motion(
          [
            %{"on" => "x", "to" => %{"encoder" => "knob1"}},
            %{"on" => "y", "to" => %{"midi" => %{"type" => "pitch_bend", "channel" => 1}}},
            %{"on" => "twist", "to" => %{"pot" => "master"}},
            %{"on" => "shake", "to" => %{"key" => 7}, "mode" => "toggle"},
            %{"on" => "near", "to" => %{"button" => "play"}}
          ],
          %{"engage" => "latch", "range" => 30, "on_release" => "spring_back", "shake" => "hard"}
        )

      assert Layouts.validate(l) == :ok
    end

    test "settings the schema doesn't know are refused" do
      for bad <- [%{"engage" => "always"}, %{"range" => 20}, %{"shake" => "wild"}, %{"speed" => 2}] do
        {l, _} = with_motion([], bad)
        assert {:error, _} = Schema.validate(l), inspect(bad)
      end

      {l, _} = with_motion([%{"on" => "wiggle", "to" => %{"key" => 1}}])
      assert {:error, _} = Schema.validate(l)
    end
  end

  describe "adding one" do
    test "comes at 2×2 with the default settings, and binds tilt X first" do
      {l, id} = with_motion([])
      {_, c} = LayoutEdit.find(l, id)
      assert c["at"]["w"] == 2 and c["at"]["h"] == 2
      assert c["motion"] == %{"engage" => "hold", "range" => 45, "on_release" => "stay", "shake" => "firm"}
      assert LayoutEdit.default_on(c) == "x"
    end

    test "fits a single free cell, is listed at 1×1 and never resized below it" do
      {:ok, l, page} = LayoutEdit.add_page(@panel)
      l = Enum.reduce([{12, 4}, {13, 4}, {12, 5}], l, fn {c, r}, l -> l |> LayoutEdit.add(page, "button", c, r) |> elem(1) end)
      assert %{fits: true, size: "1×1"} = LayoutEdit.add_menu(l, page, 13, 5) |> Enum.find(&(&1.type == "motion"))

      {:ok, l, id} = LayoutEdit.add(l, page, "motion", 13, 5)
      assert LayoutEdit.find(l, id) |> elem(1) |> Map.get("at") == LayoutEdit.cell(13, 5, 1, 1)
      assert Layouts.validate(l) == :ok

      {l, id} = with_motion([])
      assert {:ok, _} = LayoutEdit.resize(l, id, LayoutEdit.cell(4, 2, 1, 1))
      assert {:error, _} = LayoutEdit.resize(l, id, LayoutEdit.cell(4, 2, 0, 1))
    end
  end

  describe "availability" do
    test "a phone with every motion sensor can do every gesture" do
      a = Motion.availability(full())
      assert a["x"] == {:ok, "Accel"} and a["shake"] == {:ok, "Accel"}
      assert a["twist"] == {:ok, "Gyro"} and a["near"] == {:ok, "Prox"}
      assert Motion.addable?(full())
    end

    test "without a gyroscope or proximity sensor, twist and near are missing with a reason; tilt and shake work" do
      a = Motion.availability([sensor(:accelerometer, "Accel")])
      assert {:missing, why} = a["twist"]
      assert why =~ "gyroscope"
      assert {:missing, _} = a["near"]
      assert {:ok, _} = a["y"]
      assert Motion.addable?([sensor(:accelerometer, "Accel")])
    end

    test "no sensors at all: nothing works and a motion control can't be added" do
      assert Enum.all?(Motion.availability([]), &match?({_, {:missing, _}}, &1))
      refute Motion.addable?([])
      refute Motion.addable?([sensor(:gyroscope, "Gyro")])
    end

    test "tilt and twist are values, shake and near presses" do
      assert Enum.map(Motion.gestures(), &Motion.kind/1) == [:value, :value, :value, :press, :press]
    end
  end

  describe "settings" do
    test "absent settings read as their defaults; only the schema's choices can be set" do
      c = %{"type" => "motion", "motion" => %{"range" => 90}}
      assert Motion.setting(c, "range") == 90
      assert Motion.setting(c, "engage") == "hold"
      assert {:ok, %{"range" => 90, "engage" => "latch"}} = Motion.put_setting(c, "engage", "latch")
      assert :error = Motion.put_setting(c, "range", 20)
    end
  end
end
