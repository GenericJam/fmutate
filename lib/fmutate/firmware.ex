defmodule FMutate.Firmware do
  @moduledoc """
  The firmwares this build can run. v1 ships cartridges built from source (`native/build_android.sh`):
  each is `libcart_<id>.so` in the APK. The library (download, import `.fwsc`, the emulator backend for
  binary-only firmwares) builds on this list.
  """

  @enforce_keys [:id, :name, :version, :author, :license]
  defstruct [:id, :name, :version, :author, :license, :about, caps: %{}]

  @type t :: %__MODULE__{}

  # `caps`: what the firmware does with MIDI beyond notes, for bindings like keyboard wobble
  # (pitch bend). Unknown = false.
  @bundled [
    %{
      id: "obervave",
      name: "OberVave",
      version: "3.3.2",
      author: "zvenson",
      license: "GPL-3.0",
      about: "An 8-voice analog-style poly after the classic American polys of 1979-84.",
      caps: %{pitch_bend: true}
    },
    %{
      id: "shineon",
      name: "Shine On",
      version: "3.0.1",
      author: "zvenson",
      license: "GPL-3.0",
      about: "A string ensemble in the spirit of the late-70s machines.",
      caps: %{pitch_bend: true}
    }
  ]

  @doc "Every firmware this build knows, whether or not its cartridge is present."
  @spec all() :: [t]
  def all, do: Enum.map(@bundled, &struct!(__MODULE__, &1))

  @spec get(String.t()) :: t | nil
  def get(id), do: Enum.find(all(), &(&1.id == id))

  @doc "The default firmware on first run."
  def default_id, do: "obervave"

  @doc "Path of the firmware's cartridge, or nil when this build doesn't carry it."
  def cart(id), do: FMutate.Paths.bundled_cart(id)
end
