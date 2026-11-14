defmodule FMutate.Library do
  @moduledoc """
  The firmware library (HANDOFF §9): what the app can run and where it comes from — the bundled native
  cartridges, the FM-1 Firmware Hub's catalogue, the native builds of Hub firmwares in the signed cartridge
  index (`FMutate.Cartridges`), and the packages and cartridges downloaded or imported onto the phone
  (`FMutate.Library.Catalog` merges them). `FMutate.Firmware.all/0` asks it.

  The Hub catalogue is cached under the data dir and the library works from the cache offline. The
  Hub's terms ask that the catalogue be read at most once a day, so a refresh only goes out when the
  cache is a day old (or missing). Downloads stream into `FMutate.Paths.packages_dir/0` and are kept
  only when their size, SHA-256 and package header check out.

  The cartridge index has no such limit: it is read at start and on every refresh, with `If-None-Match`,
  and cached in `FMutate.Paths.cartridges_dir/0` (`index.json`, `index.json.sig`, `etag`); an index that
  doesn't verify is refused and the last good one stays. A Hub firmware with a native build for this phone
  runs natively; Download fetches its cartridge (kept only when size, SHA-256 and signature check out; the
  id's older versions are deleted then). The builds the player has seen are `seen.term`; newer ones are
  `new` until the library screen has shown them.

  Subscribers get `{:library, :changed}` when the catalogue, a download or the packages change, and
  `{:library, {:new_natives, ids}}` when a fetched index brings native builds new since the last one.
  """

  use GenServer
  require Logger

  alias FMutate.{Cartridges, Firmware, Fwsc, Paths}
  alias FMutate.Library.{Catalog, HTTP}

  @day 24 * 3600

  defstruct hub: [],
            updated: nil,
            fetched_at: nil,
            refreshing: false,
            error: nil,
            # the verified cartridge index (decoded) and its ETag; the index's state for the screen
            index: nil,
            etag: nil,
            index_refreshing: false,
            index_error: nil,
            # %{id => version} of the native builds the player has seen (nil before the first index)
            seen: nil,
            notify: false,
            downloads: %{},
            tasks: %{},
            subscribers: %{},
            # the merged list (bundled, imported, Hub; Catalog.merge/4 stats ~200 package paths) with the packages
            # and cartridges directories' listings it was built from: rebuilt when the catalogue or a listing
            # changes, so a lookup costs two directory reads, not two hundred file stats
            firmwares: nil

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Every firmware: bundled, imported, then the Hub's (see `FMutate.Library.Catalog.merge/4`)."
  @spec firmwares() :: [Firmware.t()]
  def firmwares, do: GenServer.call(__MODULE__, :firmwares)

  @doc "One firmware by id, or nil."
  @spec get(String.t()) :: Firmware.t() | nil
  def get(id), do: GenServer.call(__MODULE__, {:get, id})

  @doc """
  The library's state for the screen: `updated` (the Hub catalogue's date), `fetched_at` (when it was
  last read from the Hub, Unix seconds), `refreshing`, `error` (the last failure, a string), `downloads`
  (`%{id => {bytes, total | nil}}`); for the cartridge index `index_generated` (its date, or nil),
  `index_refreshing`, `index_error`; and `notify_new_natives`.
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

  @doc "Subscribe the caller to `{:library, :changed}` and `{:library, {:new_natives, ids}}`."
  def subscribe, do: GenServer.call(__MODULE__, {:subscribe, self()})

  @doc """
  Fetch the cartridge index, and the Hub catalogue if the cached one is a day old (the Hub's limit), or
  `force`.
  """
  def refresh(force \\ false), do: GenServer.cast(__MODULE__, {:refresh, force})

  @doc """
  Download a Hub firmware onto the phone (progress through `info/0`): its native cartridge when it runs
  natively here, else its package.
  """
  def download(id), do: GenServer.call(__MODULE__, {:download, id})

  @doc "Delete a downloaded or imported package, or a downloaded cartridge."
  def delete(id), do: GenServer.call(__MODULE__, {:delete, id})

  @doc "Import a `.fwsc` (a picked file at `path`, named `filename`)."
  def import_package(path, filename), do: GenServer.call(__MODULE__, {:import, path, filename})

  @doc "The player has seen these firmwares' native builds: they are no longer `new`."
  @spec mark_seen([String.t()]) :: :ok
  def mark_seen(ids), do: GenServer.call(__MODULE__, {:mark_seen, ids})

  @doc "Whether new native builds found by a fetch are notified (`notify_new_natives/1`); persisted, off by default."
  @spec set_notify(boolean) :: :ok
  def set_notify(on?) when is_boolean(on?), do: GenServer.call(__MODULE__, {:set_notify, on?})

  @doc """
  The notification of new native builds, for a player who opted in (`set_notify/1`). FMutate has no
  notification plugin yet (mob_notify needs a screen's socket and Firebase wiring on Android), so it logs.
  """
  @spec notify_new_natives([Firmware.t()]) :: :ok
  def notify_new_natives(firmwares) do
    Logger.info("library: new native builds: #{Enum.map_join(firmwares, ", ", &"#{&1.name} #{&1.version}")}")
  end

  @doc "Whether this build carries the emulator engine (otherwise packages \"don't run here yet\")."
  def emu?, do: File.exists?(Paths.emu_bin())

  ## Server

  @impl true
  def init(_opts) do
    settings = read_term(settings_path()) || %{}
    state = %{load_cache(%__MODULE__{}) | notify: settings[:notify_new_natives] == true}
    # (the library starts before the instances: no engine is writing a flash file yet)
    state = load_index(state)
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
    info =
      state
      |> Map.take([:updated, :fetched_at, :refreshing, :error, :downloads, :index_refreshing, :index_error])
      |> Map.merge(%{index_generated: state.index && state.index["generated"], notify_new_natives: state.notify})

    {:reply, info, state}
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

        {job, kind} =
          if cart_download?(fw),
            do: {fn -> fetch_cart(fw.native, lib) end, :cart},
            else: {fn -> fetch_package(fw, lib) end, :package}

        task = Task.async(job)
        state = %{state | downloads: Map.put(state.downloads, id, {0, fw.size}), error: nil}
        {:reply, :ok, changed(%{state | tasks: Map.put(state.tasks, task.ref, {:download, id, kind})})}
    end
  end

  def handle_call({:delete, id}, _from, state) do
    reply =
      case Enum.find(firmwares(state), &(&1.id == id)) do
        %{backend: :native, source: :hub, cart: cart, native: %{bundled: nil} = n} when is_binary(cart) ->
          Cartridges.remove(Paths.cartridges_dir(), n.id, n.platform)

        %{package: path, source: s} when is_binary(path) and s in [:hub, :imported] ->
          File.rm(path)

        _ ->
          {:error, :not_on_phone}
      end

    {:reply, reply, changed(state)}
  end

  def handle_call({:import, path, filename}, _from, state) do
    case Catalog.import_file(path, filename, Paths.packages_dir()) do
      {:ok, fw} -> {:reply, {:ok, fw}, changed(state)}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:mark_seen, ids}, _from, state) do
    versions = Cartridges.versions(entries(state.index))
    seen = Map.merge(state.seen || %{}, Map.take(versions, ids))
    if seen != state.seen, do: write_term(seen_path(), seen)
    {:reply, :ok, %{state | seen: seen, firmwares: nil}}
  end

  def handle_call({:set_notify, on?}, _from, state) do
    write_term(settings_path(), %{notify_new_natives: on?})
    {:reply, :ok, changed(%{state | notify: on?})}
  end

  @impl true
  def handle_cast({:refresh, force}, state), do: {:noreply, state |> maybe_refresh(force) |> fetch_index()}

  @impl true
  def handle_info(:auto_refresh, state), do: {:noreply, state |> maybe_refresh(false) |> fetch_index()}

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
      task = Task.async(fn -> with {:ok, body, _} <- HTTP.get(Catalog.hub_url() <> "catalog.json"), do: {:ok, body} end)
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

  defp finish(:index, result, state), do: finish_index(result, %{state | index_refreshing: false})

  defp finish({:download, id, kind}, result, state) do
    state = %{state | downloads: Map.delete(state.downloads, id)}

    case result do
      :ok ->
        changed(state)

      {:error, reason} ->
        Logger.warning("library: download #{id}: #{inspect(reason)}")
        changed(%{state | error: "Download failed: #{describe(kind, reason)}."})
    end
  end

  defp describe(:package, :size), do: "the package isn't the size the Hub lists"
  defp describe(:package, :sha256), do: "the package doesn't match the Hub's checksum"
  defp describe(:package, :not_fwsc), do: "not an FM-1 package"
  defp describe(:cart, :size), do: "the cartridge isn't the size its index lists"
  defp describe(:cart, :sha256), do: "the cartridge doesn't match its index's checksum"
  defp describe(:cart, :signature), do: "the cartridge's signature doesn't check out"
  defp describe(_kind, {:http, status}), do: "the server answered #{status}"
  defp describe(_kind, _), do: "couldn't reach the server"

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

  defp firmwares(state), do: Catalog.merge(Firmware.bundled(), state.hub, Paths.packages_dir(), natives(state))

  defp cached(state) do
    names = {File.ls(Paths.packages_dir()), File.ls(Paths.cartridges_dir())}

    case state.firmwares do
      {^names, _list} -> state
      _ -> %{state | firmwares: {names, firmwares(state)}}
    end
  end

  ## The cartridge index

  defp entries(index), do: Cartridges.entries(index, Cartridges.platform())

  # this phone's native builds, where they are, and which the player hasn't seen
  defp natives(%{index: nil}), do: %{}

  defp natives(state) do
    entries = entries(state.index)
    fresh = Cartridges.fresh(entries, state.seen)

    entries
    |> Cartridges.resolve(Paths.cartridges_dir())
    |> Map.new(fn {id, n} -> {id, Map.put(n, :new, id in fresh)} end)
  end

  defp load_index(state) do
    with {:ok, body} <- File.read(index_path()),
         {:ok, sig} <- File.read(index_path() <> ".sig"),
         {:ok, index} <- Cartridges.verify_index(body, sig, Cartridges.public_key()) do
      etag = with {:ok, e} <- File.read(etag_path()), do: e, else: (_ -> nil)
      apply_index(%{state | seen: read_term(seen_path()), etag: etag}, index, :boot)
    else
      _ -> %{state | seen: read_term(seen_path())}
    end
  end

  defp fetch_index(%{index_refreshing: true} = state), do: state

  defp fetch_index(state) do
    case Cartridges.index_url() do
      nil ->
        state

      url ->
        etag = state.index && state.etag
        task = Task.async(fn -> get_index(url, etag) end)
        changed(%{state | index_refreshing: true, tasks: Map.put(state.tasks, task.ref, :index)})
    end
  end

  # (in a task) the index and its signature, verified
  defp get_index(url, etag) do
    case HTTP.get(url, if(etag, do: [{"if-none-match", etag}], else: [])) do
      {:ok, body, headers} ->
        with {:ok, sig, _} <- HTTP.get(url <> ".sig"),
             {:ok, index} <- Cartridges.verify_index(body, sig, Cartridges.public_key()),
             do: {:ok, index, body, sig, headers["etag"]}

      other ->
        other
    end
  end

  defp finish_index(:not_modified, state), do: changed(%{state | index_error: nil})

  defp finish_index({:ok, index, body, sig, etag}, state) do
    write_atomic(index_path(), body)
    write_atomic(index_path() <> ".sig", sig)
    if etag, do: write_atomic(etag_path(), etag), else: File.rm(etag_path())
    changed(apply_index(%{state | etag: etag, index_error: nil}, index, :fetch))
  end

  defp finish_index({:error, reason}, state) when reason in [:signature, :json, :schema, :engine_abi] do
    Logger.warning("library: cartridge index refused: #{reason}")
    changed(%{state | index_error: "The native builds' list didn't verify; the last good one stays."})
  end

  defp finish_index({:error, reason}, state) do
    Logger.warning("library: cartridge index: #{inspect(reason)}")
    changed(%{state | index_error: "Couldn't read the native builds' list (offline?)."})
  end

  # a verified index: the first ever seen has nothing new; a fetched one announces the builds new since
  # the last index and the player's last look; ids now running natively take their emulator saves along
  defp apply_index(state, index, at) do
    versions = Cartridges.versions(entries(index))
    before = if state.index, do: Cartridges.versions(entries(state.index)), else: state.seen

    seen =
      if state.seen == nil do
        write_term(seen_path(), versions)
        versions
      else
        state.seen
      end

    state = %{state | index: index, seen: seen, firmwares: nil}
    move_flash(state, at)

    announce =
      if at == :fetch and before != nil,
        do: for({id, v} <- Enum.sort(versions), before[id] != v and seen[id] != v, do: id),
        else: []

    if announce != [], do: announce(state, announce)
    state
  end

  defp announce(state, ids) do
    for {pid, _} <- state.subscribers, do: send(pid, {:library, {:new_natives, ids}})

    if state.notify do
      fws = Enum.filter(firmwares(state), &(&1.id in ids and &1.backend == :native))
      if fws != [], do: notify_new_natives(fws)
    end
  end

  # at start no engine runs; after a fetch an instance may be running the id in the emulator (its engine
  # rewrites the file): that instance's saves move at the next start
  defp move_flash(state, at) do
    flash = Path.join(Paths.data_dir(), "flash")

    for {id, n} <- natives(state), Cartridges.native?(n) do
      skip = if at == :fetch, do: for(i <- instances(flash), current_firmware(i) == id, do: i), else: []

      for path <- Cartridges.move_emu_flash(flash, id, skip),
          do: Logger.info("library: #{id} runs natively now; its emulator saves are #{Catalog.hub_id(id)}'s (#{path})")
    end
  end

  defp instances(flash) do
    case File.ls(flash) do
      {:ok, names} -> names
      _ -> []
    end
  end

  defp current_firmware(instance), do: (read_term(Paths.instance_state(instance)) || %{})[:firmware]

  defp cart_download?(fw),
    do: fw.backend == :native and fw.native != nil and fw.native.bundled == nil and Cartridges.downloadable?(fw.native.platform)

  defp index_path, do: Path.join(Paths.cartridges_dir(), "index.json")
  defp etag_path, do: Path.join(Paths.cartridges_dir(), "etag")
  defp seen_path, do: Path.join(Paths.cartridges_dir(), "seen.term")
  defp settings_path, do: Path.join(Paths.cartridges_dir(), "settings.term")

  defp read_term(path) do
    case File.read(path) do
      {:ok, bin} -> :erlang.binary_to_term(bin, [:safe])
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp write_term(path, term), do: write_atomic(path, :erlang.term_to_binary(term))

  defp write_atomic(path, data) do
    File.write!(path <> ".tmp", data)
    File.rename!(path <> ".tmp", path)
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

  defp fetch_cart(native, lib) do
    dir = Paths.cartridges_dir()
    part = Path.join(dir, Cartridges.file_name(native) <> ".part")
    progress = fn got, total -> send(lib, {:progress, native.id, got, total}) end

    with :ok <- HTTP.download(native.url, part, progress),
         {:ok, _path} <- Cartridges.install(part, native, dir, Cartridges.public_key()) do
      :ok
    else
      error ->
        File.rm(part)
        error
    end
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
