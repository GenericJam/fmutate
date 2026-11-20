# native/ios_cartridges.exs: the published iOS cartridges native/build_ios.sh links into the app
# (docs/decisions/2026-11-14-native-catalog.md "Packaging"), pinned in native/ios_cartridges.lock.
#
#   elixir native/ios_cartridges.exs lock <lock> <built-in id>...
#       Fetch the signed index (config/config.exs `:cartridges`: `index_url`, `public_key`), refuse it unless its
#       Ed25519 signature verifies with the app's key, it is schema 1 and engine ABI 1, and it is no older than the
#       lock's (an old index served again); then write the lock: its `generated` and, per firmware with an iOS
#       asset (the built-ins excepted: built from source, they win), one line per platform.
#   elixir native/ios_cartridges.exs fetch <lock> <platform> <cache dir>
#       The lock's cartridges for `platform` (ios-device, ios-sim) in `<cache dir>/<sha256>.a`: downloaded when
#       not there, kept only when size, SHA-256 and the asset's own signature (the app's key) check, and checked
#       again when already there. Prints `<id> <version> <file>` per cartridge. Fails on any download or check:
#       a build links exactly the pinned set.
#   elixir native/ios_cartridges.exs layout <link map>
#       Check a link (ld -map) of the published cartridges after native/build_ios.sh moved their data and BSS into
#       the shared sections __DATA,__fm1c_d / __fm1c_b between markers (section$start/end$__DATA$<its section>):
#       each cartridge's symbols there lie between its own markers, and no two cartridges' spans overlap. Fails
#       otherwise: the host would restore or zero another cartridge's globals.
#
# A lock line: `<id> <version> <platform> <sha256> <size> <sig> <url> <commit>` (`#` starts a comment).

