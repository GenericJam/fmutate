defmodule FMutate.Firmware do
  @moduledoc """
  The firmwares this build can run, and how.

  Two backends run a firmware in an engine process (docs/engine_protocol.md):

    * `:native` — the firmware built from its source as a cartridge (`libcart_<id>.so` shipped in the
      APK, or for a Hub firmware one downloaded from the signed cartridge index, `FMutate.Cartridges`; run by
      `libfm1engine.so`). Fast and sample-exact; only for firmwares with source.
    * `:emu` — the firmware's own package (`.fwsc`) run in the fm1-emu emulator (`libfm1emu.so`, same
      engine protocol and arguments, with the package where the cartridge goes). Any firmware,
      including binary-only ones; slower.

  This module knows the bundled native cartridges; `FMutate.Library` extends the list with the Hub's
  firmwares (natively where the cartridge index has a build for this phone), downloaded and imported packages
  (emulator backend) and is what the rest of the app should ask (`get/1` and `all/0`
  delegate to it when it runs).
  """

  @enforce_keys [:id, :name, :version, :author, :license]
  defstruct [
    :id,
    :name,
    :version,
    :author,
    :license,
    :about,
    backend: :native,
    package: nil,
    caps: %{},
    # library: where it comes from (`:bundled | :hub | :imported`), its tags, and for a Hub package its
    # download (`url`, `size` in bytes, `sha256`) and repository
    source: :bundled,
    tags: [],
    url: nil,
    size: nil,
    sha256: nil,
    repo: nil,
    # a Hub firmware with a native build (`FMutate.Cartridges`): the index's entry for this platform, its
    # cartridge (downloaded or of the build; nil until downloaded), and whether the build is new since the
    # player last looked
    native: nil,
    cart: nil,
    new: false
  ]

  @type t :: %__MODULE__{}

  # `caps`: what the firmware does beyond plain notes, for bindings: `pitch_bend` (keyboard bend),
  # `octave_reset_both` (OCT− and OCT+ pressed together set its octave to 0), `note_pressure` (MIDI polyphonic
  # aftertouch sets a held note's level; FMutate's build of OberVave, native/patches/obervave). Unknown = false.
  @bundled [
    %{
      id: "obervave",
      name: "OberVave",
      version: "3.3.2",
      author: "zvenson",
      license: "GPL-3.0",
      about: "An 8-voice analog-style poly after the classic American polys of 1979-84.",
      caps: %{pitch_bend: true, octave_reset_both: true, note_pressure: true}
    },
    %{
      id: "shineon",
      name: "Shine On",
      version: "3.0.1",
      author: "zvenson",
      license: "GPL-3.0",
      about: "A string ensemble in the spirit of the late-70s machines.",
      caps: %{pitch_bend: true, octave_reset_both: true}
    }
  ]

  @doc "The firmwares shipped as native cartridges in this build."
  @spec bundled() :: [t]
  def bundled, do: Enum.map(@bundled, &struct!(__MODULE__, &1))

  @doc "Every firmware the app knows (the library's list when it runs, else the bundled ones)."
  @spec all() :: [t]
  def all do
    # (the library is a process the app starts; when it isn't running, the bundled list is all there is)
    if Process.whereis(FMutate.Library), do: FMutate.Library.firmwares(), else: bundled()
  end

  @spec get(String.t()) :: t | nil
  def get(id) do
    if Process.whereis(FMutate.Library),
      do: FMutate.Library.get(id),
      else: Enum.find(bundled(), &(&1.id == id))
  end

  @doc "The default firmware on first run."
  def default_id, do: "obervave"

  @doc """
  How to run a firmware: `%{engine: executable, file: cartridge_or_package, backend: :native | :emu}` for
  `FMutate.Engine` (the backend picks the flash file, `FMutate.Paths.flash/3`), or nil when it can't run
  here (no cartridge in this build or downloaded, no package on the phone, or no emulator engine).
  """
  @spec runnable(String.t()) :: %{engine: String.t(), file: String.t(), backend: :native | :emu} | nil
  def runnable(id) do
    case get(id) do
      %{backend: :native} = fw ->
        with cart when cart != nil <- FMutate.Paths.bundled_cart(id) || downloaded_cart(fw),
             do: %{engine: FMutate.Paths.engine_bin(), file: cart, backend: :native}

      %{backend: :emu, package: pkg} when is_binary(pkg) ->
        emu = FMutate.Paths.emu_bin()
        if File.exists?(emu) and File.exists?(pkg), do: %{engine: emu, file: pkg, backend: :emu}

      _ ->
        nil
    end
  end

  defp downloaded_cart(%{cart: cart}) when is_binary(cart), do: if(File.exists?(cart), do: cart)
  defp downloaded_cart(_fw), do: nil
end
