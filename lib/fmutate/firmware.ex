defmodule FMutate.Firmware do
  @moduledoc """
  The firmwares this build can run, and how.

  Two backends run a firmware in an engine process (docs/engine_protocol.md):

    * `:native` — the firmware built from its source as a cartridge (`libcart_<id>.so`, shipped in the
      APK, run by `libfm1engine.so`). Fast and sample-exact; only for firmwares with source.
    * `:emu` — the firmware's own package (`.fwsc`) run in the fm1-emu emulator (`libfm1emu.so`, same
      engine protocol and arguments, with the package where the cartridge goes). Any firmware,
      including binary-only ones; slower.

  This module knows the bundled native cartridges; `FMutate.Library` extends the list with downloaded and
  imported packages (emulator backend) and is what the rest of the app should ask (`get/1` and `all/0`
  delegate to it when it runs).
  """

  @enforce_keys [:id, :name, :version, :author, :license]
  defstruct [:id, :name, :version, :author, :license, :about, backend: :native, package: nil, caps: %{}]

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

  @doc "The firmwares shipped as native cartridges in this build."
  @spec bundled() :: [t]
  def bundled, do: Enum.map(@bundled, &struct!(__MODULE__, &1))

  @doc "Every firmware the app knows (the library's list when it runs, else the bundled ones)."
  @spec all() :: [t]
  def all do
    # (the library is a process the app starts; when it isn't running, the bundled list is all there is)
    if Process.whereis(FMutate.Library), do: apply(FMutate.Library, :firmwares, []), else: bundled()
  end

  @spec get(String.t()) :: t | nil
  def get(id), do: Enum.find(all(), &(&1.id == id))

  @doc "The default firmware on first run."
  def default_id, do: "obervave"

  @doc """
  How to run a firmware: `{engine_executable, firmware_file}` for `FMutate.Engine`, or nil when it can't
  run here (no cartridge in this build, no package on the phone, or no emulator engine).
  """
  @spec runnable(String.t()) :: {String.t(), String.t()} | nil
  def runnable(id) do
    case get(id) do
      %{backend: :native} ->
        with cart when cart != nil <- FMutate.Paths.bundled_cart(id), do: {FMutate.Paths.engine_bin(), cart}

      %{backend: :emu, package: pkg} when is_binary(pkg) ->
        emu = FMutate.Paths.emu_bin()
        if File.exists?(emu) and File.exists?(pkg), do: {emu, pkg}

      _ ->
        nil
    end
  end
end
