defmodule FMutate.Layouts do
  @moduledoc """
  Layout files (`priv/layout.schema.json`, format `fmutate.layout/1`). Presets ship in `priv/layouts/`;
  the native instrument view parses and renders them (android `fmutate/Layout.kt`), so here they stay JSON
  text and only the fields the app itself needs are decoded.
  """

  @doc "Directory of the preset layouts (on a device Mob pushes priv/ next to the BEAMs)."
  def presets_dir do
    case System.get_env("MOB_BEAMS_DIR") do
      nil -> Path.join(:code.priv_dir(:fmutate_app) |> to_string(), "layouts")
      dir -> Path.join([dir, "priv", "layouts"])
    end
  end

  @doc "Every preset as `%{id, name, firmware, frame, json}`."
  def presets do
    presets_dir()
    |> Path.join("*.layout.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&load!/1)
  end

  @doc "A preset by id."
  def preset(id), do: Enum.find(presets(), &(&1.id == id))

  @doc "The classic layout (the FM-1 panel); works with any firmware."
  def classic, do: preset("classic")

  @doc "Presets usable with a firmware: its own plus the universal (`firmware.id == \"any\"`)."
  def for_firmware(firmware_id),
    do: Enum.filter(presets(), &(&1.firmware in ["any", firmware_id]))

  defp load!(path) do
    json = File.read!(path)
    data = JSON.decode!(json)

    %{
      id: data["id"],
      name: data["name"],
      firmware: get_in(data, ["firmware", "id"]),
      frame: data["frame"],
      json: json
    }
  end
end
