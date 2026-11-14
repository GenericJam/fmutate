defmodule FMutate.Library.Catalog do
  @moduledoc """
  The library's catalogue, as pure functions over its sources (HANDOFF §9):

    * the bundled native cartridges (`FMutate.Firmware.bundled/0`),
    * the FM-1 Firmware Hub's catalogue (thefirmwarehub.com `catalog.json`; fm1-emu's
      `tools/hub_catalog.mjs` reads the same file): every firmware with a package,
    * the native builds of Hub firmwares in the signed cartridge index (`FMutate.Cartridges`), with their
      cartridges of the build or downloaded,
    * the packages on the phone, under `FMutate.Paths.packages_dir/0`: a Hub package downloaded as
      its Hub file name (`<id>-<version>.fwsc`), an imported one under `imported/`.

  A firmware with a native cartridge stays `:native` when the Hub lists it too (it takes the Hub's
  tags and repository), and the Hub's package of it is listed as well, as `hub:<id>` ("<name> (Hub
  package)"), so the two can be compared: an id names one backend only, and so one flash file (see
  `FMutate.Paths.flash/3`). Everything else runs in the emulator (`backend: :emu`), and has a
  `package` only when its file is on the phone.
  """

  alias FMutate.{Cartridges, Firmware, Fwsc}

  @hub "https://thefirmwarehub.com/"

  @typedoc """
  What a card says about a firmware: `:running` (the current one), `:quarantined` (crashed twice;
  Run anyway), `:on_phone` (runs from the phone), `:available` (on the Hub, download it),
  `:not_yet` (on the phone but this build has no emulator engine to run it).
  """
  @type status :: :running | :quarantined | :on_phone | :available | :not_yet

  @doc "The Hub's base URL (packages are relative to it)."
  def hub_url, do: @hub

  @doc "The Hub catalogue (decoded `catalog.json`) as firmwares: those with a package, in its order."
  @spec parse_hub(map) :: [Firmware.t()]
  def parse_hub(%{"firmwares" => list}) when is_list(list) do
    for %{"id" => id, "pkg" => pkg} = h <- list, is_binary(id) and is_binary(pkg) do
      %Firmware{
        id: id,
        name: h["name"] || id,
        version: package_version(id, pkg) || to_string(h["version"] || "?"),
        author: h["author"] || "?",
        license: h["lic"] || "see the repository",
        about: h["what"],
        backend: :emu,
        source: :hub,
        tags: hub_tags(h),
        url: URI.merge(@hub, pkg) |> to_string(),
        size: h["size"],
        sha256: h["sha256"],
        repo: repo(h)
      }
    end
  end

  def parse_hub(_), do: []

  defp hub_tags(h) do
    kinds = List.wrap(h["kind"]) |> Enum.filter(&is_binary/1)
    flags = for {key, tag} <- [{"vintage", "vintage"}, {"ambient", "ambient"}, {"beta", "beta"}], h[key] == true, do: tag
    Enum.uniq(kinds ++ flags)
  end

  defp repo(%{"repo" => r}) when is_binary(r) and r != "", do: "https://github.com/" <> r
  defp repo(h), do: h["site"]

  @doc """
  A Hub package's version from its file name, `<id>-<version>.fwsc` (a `+build` suffix dropped), as
  fm1-emu's `packageVersion`; nil when the name is not of that form.
  """
  @spec package_version(String.t(), String.t()) :: String.t() | nil
  def package_version(id, pkg) do
    base = pkg |> Path.basename() |> Path.rootname(".fwsc")

    if String.starts_with?(base, id <> "-") do
      base |> binary_part(byte_size(id) + 1, byte_size(base) - byte_size(id) - 1) |> String.replace(~r/\+[0-9a-f]+$/, "")
    end
  end

  @doc """
  Name and version from an imported package's file name (the package itself carries neither):
  `my-fork-1.2.fwsc` → `{"my-fork", "1.2"}`, `FM-1.fwsc` → `{"FM-1", nil}`.
  """
  @spec name_from_filename(String.t()) :: {String.t(), String.t() | nil}
  def name_from_filename(file) do
    base = file |> Path.basename() |> Path.rootname(".fwsc")

    case Regex.run(~r/^(.+?)[-_ ]v?(\d+(?:\.\d+)+[\w.+-]*)$/, base) do
      [_, name, version] -> {name, version}
      _ -> {base, nil}
    end
  end

  @doc "Where a Hub firmware's package goes on the phone."
  @spec hub_package_path(Firmware.t(), Path.t()) :: Path.t()
  def hub_package_path(%Firmware{url: url}, dir), do: Path.join(dir, Path.basename(URI.parse(url).path))

  @doc "The directory imported packages are copied into."
  def imported_dir(dir), do: Path.join(dir, "imported")

  @doc """
  The whole catalogue: bundled first, then imported packages, then the Hub's. A native cartridge wins
  over the Hub's entry of the same id; that entry stays in the Hub's place as `hub:<id>`.

  `natives` are the cartridge index's entries for this phone (`FMutate.Cartridges.resolve/3`, with `new`). A
  Hub firmware with one that runs here becomes `backend: :native` in the Hub's place, with the entry as
  `native` and its cartridge as `cart` (of the build, else the downloaded file, else nil: Download), followed
  by its Hub package as `hub:<id>`; an entry without a Hub firmware is listed after the Hub's. The bundled
  firmwares ignore the index. On iOS an entry that isn't linked into the app stays `:emu` with `native` set.
  """
  @spec merge([Firmware.t()], [Firmware.t()], Path.t(), %{String.t() => map}) :: [Firmware.t()]
  def merge(bundled, hub, dir, natives \\ %{}) do
    hub_by_id = Map.new(hub, &{&1.id, &1})

    statics =
      for fw <- bundled do
        case hub_by_id[fw.id] do
          nil -> fw
          h -> %{fw | tags: h.tags, repo: h.repo}
        end
      end

    static_by_id = Map.new(statics, &{&1.id, &1})
    natives = Map.drop(natives, Map.keys(static_by_id))

    hubs =
      Enum.flat_map(hub, fn h ->
        cond do
          native = static_by_id[h.id] ->
            [with_package(hub_variant(h, native), dir)]

          (n = natives[h.id]) && Cartridges.native?(n) ->
            fw = native_firmware(h, n)
            [fw, with_package(hub_variant(h, fw), dir)]

          n = natives[h.id] ->
            [with_package(%{h | native: n}, dir)]

          true ->
            [with_package(h, dir)]
        end
      end)

    index_only =
      for {id, n} <- Enum.sort(natives), not Map.has_key?(hub_by_id, id), Cartridges.native?(n),
          do: native_firmware(index_firmware(n), n)

    statics ++ imported(dir) ++ hubs ++ index_only
  end

  defp with_package(h, dir) do
    path = hub_package_path(h, dir)
    if File.regular?(path), do: %{h | package: path}, else: h
  end

  defp native_firmware(h, n) do
    %{
      h
      | backend: :native,
        version: n.version,
        license: n.license || h.license,
        url: n.url,
        size: n.size,
        sha256: n.sha256,
        package: nil,
        native: n,
        cart: n.bundled || n.cart,
        new: n[:new] == true
    }
  end

  # a native build the Hub's catalogue (not read yet, or not listing it) has no entry for
  defp index_firmware(n) do
    repo = n.repo && "https://github.com/" <> n.repo
    author = if n.repo, do: n.repo |> String.split("/") |> hd(), else: "?"

    %Firmware{
      id: n.id,
      name: n.name,
      version: n.version,
      author: author,
      license: n.license || "see the repository",
      source: :hub,
      repo: repo
    }
  end

  @doc "The id the Hub's package of a firmware with a native cartridge goes by."
  @spec hub_id(String.t()) :: String.t()
  def hub_id(id), do: "hub:" <> id

  defp hub_variant(h, native) do
    %{
      h
      | id: hub_id(h.id),
        name: "#{h.name} (Hub package)",
        about: "The Hub's package, run in the emulator, to compare with the native #{native.name}. Its saves are its own."
    }
  end

  @doc """
  Whether a native firmware's downloaded cartridge is older than the index's build: Download again offers the
  update while the old one keeps running.
  """
  @spec update?(Firmware.t()) :: boolean
  def update?(%{backend: :native, native: %{bundled: nil, cart_version: v, version: latest}}) when is_binary(v),
    do: v != latest

  def update?(_fw), do: false

  @doc "The imported packages on the phone."
  @spec imported(Path.t()) :: [Firmware.t()]
  def imported(dir) do
    idir = imported_dir(dir)

    case File.ls(idir) do
      {:ok, files} ->
        for file <- Enum.sort(files), String.ends_with?(file, ".fwsc"), do: imported_entry(Path.join(idir, file))

      _ ->
        []
    end
  end

  defp imported_entry(path) do
    file = Path.basename(path)
    {name, version} = name_from_filename(file)

    %Firmware{
      id: "imported:" <> file,
      name: name,
      version: version || "—",
      author: "imported",
      license: "—",
      about: "Imported from #{file}.",
      backend: :emu,
      package: path,
      source: :imported,
      tags: ["imported"],
      size: File.stat!(path).size
    }
  end

  @doc """
  Copy a package into the imported packages, as `filename` (its name and version come from it).
  Refuses a file that isn't an FM-1 update package.
  """
  @spec import_file(Path.t(), String.t(), Path.t()) :: {:ok, Firmware.t()} | {:error, :not_fwsc | File.posix()}
  def import_file(src, filename, dir) do
    file = sanitize(filename)

    with true <- Fwsc.valid_file?(src) || {:error, :not_fwsc},
         idir = imported_dir(dir),
         :ok <- File.mkdir_p(idir),
         dest = Path.join(idir, file),
         {:ok, _} <- File.copy(src, dest <> ".part"),
         :ok <- File.rename(dest <> ".part", dest) do
      {:ok, imported_entry(dest)}
    end
  end

  defp sanitize(filename) do
    base = filename |> Path.basename() |> String.replace(~r/[^\w.+ -]/u, "_")
    if String.ends_with?(String.downcase(base), ".fwsc"), do: Path.rootname(base) <> ".fwsc", else: base <> ".fwsc"
  end

  @doc """
  A firmware's status. `ctx`: `current` (the running firmware's id), `quarantined` (ids), `emu?`
  (whether this build has the emulator engine).
  """
  @spec status(Firmware.t(), %{current: String.t() | nil, quarantined: [String.t()], emu?: boolean}) :: status
  def status(fw, ctx) do
    cond do
      fw.id in ctx.quarantined -> :quarantined
      fw.id == ctx.current -> :running
      fw.backend == :native and fw.source == :hub and fw.cart == nil -> :available
      fw.backend == :native -> :on_phone
      fw.package == nil -> :available
      ctx.emu? -> :on_phone
      true -> :not_yet
    end
  end

  @doc "Whether a firmware matches a search (name, author, tags, description; case-insensitive)."
  @spec matches?(Firmware.t(), String.t()) :: boolean
  def matches?(_fw, ""), do: true

  def matches?(fw, query) do
    q = String.downcase(query)
    hay = [fw.name, fw.author, fw.about | fw.tags]
    Enum.any?(hay, &(is_binary(&1) and String.contains?(String.downcase(&1), q)))
  end
end