defmodule IosCartridges do
  @schema 1
  @engine_abi 1
  @platforms ["ios-device", "ios-sim"]

  def main(["lock", lock | builtins]), do: lock(lock, builtins)

  def main(["fetch", lock, platform, cache]) when platform in @platforms,
    do: fetch(lock, platform, cache)

  def main(["layout", map]), do: layout(map)

  def main(_args) do
    IO.puts(
      :stderr,
      "usage: ios_cartridges.exs lock <lock> <built-in id>... | fetch <lock> <platform> <cache dir> | " <>
        "layout <link map>"
    )

    System.halt(64)
  end

  ## lock

  defp lock(lock, builtins) do
    config = config()
    body = get!(config[:index_url])
    sig = get!(config[:index_url] <> ".sig")
    index = verify_index!(body, sig, key(config))
    previous = if File.exists?(lock), do: read_lock(lock).generated

    if previous && older?(index["generated"], previous),
      do:
        fail!(
          "the index (generated #{index["generated"]}) is older than the lock's (#{previous})"
        )

    lines =
      for f <- Enum.sort_by(index["firmwares"], & &1["id"]),
          f["id"] not in builtins,
          platform <- @platforms,
          asset = get_in(f, ["assets", platform]),
          asset != nil do
        line!(f, platform, asset)
      end

    File.write!(lock, [header(), "generated #{index["generated"]}\n", Enum.map(lines, &[&1, ?\n])])

    ids = lines |> Enum.map(&hd(String.split(&1))) |> Enum.uniq() |> length()
    IO.puts(:stderr, "#{lock}: #{ids} cartridges from the index generated #{index["generated"]}")
  end

  defp header do
    """
    # native/ios_cartridges.lock (written by native/ios_cartridges.exs): the published iOS cartridges
    # native/build_ios.sh links into the app, pinned from the signed index of github.com/GenericJam/fmutate-cartridges
    # so a build is reproducible and a later index can't change it. Refresh: IOS_CARTRIDGES_REFRESH=1 sh
    # native/build_ios.sh. The built-ins (build_ios.sh CARTRIDGES, built from source) aren't listed.
    # <id> <version> <platform> <sha256> <size> <sig> <url> <commit>
    """
  end

  defp line!(f, platform, %{"url" => url, "sha256" => sha, "size" => size, "sig" => sig}) do
    fields = [
      f["id"],
      f["version"],
      platform,
      String.downcase(sha),
      to_string(size),
      sig,
      url,
      f["commit"] || "-"
    ]

    unless safe?(f["id"]) and safe?(f["version"]) and is_integer(size) and
             sha =~ ~r/\A[0-9a-fA-F]{64}\z/ and
             Enum.all?(
               fields,
               &(is_binary(&1) and &1 != "" and not String.contains?(&1, [" ", "\n", "\t"]))
             ),
           do:
             fail!(
               "the index's #{platform} asset of #{inspect(f["id"])} isn't one this build can pin"
             )

    Enum.join(fields, " ")
  end

  # ids and versions become file and C names (as FMutate.Cartridges)
  defp safe?(s), do: is_binary(s) and s =~ ~r/\A[A-Za-z0-9][\w.+-]*\z/

  defp verify_index!(body, sig, key) do
    sig = Base.decode64!(String.trim(sig))

    unless signed?(body, sig, key),
      do: fail!("the index's signature doesn't verify with the app's key")

    index = JSON.decode!(body)

    unless index["schema"] == @schema,
      do: fail!("index schema #{inspect(index["schema"])}, not #{@schema}")

    unless index["engine_abi"] == @engine_abi,
      do: fail!("index engine ABI #{inspect(index["engine_abi"])}, not #{@engine_abi}")

    unless is_list(index["firmwares"]) and is_binary(index["generated"]),
      do: fail!("the index has no firmwares")

    index
  end

  defp older?(new, current) do
    case {DateTime.from_iso8601(new), DateTime.from_iso8601(current)} do
      {{:ok, n, _}, {:ok, c, _}} ->
        DateTime.before?(n, c)

      _ ->
        fail!(
          "can't compare the index's generated #{inspect(new)} with the lock's #{inspect(current)}"
        )
    end
  end

  ## fetch

  defp fetch(lock, platform, cache) do
    File.mkdir_p!(cache)
    key = key(config())
    entries = for e <- read_lock(lock).entries, e.platform == platform, do: e

    entries
    |> Task.async_stream(&cached!(&1, cache, key),
      max_concurrency: 8,
      timeout: :infinity,
      ordered: true
    )
    |> Enum.zip(entries)
    |> Enum.each(fn {{:ok, path}, e} -> IO.puts("#{e.id} #{e.version} #{path}") end)
  end

  defp cached!(e, cache, key) do
    path = Path.join(cache, e.sha256 <> ".a")

    case File.exists?(path) && check(File.read!(path), e, key) do
      :ok ->
        path

      _ ->
        part = "#{path}.#{System.unique_integer([:positive])}.part"
        bin = get!(e.url)

        case check(bin, e, key) do
          :ok ->
            File.write!(part, bin)
            File.rename!(part, path)
            path

          {:error, what} ->
            fail!("#{e.id} #{e.version} #{e.platform} (#{e.url}): #{what} doesn't match the lock")
        end
    end
  end

  defp check(bin, e, key) do
    cond do
      byte_size(bin) != e.size -> {:error, "size"}
      Base.encode16(:crypto.hash(:sha256, bin), case: :lower) != e.sha256 -> {:error, "SHA-256"}
      not signed?(bin, Base.decode64!(e.sig), key) -> {:error, "signature"}
      true -> :ok
    end
  end

  defp read_lock(lock) do
    lines =
      for line <- File.read!(lock) |> String.split("\n"),
          line = String.trim(line),
          line != "" and not String.starts_with?(line, "#"),
          do: String.split(line)

    generated = Enum.find_value(lines, fn l -> match?(["generated", _], l) && List.last(l) end)

    entries =
      for l <- lines, not match?(["generated", _], l) do
        case l do
          [id, version, platform, sha, size, sig, url, commit] ->
            %{
              id: id,
              version: version,
              platform: platform,
              sha256: sha,
              size: String.to_integer(size),
              sig: sig,
              url: url,
              commit: commit
            }

          _ ->
            fail!("#{lock}: can't read #{inspect(Enum.join(l, " "))}")
        end
      end

    %{generated: generated, entries: entries}
  end

  ## layout

  @shared ["__fm1c_d", "__fm1c_b"]

  defp layout(map) do
    lines = map |> File.read!() |> String.split("\n")

    files =
      for l <- block(lines, "# Object files:"),
          [_, n, path] <- [Regex.run(~r/^\[\s*(\d+)\]\s+(.*)$/, l)],
          into: %{},
          do: {n, Path.basename(path)}

    sections =
      for l <- block(lines, "# Sections:"),
          [addr, size, "__DATA", name] <- [String.split(l, "\t")],
          name in @shared,
          do: {name, hex(addr), hex(addr) + hex(size)}

    symbols =
      for l <- block(lines, "# Symbols:"),
          [_, addr, size, n, name] <- [
            Regex.run(~r/^(0x[0-9A-Fa-f]+)\t(0x[0-9A-Fa-f]+)\t\[\s*(\d+)\] (.*)$/, l)
          ],
          do: {hex(addr), hex(size), n, name}

    in_section =
      for {name, lo, hi} <- sections,
          do: {name, Enum.filter(symbols, &(elem(&1, 0) in lo..(hi - 1)//1))}

    problems = for {name, syms} <- in_section, problem <- spans(name, syms, files), do: problem

    if sections == [] or problems != [] do
      Enum.each(problems, &IO.puts(:stderr, "  " <> &1))

      fail!(
        "#{map}: the cartridges' data and BSS aren't each between their own markers in #{inspect(@shared)}"
      )
    end

    counts =
      Enum.map_join(in_section, ", ", fn {name, syms} ->
        "#{name} #{Enum.count(syms, &String.starts_with?(elem(&1, 3), "section$start$"))}"
      end)

    IO.puts(:stderr, "layout: each cartridge's span its own (#{counts})")
  end

  # problems with one shared section's symbols: each object's between its own two markers, no two spans overlapping
  defp spans(section, symbols, files) do
    results =
      for {n, syms} <- Enum.group_by(symbols, &elem(&1, 2)),
          do: span(section, files[n] || "file #{n}", syms)

    spans = for {:ok, span} <- results, do: span
    problems = for {:error, problem} <- results, do: problem

    overlaps =
      spans
      |> Enum.sort()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn [{_, e1, f1}, {s2, _, f2}] ->
        if s2 < e1, do: ["#{section}: #{f1} and #{f2} overlap"], else: []
      end)

    problems ++ overlaps
  end

  # one object's symbols in a shared section: `{:ok, {start, end, file}}` when they lie between its markers
  defp span(section, file, syms) do
    {markers, rest} = Enum.split_with(syms, &String.starts_with?(elem(&1, 3), "section$"))
    start = for {a, _, _, "section$start$" <> _} <- markers, do: a
    stop = for {a, _, _, "section$end$" <> _} <- markers, do: a

    case {start, stop} do
      {[s], [e]} when s <= e ->
        case Enum.reject(rest, &inside?(&1, s, e)) do
          [] -> {:ok, {s, e, file}}
          outside -> {:error, "#{section}: #{file}: #{names(outside)} outside its markers"}
        end

      _ ->
        {:error,
         "#{section}: #{file}: not one start and one end marker (#{length(start)}, #{length(stop)})"}
    end
  end

  # (the end marker's own byte starts at e)
  defp inside?({a, size, _, _}, s, e), do: a >= s and (a == e or a + size <= e)

  defp names(syms), do: syms |> Enum.take(5) |> Enum.map_join(" ", &elem(&1, 3))

  # a block of a link map: the lines after its `# <title>` header (and its column header) to the next `# ` line
  defp block(lines, title) do
    lines
    |> Enum.drop_while(&(&1 != title))
    |> Enum.drop(1)
    |> Enum.drop_while(&String.starts_with?(&1, "# Address"))
    |> Enum.take_while(&(not String.starts_with?(&1, "#")))
  end

  defp hex("0x" <> h), do: String.to_integer(h, 16)

  ## common

  # the app's own configuration: one place for the index's URL and key
  defp config do
    path = Path.expand("../config/config.exs", __DIR__)

    Config.Reader.read!(path, env: :prod)[:fmutate_app][:cartridges] ||
      fail!("no :cartridges config in #{path}")
  end

  defp key(config) do
    case Base.decode64(config[:public_key] || "") do
      {:ok, <<_::binary-32>> = key} -> key
      _ -> fail!("no Ed25519 public key in the :cartridges config")
    end
  end

  defp signed?(data, sig, key), do: :crypto.verify(:eddsa, :none, data, sig, [key, :ed25519])

  defp get!(url) do
    case System.cmd("curl", ["-fsSL", "--retry", "3", "--max-time", "300", url],
           stderr_to_stdout: false
         ) do
      {body, 0} -> body
      {_, code} -> fail!("download failed (curl #{code}): #{url}")
    end
  end

  defp fail!(message) do
    IO.puts(:stderr, "ios_cartridges: " <> message)
    System.halt(1)
  end
end

IosCartridges.main(System.argv())
