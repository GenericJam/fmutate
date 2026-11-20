defmodule FMutate.MIDI.Params do
  @moduledoc """
  The synth parameters a firmware's MIDI CCs set, for the firmwares FMutate knows them of:
  `priv/midi_params/<firmware id>@<version>.json`, generated from the firmware's source at the commit FMutate
  builds (`tools/midi_params.exs`). Keyed by version, so a firmware update without a list has none (rather
  than a wrong one).

  A parameter is `%{cc, page, name}`; `label/1` is what the player reads ("OSC 1 · WAVE"). Used by the I/O
  screen to say what a knob that drives nothing in FMutate does on the firmware (its CC goes to the firmware's
  own MIDI map), and to pin a hardware knob to a parameter by name (`FMutate.MIDI`).
  """

  alias FMutate.{Firmware, Paths}

  @type param :: %{cc: byte, page: String.t(), name: String.t()}

  @doc "The parameters of a firmware (by id, at the version FMutate has of it), or nil when unknown."
  @spec of(String.t() | nil) :: [param] | nil
  def of(nil), do: nil

  def of(firmware_id) do
    case Firmware.get(firmware_id) do
      %{version: version} -> list(firmware_id, version)
      _ -> nil
    end
  end

  @doc "The parameters of `firmware_id` at `version`, or nil when there is no list for it."
  @spec list(String.t(), String.t()) :: [param] | nil
  def list(firmware_id, version) do
    key = {__MODULE__, firmware_id, version}

    case :persistent_term.get(key, :none) do
      :none ->
        list = read(firmware_id, version)
        :persistent_term.put(key, list)
        list

      list ->
        list
    end
  end

  defp read(firmware_id, version) do
    with {:ok, bin} <- File.read(Paths.priv("midi_params/#{firmware_id}@#{version}.json")),
         {:ok, %{"params" => params}} <- JSON.decode(bin) do
      for p <- params, do: %{cc: p["cc"], page: p["page"], name: p["name"]}
    else
      _ -> nil
    end
  end

  @doc ~S|What the player reads: "OSC 1 · WAVE".|
  def label(%{page: page, name: name}), do: "#{page} · #{name}"

  @doc "The parameter a CC sets, or nil."
  def by_cc(nil, _cc), do: nil
  def by_cc(params, cc), do: Enum.find(params, &(&1.cc == cc))

  @doc "The parameter of a label, or nil."
  def by_label(nil, _label), do: nil
  def by_label(params, label), do: Enum.find(params, &(label(&1) == label))
end
