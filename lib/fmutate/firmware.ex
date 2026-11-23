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
    # download (`url`, `size` in bytes, `sha256`); its repository (`repo`, a URL) and the git ref this build
    # or package comes from (`ref`: a commit or tag; nil = the default branch), where its README is read
    # (`FMutate.Library.Description`); the Hub's card picture (`picture`, a URL); `note`: FMutate's own remark
    # on the card (the maker's text is `about`)
    source: :bundled,
    tags: [],
    url: nil,
    size: nil,
    sha256: nil,
    repo: nil,
    ref: nil,
    picture: nil,
    note: nil,
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
  # `repo` and `ref`: the source native/build_android.sh builds the cartridge from (keep the commits in step).
  @bundled [
    %{
      id: "obervave",
      name: "OberVave",
      version: "3.3.2",
      author: "zvenson",
      license: "GPL-3.0",
      about: "An 8-voice analog-style poly after the classic American polys of 1979-84.",
      repo: "https://github.com/zvenson/obervave",
      ref: "792535d23ef4265475b1c2f9895ca30e857fe596",
      caps: %{pitch_bend: true, octave_reset_both: true, note_pressure: true}
    },
    %{
      id: "shineon",
      name: "Shine On",
      version: "3.0.1",
      author: "zvenson",
      license: "GPL-3.0",
      about: "A string ensemble in the spirit of the late-70s machines.",
      repo: "https://github.com/zvenson/shineon",
      ref: "2f37738d690a628e0ae1d23d07ea5ee3eeda2de7",
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
        if FMutate.Paths.emu?() and File.exists?(pkg),
          do: %{engine: FMutate.Paths.emu_bin(), file: pkg, backend: :emu}

      _ ->
        nil
    end
  end

  defp downloaded_cart(%{cart: cart}) when is_binary(cart), do: if(File.exists?(cart), do: cart)
  defp downloaded_cart(_fw), do: nil

  @typedoc "Who a running build is (`build/2`): what a sound saved from it says."
  @type build :: %{
          id: String.t(),
          name: String.t(),
          version: String.t() | nil,
          commit: String.t() | nil,
          backend: :native | :emu
        }

  @doc """
  Who a run of firmware `id` from `run` (`runnable/1`'s answer, as it started) is. `version` is the build's: a
  downloaded native cartridge's own when the index has moved past it (`native.cart_version`), else the firmware's
  (on iOS already the linked cartridge's); `commit` when the build says (a bundled cartridge's pinned source, the
  index's entry when its version is the build's), else nil.
  """
  @spec build(String.t(), %{backend: :native | :emu, file: term}) :: build
  def build(id, %{backend: backend, file: file}) do
    case get(id) do
      nil ->
        %{id: id, name: id, version: nil, commit: nil, backend: backend}

      fw ->
        {version, commit} = build_version(fw, file)
        %{id: fw.id, name: fw.name, version: version, commit: commit, backend: backend}
    end
  end

  defp build_version(%__MODULE__{native: %{} = n} = fw, file) do
    version = if file == n[:cart] and is_binary(n[:cart_version]), do: n.cart_version, else: fw.version
    {version, if(version == n[:version], do: n[:commit])}
  end

  defp build_version(%__MODULE__{source: :bundled, ref: ref} = fw, _file), do: {fw.version, ref}
  defp build_version(fw, _file), do: {fw.version, nil}

  @doc """
  Whether a firmware runs natively from a cartridge this phone downloads and doesn't have yet: a Hub firmware
  gone native in the cartridge index (`FMutate.Library.download/1` fetches it).
  """
  @spec needs_cart?(t | nil) :: boolean
  def needs_cart?(%__MODULE__{backend: :native, native: %{bundled: nil, platform: platform}} = fw),
    do: downloaded_cart(fw) == nil and FMutate.Cartridges.downloadable?(platform)

  def needs_cart?(_fw), do: false
end
