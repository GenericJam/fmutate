defmodule FMutate.Cartridges do
  @moduledoc """
  Native cartridges for FM-1 Firmware Hub firmwares, built and signed outside the app by
  [fmutate-cartridges](https://github.com/GenericJam/fmutate-cartridges): its signed index, which entries this
  phone runs natively, and the downloaded cartridge files. Pure except for the functions that read or write
  files in a directory they are given.

  The index (schema 1) is `index.json`, with `index.json.sig` beside it: base64 of the Ed25519 signature over
  the exact bytes, by the key in the `:cartridges` config (`public_key`, base64 of the raw 32 bytes). An index
  is used only when it verifies and is of schema 1 and engine ABI 1. Each firmware lists an asset per platform
  (`android-arm64-v8a`, `android-x86_64`, `android-armeabi-v7a`, `ios-device`, `ios-sim`) with its url, size,
  SHA-256 and own signature (same key, over the file's bytes); a download is kept only when all three check.
  A downloaded cartridge is `libcart_<id>-<version>-<platform>.so` in `FMutate.Paths.cartridges_dir/0`.

  iOS runs no downloaded native code: there only the cartridges linked into the app run natively
  (`FMutate.Paths.bundled_cart/1`), and an entry with an iOS asset that isn't linked plays emulated until an
  app update links it.
  """

  alias FMutate.Library.Catalog
  alias FMutate.Paths

  @schema 1
  @engine_abi 1

  @typedoc """
  One firmware's native build for this platform: the index's fields (`id`, `name`, `version`, `commit`,
  `license`, `repo`, `build`, `parity`, `updated`), its asset (`platform`, `url`, `size`, `sha256`, `sig`),
  and once resolved (`resolve/3`) where it is on the phone: `bundled` (a cartridge of the build, or nil),
  `cart` and `cart_version` (the downloaded file and its version, or nil).
  """
  @type entry :: %{required(atom) => term}

  @doc "The signed index's URL (nil: don't fetch)."
  def index_url, do: config(:index_url)

  @doc "The key cartridges and the index are signed with (raw 32 bytes), or nil when none is configured."
  def public_key do
    with b64 when is_binary(b64) <- config(:public_key),
         {:ok, key} <- Base.decode64(b64),
         do: key,
         else: (_ -> nil)
  end

  defp config(key), do: Application.get_env(:fmutate_app, :cartridges, [])[key]

  ## The index

  @doc """
  The decoded index when `sig` (the `.sig` file: base64 of the signature) verifies `body` against `key` and
  it is of the schema and engine ABI this app reads.
  """
  @spec verify_index(binary, binary, binary | nil) :: {:ok, map} | {:error, :signature | :json | :schema | :engine_abi}
  def verify_index(body, sig, key) do
    with :ok <- check(signed?(body, decode_sig(sig), key), :signature),
         {:ok, index} <- decode(body),
         :ok <- check(index["schema"] == @schema, :schema),
         :ok <- check(index["engine_abi"] == @engine_abi, :engine_abi),
         do: {:ok, index}
  end

  defp check(true, _error), do: :ok
  defp check(false, error), do: {:error, error}

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, %{"firmwares" => list} = index} when is_list(list) -> {:ok, index}
      _ -> {:error, :json}
    end
  end

  defp decode_sig(sig) do
    case Base.decode64(String.trim(sig)) do
      {:ok, raw} -> raw
      :error -> nil
    end
  end

  @doc "Whether `sig` (raw 64 bytes) is `key`'s Ed25519 signature of `data`."
  @spec signed?(binary, binary | nil, binary | nil) :: boolean
  def signed?(data, sig, key) when is_binary(sig) and is_binary(key) do
    :crypto.verify(:eddsa, :none, data, sig, [key, :ed25519])
  rescue
    # a key or signature of the wrong size
    _ in [ArgumentError, ErlangError] -> false
  end

  def signed?(_data, _sig, _key), do: false

  @doc "The index's firmwares that have an asset for `platform`, by id (none for an unknown platform)."
  @spec entries(map | nil, String.t() | nil) :: %{String.t() => entry}
  def entries(%{"firmwares" => list}, platform) when is_list(list) and is_binary(platform) do
    for %{"id" => id, "version" => version, "assets" => %{^platform => asset}} = f <- list,
        safe?(id) and safe?(version) and asset?(asset),
        into: %{} do
      {id,
       %{
         id: id,
         name: f["name"] || id,
         version: version,
         commit: f["commit"],
         license: f["license"],
         repo: f["repo"],
         build: f["build"],
         parity: f["parity"],
         updated: f["updated"],
         platform: platform,
         url: asset["url"],
         size: asset["size"],
         sha256: String.downcase(asset["sha256"]),
         sig: asset["sig"]
       }}
    end
  end

  def entries(_index, _platform), do: %{}

  # ids and versions become file names
  defp safe?(s), do: is_binary(s) and s =~ ~r/^[A-Za-z0-9][\w.+-]*$/

  defp asset?(%{"url" => url, "size" => size, "sha256" => sha, "sig" => sig}),
    do: is_binary(url) and is_integer(size) and is_binary(sha) and is_binary(sig)

  defp asset?(_), do: false

  ## This phone

  @doc """
  The asset key of this phone: the configured `:cartridges` `platform` (hosts, tests), else from the OS and
  CPU (`platform/2`); nil on a host without one.
  """
  @spec platform() :: String.t() | nil
  def platform, do: config(:platform) || platform(os(), to_string(:erlang.system_info(:system_architecture)))

  @doc "The asset key for an OS (`:android | :ios | :host`) and the BEAM's system architecture."
  @spec platform(atom, String.t()) :: String.t() | nil
  def platform(:android, arch) do
    cond do
      String.starts_with?(arch, "aarch64") -> "android-arm64-v8a"
      String.starts_with?(arch, "x86_64") -> "android-x86_64"
      String.starts_with?(arch, "arm") -> "android-armeabi-v7a"
      true -> nil
    end
  end

  def platform(:ios, arch), do: if(String.contains?(arch, "sim"), do: "ios-sim", else: "ios-device")
  def platform(_os, _arch), do: nil

  defp os do
    :mob_nif.platform()
  rescue
    _ in [UndefinedFunctionError, ErlangError] -> :host
  end

  @doc "Whether cartridges for `platform` can be downloaded (not on iOS, which runs only linked ones)."
  @spec downloadable?(String.t() | nil) :: boolean
  def downloadable?(platform), do: is_binary(platform) and not String.starts_with?(platform, "ios")

  @doc "Whether an entry runs natively here: a cartridge of the build, or one this platform can download."
  @spec native?(entry) :: boolean
  def native?(entry), do: entry.bundled != nil or downloadable?(entry.platform)

  ## Files

  @doc "A downloaded cartridge's file name."
  @spec file_name(entry) :: String.t()
  def file_name(%{id: id, version: version, platform: platform}), do: "libcart_#{id}-#{version}-#{platform}.so"

  @doc """
  Entries with where they are on the phone: `bundled` (`bundled_cart.(id)`, a cartridge of the build) and,
  where cartridges download, `cart` and `cart_version` (the file of the id in `dir`: this version's, else an
  older one, which keeps working until the update is downloaded).
  """
  @spec resolve(%{String.t() => entry}, Path.t(), (String.t() -> String.t() | nil)) :: %{String.t() => entry}
  def resolve(entries, dir, bundled_cart \\ &Paths.bundled_cart/1) do
    files = list(dir)
    ids = Map.keys(entries)

    Map.new(entries, fn {id, e} ->
      {cart, version} =
        if downloadable?(e.platform), do: downloaded(files, dir, e, ids), else: {nil, nil}

      {id, Map.merge(e, %{bundled: bundled_cart.(id), cart: cart, cart_version: version})}
    end)
  end

  defp downloaded(files, dir, e, ids) do
    current = file_name(e)

    if current in files do
      {Path.join(dir, current), e.version}
    else
      case files |> carts_of(e.id, e.platform, ids) |> List.last() do
        nil -> {nil, nil}
        {file, version} -> {Path.join(dir, file), version}
      end
    end
  end

  # `{file, version}` of an id's cartridges among `files`: not those of a longer id (`<id>-<more>`, known
  # from the index, or any whose "version" doesn't start with a digit, as the index's versions do)
  defp carts_of(files, id, platform, ids) do
    prefix = "libcart_#{id}-"
    suffix = "-#{platform}.so"
    longer = for o <- ids, String.starts_with?(o, id <> "-"), do: "libcart_#{o}-"

    for file <- Enum.sort(files),
        String.starts_with?(file, prefix) and String.ends_with?(file, suffix),
        not String.starts_with?(file, longer),
        version = binary_part(file, byte_size(prefix), byte_size(file) - byte_size(prefix) - byte_size(suffix)),
        version =~ ~r/^\d/,
        do: {file, version}
  end

  defp list(dir) do
    case File.ls(dir) do
      {:ok, files} -> files
      _ -> []
    end
  end

  @doc """
  Keep a downloaded cartridge (`part`) as the entry's file in `dir` when its size, SHA-256 and signature check
  out, and delete the id's other versions; otherwise delete it.
  """
  @spec install(Path.t(), entry, Path.t(), binary | nil) ::
          {:ok, Path.t()} | {:error, :size | :sha256 | :signature | File.posix()}
  def install(part, entry, dir, key) do
    dest = Path.join(dir, file_name(entry))

    with :ok <- verify_asset(part, entry, key),
         :ok <- File.rename(part, dest) do
      for {file, _} <- carts_of(list(dir), entry.id, entry.platform, []),
          Path.join(dir, file) != dest,
          do: File.rm(Path.join(dir, file))

      {:ok, dest}
    else
      error ->
        File.rm(part)
        error
    end
  end

  @doc "Whether a downloaded file is the entry's asset: its size, SHA-256 and signature."
  @spec verify_asset(Path.t(), entry, binary | nil) :: :ok | {:error, :size | :sha256 | :signature | File.posix()}
  def verify_asset(path, entry, key) do
    with {:ok, bin} <- File.read(path) do
      cond do
        byte_size(bin) != entry.size -> {:error, :size}
        Base.encode16(:crypto.hash(:sha256, bin), case: :lower) != entry.sha256 -> {:error, :sha256}
        not signed?(bin, decode_sig(entry.sig), key) -> {:error, :signature}
        true -> :ok
      end
    end
  end

  @doc "Delete every downloaded cartridge of an id for a platform."
  @spec remove(Path.t(), String.t(), String.t()) :: :ok
  def remove(dir, id, platform) do
    for {file, _} <- carts_of(list(dir), id, platform, []), do: File.rm(Path.join(dir, file))
    :ok
  end

  ## New since last seen

  @doc "The versions of entries, by id (what `seen` records)."
  @spec versions(%{String.t() => entry}) :: %{String.t() => String.t()}
  def versions(entries), do: Map.new(entries, fn {id, e} -> {id, e.version} end)

  @doc """
  The ids of entries new or updated since `seen` (`%{id => version}`); none before anything was seen (the
  first index ever loaded).
  """
  @spec fresh(%{String.t() => entry}, %{String.t() => String.t()} | nil) :: [String.t()]
  def fresh(_entries, nil), do: []
  def fresh(entries, seen), do: for({id, e} <- Enum.sort(entries), seen[id] != e.version, do: id)

  ## Saves

  @doc """
  When an id starts running natively, its emulator flash (`<flash_dir>/<instance>/emu/<id>.bin`) belongs to the
  Hub package, `hub:<id>`: move it to `emu/hub:<id>.bin` in every instance not in `skip`, unless that file
  exists. Returns the moved files' new paths.
  """
  @spec move_emu_flash(Path.t(), String.t(), [String.t()]) :: [Path.t()]
  def move_emu_flash(flash_dir, id, skip \\ []) do
    for instance <- list(flash_dir),
        instance not in skip,
        emu = Path.join([flash_dir, instance, "emu"]),
        src = Path.join(emu, "#{id}.bin"),
        dest = Path.join(emu, "#{Catalog.hub_id(id)}.bin"),
        File.regular?(src) and not File.exists?(dest),
        File.rename(src, dest) == :ok,
        do: dest
  end
end
