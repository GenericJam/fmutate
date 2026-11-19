defmodule FMutate.RoutePicker do
  @moduledoc """
  iOS: where the sound plays, and the system's route picker (`AVRoutePickerView`, `ios/FMutateRoutePicker.swift`).
  iOS chooses the audio output itself, so the I/O screen shows this native view in place of Android's output
  list (`fm1io`). No props, no events.
  """

  use Mob.Component

  @impl true
  def mount(_props, socket), do: {:ok, socket}

  @impl true
  def render(_assigns), do: %{}
end
