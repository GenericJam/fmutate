defmodule FMutate.Layouts do
  @moduledoc """
  Layouts (`priv/layout.schema.json`, format `fmutate.layout/1`): the presets shipped in `priv/layouts/`,
  and the player's own.

  A layout belongs to one firmware and one instance (HANDOFF §3, §5): each `{instance, firmware}` has its
  current layout, saved under the data dir (`FMutate.Paths.layout/2`) whenever it is edited. Until the
  player makes one, it is the classic layout, which is also always one tap away ("Reset to classic").
  Presets are starting points: "new layout from a preset" copies one for the running firmware, "new page
  from a preset" (`FMutate.LayoutEdit.add_page_from_preset/2`) copies its first page.

  Layouts are decoded JSON (string keys) on this side; the native instrument view gets them as JSON text
  (`encode/1`) and draws them (android `fmutate/Layout.kt`). Every saved layout passes `validate/1`: the
  schema (`FMutate.Layouts.Schema`) and the editing rules (`FMutate.LayoutEdit.semantic_errors/1`).
  """

  alias FMutate.{LayoutEdit, Paths}
  alias FMutate.Layouts.Schema

  @type layout :: map()

  @doc "Directory of the preset layouts."
  def presets_dir, do: Paths.priv("layouts")

  @doc "Every preset as `%{id, name, firmware, frame, data}` (`data` is the decoded layout)."
  def presets do
    presets_dir()
    |> Path.join("*.layout.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&load_preset!/1)
  end

  @doc "A preset by id."
  def preset(id), do: Enum.find(presets(), &(&1.id == id))

  @doc "The classic layout (the FM-1 panel), as shipped; works with any firmware."
  def classic, do: preset("classic").data

  @doc "Presets made for a firmware: its own plus the universal ones (`firmware.id == \"any\"`)."
  def for_firmware(firmware_id), do: Enum.filter(presets(), &(&1.firmware in ["any", firmware_id]))

  defp load_preset!(path) do
    data = path |> File.read!() |> JSON.decode!()
    %{id: data["id"], name: data["name"], firmware: get_in(data, ["firmware", "id"]), frame: data["frame"], data: data}
  end

  ## The player's layouts

  @doc """
  The current layout of an instance for a firmware: the saved one, or the classic layout. A saved file
  that no longer validates (hand-edited, older app) is ignored rather than drawn wrong.
  """
  @spec current(String.t(), String.t() | nil) :: layout
  def current(instance, firmware_id) do
    with id when is_binary(id) <- firmware_id,
         {:ok, json} <- File.read(Paths.layout(instance, id)),
         {:ok, data} <- decode(json),
         :ok <- validate(data) do
      data
    else
      _ -> for_this(classic(), firmware_id)
    end
  end

  @doc "Whether the player has a saved layout for this firmware (else the instrument shows classic)."
  def saved?(instance, firmware_id), do: File.exists?(Paths.layout(instance, firmware_id))

  @doc "Validate and save the current layout of an instance for a firmware."
  @spec save(String.t(), String.t(), layout) :: :ok | {:error, [String.t()]}
  def save(instance, firmware_id, layout) do
    layout = for_this(layout, firmware_id)

    with :ok <- validate(layout) do
      path = Paths.layout(instance, firmware_id)
      tmp = path <> ".tmp"
      File.write!(tmp, encode(layout))
      File.rename!(tmp, path)
    end
  end

  @doc "Forget the saved layout: the classic one again. Returns it."
  def reset(instance, firmware_id) do
    _ = File.rm(Paths.layout(instance, firmware_id))
    current(instance, firmware_id)
  end

  @doc "A copy of a preset for a firmware, ready to be the current layout."
  def from_preset(preset_id, firmware_id) do
    case preset(preset_id) do
      nil -> nil
      p -> p.data |> for_this(firmware_id) |> put_in(["meta"], %{"made_by" => "user"})
    end
  end

  # a layout belongs to the firmware it is saved for
  defp for_this(layout, nil), do: layout
  defp for_this(layout, firmware_id), do: Map.put(layout, "firmware", %{"id" => firmware_id})

  @doc "`:ok`, or `{:error, messages}`: the schema first, then the editing rules."
  @spec validate(term()) :: :ok | {:error, [String.t()]}
  def validate(layout) do
    case Schema.validate(layout) do
      {:error, errors} ->
        {:error, Enum.map(errors, fn {path, msg} -> "#{if path == "", do: "/", else: path}: #{msg}" end)}

      :ok ->
        case LayoutEdit.semantic_errors(layout) do
          [] -> :ok
          errors -> {:error, errors}
        end
    end
  end

  @doc "Layout JSON text (what the instrument view and the files take)."
  def encode(layout), do: JSON.encode!(layout)

  @doc "Decode layout JSON text."
  def decode(json) do
    case JSON.decode(json) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, _} -> {:error, :not_an_object}
      error -> error
    end
  end
end
