defmodule FMutate.Library.Description do
  @moduledoc """
  A firmware's fuller description for its synth page (`FMutate.FirmwareScreen`): the README of its repository at
  the git ref its build or package comes from (`FMutate.Firmware` `repo` and `ref`), and the Hub's card picture.
  Both are their makers' (the page says whose and links the repository).

  Where the text comes from, first that works:

    1. the README read now from the repository's host: `raw.githubusercontent.com/<owner>/<name>/<ref>/README.md`
       (`Readme.md`, `readme.md`, `README` when that is missing; the default branch when the catalogue pins no ref), HTTPS through
       `FMutate.Library.HTTP`, at most 512 KB. Cached per repository and ref under `FMutate.Paths.descriptions_dir/0`
       with its `ETag` and `Last-Modified`, so reading it again is a conditional GET that a 304 answers;
    2. that cached copy, when the host can't be reached (offline): `status: :cached` with when it was read;
    3. nothing (`:missing`, or `:none` without a GitHub repository, e.g. an imported package): the page shows the
       Hub's card text (`about`) or a plain note.

  The README is untrusted text and only ever becomes `FMutate.Library.Readme` blocks. A test points
  `:fmutate_app, :readme_base` (default `"https://raw.githubusercontent.com/"`) at a local server.
  """

  alias FMutate.{Firmware, Paths}
  alias FMutate.Library.{HTTP, Readme}

  @max 524_288
  @picture_max 2_097_152
  @files ["README.md", "Readme.md", "readme.md", "README"]
  @extensions ~w(.webp .png .jpg .jpeg .gif)

  @typedoc "A GitHub repository (`owner/name`) and the ref to read it at (nil: the default branch)."
  @type source :: %{repo: String.t(), ref: String.t() | nil}

  @typedoc """
  What the page shows: `status` `:fresh` (read or confirmed by the host now), `:cached` (the host couldn't be
  reached: the copy read at `fetched_at`), `:missing` (no README read, none cached; `error` says why) or `:none`
  (no repository to read); `readme` the blocks; `file` the README's name in the repository.
  """
  @type t :: %{
          status: :fresh | :cached | :missing | :none,
          readme: Readme.t() | nil,
          fetched_at: integer | nil,
          source: source | nil,
          file: String.t() | nil,
          error: term
        }

  @doc "Where a firmware's README is: its GitHub repository and ref, or nil (no repository, or not GitHub's)."
  @spec source(Firmware.t()) :: source | nil
  def source(%Firmware{repo: "https://github.com/" <> path, ref: ref}) do
    path = path |> String.trim_trailing("/") |> String.replace_suffix(".git", "")

    if path =~ ~r"\A[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}\z" and
         not String.ends_with?(path, "/..") and
         not String.ends_with?(path, "/."),
       do: %{repo: path, ref: valid_ref(ref)}
  end

  def source(_fw), do: nil

  defp valid_ref(ref) when is_binary(ref) do
    if ref =~ ~r"\A[A-Za-z0-9._+-][A-Za-z0-9._/+-]{0,199}\z" and not String.contains?(ref, ".."),
      do: ref
  end

  defp valid_ref(_ref), do: nil

  @doc "The README on the web, for \"Read the full README\" (at the ref; the repository's page without one)."
  @spec page_url(source, String.t() | nil) :: String.t()
  def page_url(src, file \\ nil)
  def page_url(%{repo: repo, ref: nil}, _file), do: "https://github.com/#{repo}#readme"

  def page_url(%{repo: repo, ref: ref}, file),
    do: "https://github.com/#{repo}/blob/#{ref}/#{file || hd(@files)}"

  @doc "What is on the phone for a firmware, without the network: the cached README (`:cached`), or nil."
  @spec cached(Firmware.t()) :: t | nil
  def cached(fw) do
    with src when src != nil <- source(fw),
         {body, meta} <- read_cache(src),
         do: result(:cached, body, meta, src, fw, nil)
  end

  @doc """
  Read the firmware's README (conditionally, when a copy is cached), cache it, and say what to show (see the
  module doc). Blocks on the network: call it from a task (`Mob.Socket.start_async/3`).
  """
  @spec load(Firmware.t()) :: t
  def load(fw) do
    case source(fw) do
      nil -> empty(:none, nil, nil)
      src -> load(fw, src, read_cache(src))
    end
  end

  defp load(fw, src, cache) do
    case fetch(src, cache) do
      {:ok, body, headers, file} ->
        meta = %{
          etag: headers["etag"],
          last_modified: headers["last-modified"],
          fetched_at: System.os_time(:second),
          file: file
        }

        write_cache(src, body, meta)
        result(:fresh, body, meta, src, fw, nil)

      :not_modified ->
        {body, meta} = cache
        meta = %{meta | fetched_at: System.os_time(:second)}
        write_cache(src, nil, meta)
        result(:fresh, body, meta, src, fw, nil)

      {:error, reason} when cache != nil ->
        {body, meta} = cache
        result(:cached, body, meta, src, fw, reason)

      {:error, reason} ->
        empty(:missing, src, reason)
    end
  end

  defp result(status, body, meta, src, fw, error) do
    %{
      status: status,
      readme: Readme.extract(body, name: fw.name),
      fetched_at: meta.fetched_at,
      source: src,
      file: meta.file,
      error: error
    }
  end

  defp empty(status, src, error),
    do: %{status: status, readme: nil, fetched_at: nil, source: src, file: nil, error: error}

  # the cached file's name first (with its validators), then the others; a 404 tries the next name
  defp fetch(src, cache) do
    {first, validators} =
      case cache do
        {_body, meta} -> {meta.file, validators(meta)}
        nil -> {hd(@files), []}
      end

    [first | List.delete(@files, first)]
    |> Enum.with_index()
    |> Enum.reduce_while({:error, :not_found}, fn {file, i}, _ ->
      headers = if i == 0, do: validators, else: []

      case HTTP.get(readme_url(src, file), headers, max: @max) do
        {:ok, body, resp} -> {:halt, {:ok, body, resp, file}}
        {:error, {:http, 404}} -> {:cont, {:error, {:http, 404}}}
        other -> {:halt, other}
      end
    end)
  end

  defp validators(meta) do
    [{"if-none-match", meta.etag}, {"if-modified-since", meta.last_modified}]
    |> Enum.filter(&is_binary(elem(&1, 1)))
  end

  defp readme_url(%{repo: repo, ref: ref}, file), do: base() <> "#{repo}/#{ref || "HEAD"}/#{file}"

  defp base,
    do: Application.get_env(:fmutate_app, :readme_base, "https://raw.githubusercontent.com/")

  ## The cache: <key>.md (the README as read) and <key>.term (its validators, when, which file)

  defp key(%{repo: repo, ref: ref}),
    do:
      :crypto.hash(:sha256, "#{repo}@#{ref || "HEAD"}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

  defp read_cache(src) do
    path = Path.join(Paths.descriptions_dir(), key(src))

    with {:ok, body} <- File.read(path <> ".md"),
         {:ok, bin} <- File.read(path <> ".term"),
         %{fetched_at: _, file: _} = meta <- :erlang.binary_to_term(bin, [:safe]) do
      {body, meta}
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # (the body is nil when only the validators changed: a 304)
  defp write_cache(src, body, meta) do
    path = Path.join(Paths.descriptions_dir(), key(src))
    if body, do: write_atomic(path <> ".md", body)
    write_atomic(path <> ".term", :erlang.term_to_binary(meta))
  rescue
    # (a full phone: the page still shows what it read)
    File.Error -> :ok
  end

  defp write_atomic(path, data) do
    File.write!(path <> ".tmp", data)
    File.rename!(path <> ".tmp", path)
  end

  ## The Hub's card picture

  @doc "The firmware's card picture on the phone, if it was read before (no network); nil otherwise."
  @spec cached_picture(Firmware.t()) :: Path.t() | nil
  def cached_picture(%Firmware{picture: url}) when is_binary(url) do
    path = picture_path(url)
    if File.regular?(path), do: path
  end

  def cached_picture(_fw), do: nil

  @doc """
  The firmware's card picture as a file on the phone (read once: the Hub names each version of a picture
  apart), at most 2 MB; `:none` when the Hub has none.
  """
  @spec picture(Firmware.t()) :: {:ok, Path.t()} | :none | {:error, term}
  def picture(%Firmware{picture: url} = fw) when is_binary(url) do
    case cached_picture(fw) do
      nil -> fetch_picture(url)
      path -> {:ok, path}
    end
  end

  def picture(_fw), do: :none

  defp fetch_picture(url) do
    path = picture_path(url)

    with {:ok, body, _headers} <- HTTP.get(url, [], max: @picture_max) do
      write_atomic(path, body)
      {:ok, path}
    end
  rescue
    e in File.Error -> {:error, e.reason}
  end

  defp picture_path(url) do
    ext =
      url
      |> URI.parse()
      |> Map.get(:path, "")
      |> to_string()
      |> Path.extname()
      |> String.downcase()

    ext = if ext in @extensions, do: ext, else: ".img"
    hash = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower) |> binary_part(0, 32)
    Path.join(Paths.descriptions_dir(), "pic-" <> hash <> ext)
  end
end
