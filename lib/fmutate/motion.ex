defmodule FMutate.Motion do
  @moduledoc """
  Motion controls (`"type": "motion"`): what their gestures are, which sensor each needs, and their settings.

  A motion control is a tile the player holds (or latches on) while moving the phone. The native surface
  (android `fmutate/MotionControl.kt`) reads the sensors and drives the bindings; readings never pass through
  the BEAM. This module is the editor's side: the gestures it can bind, whether this phone has the sensor for
  each (`availability/1`, from `MobSensors.list/0`), and the settings with their defaults.

  Gestures (a binding's `on`):

    * `x`: tilt X (roll; the right edge going down moves the value up), a value;
    * `y`: tilt Y (pitch; the top edge going up moves the value up), a value;
    * `twist`: turning the phone flat on its face (gyroscope yaw rate, integrated; clockwise is up), a value;
    * `shake`: a jolt of the phone (accelerometer), a press;
    * `near`: something close to the proximity sensor (a hand over the earpiece), a press.
  """

  @gestures [
    {"x", "Tilt X", :value, :accelerometer},
    {"y", "Tilt Y", :value, :accelerometer},
    {"twist", "Twist", :value, :gyroscope},
    {"shake", "Shake", :press, :accelerometer},
    {"near", "Near", :press, :proximity}
  ]

  @sensor_names %{accelerometer: "accelerometer", gyroscope: "gyroscope", proximity: "proximity sensor"}

  @defaults %{"engage" => "hold", "range" => 45, "on_release" => "stay", "shake" => "firm"}

  @doc "The gesture ids, in the sheet's order."
  def gestures, do: Enum.map(@gestures, &elem(&1, 0))

  @doc "A gesture's name for the player (\"Tilt X\")."
  def name(gesture), do: gesture |> find() |> elem(1)

  @doc "What a gesture drives: `:value` (tilt, twist) or `:press` (shake, near)."
  def kind(gesture), do: gesture |> find() |> elem(2)

  @doc "The sensor a gesture reads (`MobSensors` type)."
  def sensor(gesture), do: gesture |> find() |> elem(3)

  defp find(gesture), do: List.keyfind(@gestures, gesture, 0) || hd(@gestures)

  @doc "Whether `on` is a motion gesture."
  def gesture?(on), do: List.keymember?(@gestures, on, 0)

  @doc """
  Per gesture, whether this phone can do it: `%{gesture => {:ok, sensor_name} | {:missing, reason}}`, from a
  `MobSensors.list/0`-shaped list (maps with `:type` and `:name`).
  """
  def availability(sensors) do
    have = Map.new(Enum.reverse(sensors), &{&1.type, &1.name})

    Map.new(@gestures, fn {g, _, _, s} ->
      case have do
        %{^s => name} -> {g, {:ok, name}}
        _ -> {g, {:missing, "this phone has no #{@sensor_names[s]}"}}
      end
    end)
  end

  @doc "Whether a motion control can be added at all: the phone has an accelerometer (tilt and shake)."
  def addable?(sensors), do: Enum.any?(sensors, &(&1.type == :accelerometer))

  @doc """
  The sensors this phone has (`MobSensors.list/0`), or `[]` when the plugin's server isn't running (host
  builds, tests). One call, when the editor needs it; never a stream.
  """
  def sensors do
    MobSensors.list()
  catch
    :exit, _ -> []
  end

  @doc "A new motion control's settings."
  def defaults, do: @defaults

  @doc "A motion control's setting (`engage`, `range`, `on_release`, `shake`), its default when absent."
  def setting(c, key), do: get_in(c, ["motion", key]) || @defaults[key]

  @doc "The choices for each setting, in the sheet's order."
  def choices("engage"), do: ["hold", "latch"]
  def choices("range"), do: [15, 30, 45, 60, 90]
  def choices("on_release"), do: ["stay", "spring_back"]
  def choices("shake"), do: ["gentle", "firm", "hard"]

  @doc "Set one setting of a motion control's `motion` map; `:error` for a value the schema doesn't allow."
  def put_setting(c, key, value) do
    if value in choices(key),
      do: {:ok, Map.put(c["motion"] || %{}, key, value)},
      else: :error
  end
end
