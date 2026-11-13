defmodule FMutate.Library do
  @moduledoc """
  The firmware library (HANDOFF §9): what the app can run and where it comes from — the bundled native
  cartridges, the FM-1 Firmware Hub's catalogue, and the packages downloaded or imported onto the
  phone (`FMutate.Library.Catalog` merges them). `FMutate.Firmware.all/0` asks it.

  The Hub catalogue is cached under the data dir and the library works from the cache offline. The
  Hub's terms ask that the catalogue be read at most once a day, so a refresh only goes out when the
  cache is a day old (or missing). Downloads stream into `FMutate.Paths.packages_dir/0` and are kept
  only when their size, SHA-256 and package header check out.

  Subscribers get `{:library, :changed}` when the catalogue, a download or the packages change.
  """

  use GenServer
  require Logger

  alias FMutate.{Firmware, Fwsc, Paths}
  alias FMutate.Library.{Catalog, HTTP}

  @day 24 * 3600

  defstruct hub: [],
            updated: nil,
            fetched_at: nil,
            refreshing: false,
            error: nil,
            downloads: %{},
            tasks: %{},
            subscribers: %{},
            # the merged list (bundled, imported, Hub; Catalog.merge/3 stats ~200 package paths) with the packages
            # directory's listing it was built from: rebuilt when the catalogue or that listing changes, so a lookup
            # costs one directory read, not two hundred file stats
            firmwares: nil

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Every firmware: bundled, imported, then the Hub's (see `FMutate.Library.Catalog.merge/3`)."
  @spec firmwares() :: [Firmware.t()]
  def firmwares, do: GenServer.call(__MODULE__, :firmwares)

  @doc "One firmware by id, or nil."
  @spec get(String.t()) :: Firmware.t() | nil
  def get(id), do: GenServer.call(__MODULE__, {:get, id})

  @doc """
  The library's state for the screen: `updated` (the Hub catalogue's date), `fetched_at` (when it was
  last read from the Hub, Unix seconds), `refreshing`, `error` (the last failure, a string), `downloads`
  (`%{id => {bytes, total | nil}}`).
  """
  def info, do: GenServer.call(__MODULE__, :info)

  @doc """
  What the screen says about checking the Hub while a check would be refused (the catalogue was read
  less than a day ago): "Checked today · next check after 14:05". Nil when a check would go out.
  `to_local` turns Unix seconds into the phone's local time.
  """
  @spec check_note(integer | nil, integer, (integer -> NaiveDateTime.t())) :: String.t() | nil
  def check_note(fetched_at, now, to_local \\ &local_time/1)
  def check_note(nil, _now, _to_local), do: nil

  def check_note(fetched_at, now, to_local) do
    next = fetched_at + @day

    if now < next do
      day = if NaiveDateTime.to_date(to_local.(fetched_at)) == NaiveDateTime.to_date(to_local.(now)), do: "today", else: "yesterday"
      "Checked #{day} · next check after #{Calendar.strftime(to_local.(next), "%H:%M")}"
    end
  end

  defp local_time(secs), do: secs |> :calendar.system_time_to_local_time(:second) |> NaiveDateTime.from_erl!()

  @doc "Subscribe the caller to `{:library, :changed}`."
  def subscribe, do: GenServer.call(__MODULE__, {:subscribe, self()})

  @doc "Fetch the Hub catalogue if the cached one is a day old (the Hub's limit), or `force`."
  def refresh(force \\ false), do: GenServer.cast(__MODULE__, {:refresh, force})

  @doc "Download a Hub firmware's package onto the phone (progress through `info/0`)."
  def download(id), do: GenServer.call(__MODULE__, {:download, id})

  @doc "Delete a downloaded or imported package."
  def delete(id), do: GenServer.call(__MODULE__, {:delete, id})

  @doc "Import a `.fwsc` (a picked file at `path`, named `filename`)."
  def import_package(path, filename), do: GenServer.call(__MODULE__, {:import, path, filename})

  @doc "Whether this build carries the emulator engine (otherwise packages \"don't run here yet\")."
  def emu?, do: Paths.emu?()

  ## Server

  @impl true
  def init(_opts) do
    state = load_cache(%__MODULE__{})
    send(self(), :auto_refresh)
    {:ok, state}
  end

  @impl true
  def handle_call(:hub, _from, state), do: {:reply, state.hub, state}

  def handle_call(:firmwares, _from, state) do
    %{firmwares: {_, list}} = state = cached(state)
    {:reply, list, state}
  end

  def handle_call({:get, id}, _from, state) do
    %{firmwares: {_, list}} = state = cached(state)
    {:reply, Enum.find(list, &(&1.id == id)), state}
  end

  def handle_call(:info, _from, state) do
    {:reply, Map.take(state, [:updated, :fetched_at, :refreshing, :error, :downloads]), state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, ref)}}
  end

  def handle_call({:download, id}, _from, state) do
    # by the catalogue's id: the Hub's package of a native firmware goes by `hub:<id>`
    case Enum.find(firmwares(state), &(&1.id == id and &1.source == :hub)) do
      nil ->
        {:reply, {:error, :unknown}, state}

      _fw when is_map_key(state.downloads, id) ->
        {:reply, :ok, state}

      fw ->
        lib = self()
        task = Task.async(fn -> fetch_package(fw, lib) end)
        state = %{state | downloads: Map.put(state.downloads, id, {0, fw.size}), error: nil}
        {:reply, :ok, changed(%{state | tasks: Map.put(state.tasks, task.ref, {:download, id})})}
    end
  end

  def handle_call({:delete, id}, _from, state) do
    reply =
      case Enum.find(firmwares(state), &(&1.id == id)) do
        %{package: path, source: s} when is_binary(path) and s in [:hub, :imported] -> File.rm(path)
        _ -> {:error, :not_on_phone}
      end

    {:reply, reply, changed(state)}
  end

  def handle_call({:import, path, filename}, _from, state) do
    case Catalog.import_file(path, filename, Paths.packages_dir()) do
      {:ok, fw} -> {:reply, {:ok, fw}, changed(state)}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_cast({:refresh, force}, state), do: {:noreply, maybe_refresh(state, force)}

  @impl true
  def handle_info(:auto_refresh, state), do: {:noreply, maybe_refresh(state, false)}

  def handle_info({:progress, id, got, total}, state) do
    if Map.has_key?(state.downloads, id) do
      {old, _} = state.downloads[id]
      state = %{state | downloads: Map.put(state.downloads, id, {got, total})}
      # tell the screen about every 2% (or 64 KiB without a length), not every chunk
      step = if total, do: max(div(total, 50), 1), else: 65_536
      {:noreply, if(div(got, step) != div(old, step), do: changed(state), else: state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({ref, result}, state) when is_map_key(state.tasks, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state.tasks[ref], result, %{state | tasks: Map.delete(state.tasks, ref)})}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, state) when is_map_key(state.tasks, ref) do
    {:noreply, finish(state.tasks[ref], {:error, reason}, %{state | tasks: Map.delete(state.tasks, ref)})}
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

  def handle_info(_msg, state), do: {:noreply, state}

  ## Catalogue

  defp maybe_refresh(%{refreshing: true} = state, _force), do: state

  defp maybe_refresh(state, force) do
    if force or stale?(state) do
      task = Task.async(fn -> HTTP.get(Catalog.hub_url() <> "catalog.json") end)
      changed(%{state | refreshing: true, error: nil, tasks: Map.put(state.tasks, task.ref, :catalog)})
    else
      state
    end
  end

  defp stale?(%{fetched_at: nil}), do: true
  defp stale?(%{fetched_at: t}), do: System.os_time(:second) - t >= @day

  defp finish(:catalog, {:ok, body}, state) do
    state = %{state | refreshing: false}

    case decode(body) do
      {:ok, json} ->
        File.write!(cache_path(), body)
        changed(%{from_json(state, json) | fetched_at: System.os_time(:second)})

      :error ->
        changed(%{state | error: "The Hub's catalogue didn't read."})
    end
  end

  defp finish(:catalog, {:error, reason}, state) do
    Logger.warning("library: Hub catalogue: #{inspect(reason)}")
    changed(%{state | refreshing: false, error: "Couldn't reach the Hub (offline?)."})
  end

  defp finish({:download, id}, result, state) do
    state = %{state | downloads: Map.delete(state.downloads, id)}

    case result do
      :ok ->
        changed(state)

      {:error, reason} ->
        Logger.warning("library: download #{id}: #{inspect(reason)}")
        changed(%{state | error: "Download failed: #{describe(reason)}."})
    end
  end

  defp describe(:size), do: "the package isn't the size the Hub lists"
  defp describe(:sha256), do: "the package doesn't match the Hub's checksum"
  defp describe(:not_fwsc), do: "not an FM-1 package"
  defp describe({:http, status}), do: "the Hub answered #{status}"
  defp describe(_), do: "couldn't reach the Hub"

  defp load_cache(state) do
    with {:ok, body} <- File.read(cache_path()),
         {:ok, json} <- decode(body),
         {:ok, stat} <- File.stat(cache_path(), time: :posix) do
      %{from_json(state, json) | fetched_at: stat.mtime}
    else
      _ -> state
    end
  end

  defp from_json(state, json), do: %{state | hub: Catalog.parse_hub(json), updated: json["updated"], firmwares: nil}

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, %{"firmwares" => _} = json} -> {:ok, json}
      _ -> :error
    end
  end

  defp cache_path, do: Path.join(Paths.data_dir(), "hub_catalog.json")

  defp firmwares(state), do: Catalog.merge(Firmware.bundled(), state.hub, Paths.packages_dir())

  defp cached(state) do
    names = File.ls(Paths.packages_dir())

    case state.firmwares do
      {^names, _list} -> state
      _ -> %{state | firmwares: {names, firmwares(state)}}
    end
  end

  ## Downloads (in a task)

  defp fetch_package(fw, lib) do
    dest = Catalog.hub_package_path(fw, Paths.packages_dir())
    part = dest <> ".part"
    progress = fn got, total -> send(lib, {:progress, fw.id, got, total}) end

    result =
      with :ok <- HTTP.download(fw.url, part, progress),
           :ok <- verify(fw, part),
           do: File.rename(part, dest)

    if result != :ok, do: File.rm(part)
    result
  end

  @doc false
  # size and checksum as the Hub lists them, then the package header
  def verify(fw, path) do
    cond do
      fw.size && File.stat!(path).size != fw.size -> {:error, :size}
      fw.sha256 && sha256(path) != String.downcase(fw.sha256) -> {:error, :sha256}
      not Fwsc.valid_file?(path) -> {:error, :not_fwsc}
      true -> :ok
    end
  end

  defp sha256(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp changed(state) do
    for {pid, _} <- state.subscribers, do: send(pid, {:library, :changed})
    %{state | firmwares: nil}
  end
end
