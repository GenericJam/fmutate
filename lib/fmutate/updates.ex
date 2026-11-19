defmodule FMutate.Updates do
  @moduledoc """
  Both ways FMutate updates itself (docs/decisions/2026-11-13-updates.md):

    * **the app** (native code: the engine, the Kotlin surface, Mob): a newer signed APK from the
      repository's GitHub Releases, through `MobAppUpdate`. Checked at launch at most once per
      `:launch_check_after` (the GitHub API allows 60 unauthenticated requests an hour) and on "Check
      now"; downloaded and handed to Android's installer only when the user taps Install, and Android
      asks again before installing.
    * **the code** (Elixir only): signed BEAMs over the air through `MobDeliver`, on this build's own
      channel (`<track>-<versionCode>`, `config :mob_deliver, :channel`). mob_deliver checks at launch
      and hourly by itself; an install applies at the next launch, and a launch that crashes before its
      first screen rolls the code back. The launch after a rollback shows it (the notice is taken at
      launch, so the next good launch doesn't).

  Subscribers (`subscribe/0`) get `{:updates, state}` on every change. State persists in
  `updates.term` (when the app was last checked, the newest release seen, the app version that last
  ran) as plain data: string keys and no atoms of its own, so a launch reads it before the modules that
  name a release's fields are loaded (`binary_to_term/2` with `:safe` refuses atoms that don't exist yet).
  """

  use GenServer

  require Logger

  alias FMutate.Paths

  @default_launch_check_after :timer.hours(12)

  @typedoc "Where the APK side is."
  @type app_status ::
          :idle
          | :checking
          | :up_to_date
          | {:available, map}
          | {:downloading, non_neg_integer, non_neg_integer | nil}
          | {:needs_permission, map}
          | {:confirm, map}
          | {:error, term}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The current state (see `t:app_status/0` for `:app`); a default before the server runs."
  def state do
    if GenServer.whereis(__MODULE__), do: GenServer.call(__MODULE__, :state), else: nil
  end

  @doc "Subscribe the caller to `{:updates, state}`; returns `{:ok, state}`."
  def subscribe, do: GenServer.call(__MODULE__, {:subscribe, self()})

  @doc "Check both now: the app on GitHub Releases and the code on the OTA channel."
  def check, do: GenServer.cast(__MODULE__, :check)

  @doc "Download the available APK (if not already downloaded) and hand it to Android's installer."
  def install, do: GenServer.cast(__MODULE__, :install)

  @doc "Open Android's 'Install unknown apps' page for FMutate (the first install asks for it)."
  def open_install_settings, do: client().open_install_settings()

  @doc """
  Whether a launch check is due: never checked, or the last successful check is at least `interval` ms
  old (or in the future: a clock that went back).
  """
  @spec due?(DateTime.t() | nil, DateTime.t(), non_neg_integer) :: boolean
  def due?(nil, _now, _interval), do: true

  def due?(%DateTime{} = last, %DateTime{} = now, interval) do
    age = DateTime.diff(now, last, :millisecond)
    age < 0 or age >= interval
  end

  ## Server

  @impl true
  def init(opts) do
    config = Keyword.merge(Application.get_env(:fmutate_app, :updates, []), opts)
    saved = load(config)
    installed = installed()

    # what the last check found, while it's still newer than this app (not once it's installed): offered again
    # at launch without asking GitHub before the interval is up
    release = newer(saved.release, installed)
    launch = launch(saved, installed)

    state = %{
      config: config,
      subscribers: %{},
      installed: installed,
      app: if(release, do: {:available, release}, else: :idle),
      release: release,
      checked_at: saved.checked_at,
      # the app version this launch replaced, when it differs from the last one that ran
      updated_from: launch.updated_from,
      # the outcome of the last code check this server asked for (mob_deliver also checks by itself)
      code_check: nil,
      # a rollback mob_deliver did at this launch's boot
      rollback: launch.rollback,
      apk: nil,
      task: nil
    }

    state = refresh_code(state)
    persist(state)
    if launch_check?(state), do: send(self(), :launch_check)
    {:ok, state}
  end

  # What this launch replaced (the app version) and rolled back (the code), worked out once per VM: both are gone
  # once read (updates.term is rewritten with this version, taking the notice clears it), and this server restarts
  # within the launch whenever an earlier child of FMutate.Supervisor does (rest_for_one).
  defp launch(saved, installed) do
    case :persistent_term.get({__MODULE__, :launch}, nil) do
      nil ->
        launch = %{
          updated_from: updated_from(saved.version_code, installed),
          rollback: code_client().take_rollback_notice()
        }

        :persistent_term.put({__MODULE__, :launch}, launch)
        launch

      launch ->
        launch
    end
  end

  @impl true
  def handle_call(:state, _from, state) do
    state = refresh_code(state)
    {:reply, public(state), state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    state = refresh_code(state)
    {:reply, {:ok, public(state)}, %{state | subscribers: Map.put(state.subscribers, ref, pid)}}
  end

  @impl true
  def handle_cast(:check, state), do: {:noreply, start_check(state, :both)}

  # Install again from :confirm too: Android's dialog can be lost (the activity went away) without an outcome
  def handle_cast(:install, %{app: {status, release}} = state) when status in [:available, :needs_permission, :confirm],
    do: {:noreply, start_install(state, release)}

  def handle_cast(:install, %{app: {:error, _}, release: %{} = release} = state), do: {:noreply, start_install(state, release)}
  def handle_cast(:install, state), do: {:noreply, state}

  @impl true
  def handle_info(:launch_check, state), do: {:noreply, start_check(state, :app)}

  # results of the work started below (one task at a time)
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> Map.put(:task, nil) |> finished(result) |> changed()}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}

  # progress from MobAppUpdate.download/2 and the installer's outcome from MobAppUpdate.install/2
  def handle_info({:mob_app_update, {:progress, got, total}}, state),
    do: {:noreply, changed(%{state | app: {:downloading, got, total}})}

  def handle_info({:mob_app_update, {:install, outcome}}, state), do: {:noreply, changed(installer(state, outcome))}

  def handle_info(_message, state), do: {:noreply, state}

  ## Checking

  defp launch_check?(state) do
    state.installed != nil and
      due?(state.checked_at, DateTime.utc_now(), Keyword.get(state.config, :launch_check_after, @default_launch_check_after))
  end

  defp start_check(%{task: %Task{}} = state, _what), do: state

  defp start_check(state, what) do
    opts = check_opts(state.config)
    client = client()
    changed(%{state | task: guarded_task(fn -> run_check(what, client, opts) end), app: :checking})
  end

  defp run_check(what, client, opts) do
    code = if what == :both, do: code_client().check(details: true)
    {:checked, code, client.check(opts)}
  end

  defp check_opts(config), do: Keyword.take(config, [:repo, :prerelease, :metadata_asset])

  defp finished(state, {:checked, code, app}) do
    state = refresh_code(%{state | code_check: code})

    case app do
      {:ok, :available, release} ->
        apk = same_apk(state, release)
        persist(%{state | app: {:available, release}, release: release, apk: apk, checked_at: now()})

      {:ok, :up_to_date, _} ->
        persist(%{state | app: :up_to_date, release: nil, apk: nil, checked_at: now()})

      # GitHub's answer that there's nothing to offer: a release seen before was withdrawn
      {:error, reason} when reason in [:no_release, :no_update_metadata, :not_found] ->
        persist(%{state | app: {:error, reason}, release: nil, apk: nil})

      {:error, {:package_mismatch, _, _} = reason} ->
        persist(%{state | app: {:error, reason}, release: nil, apk: nil})

      {:error, reason} ->
        %{state | app: {:error, reason}}
    end
  end

  # The session started. Android's outcome can arrive before this result (it's sent from the installer's own
  # thread): then it stands, and the APK it was about is gone.
  defp finished(%{app: {:downloading, _, _}} = state, {:installing, {:ok, path}, :ok}),
    do: %{state | apk: path, app: {:confirm, state.release}}

  defp finished(state, {:installing, {:ok, _path}, :ok}), do: state

  defp finished(state, {:installing, {:ok, path}, {:error, :install_permission_required}}),
    do: %{state | apk: path, app: {:needs_permission, state.release}}

  defp finished(state, {:installing, {:ok, path}, {:error, reason}}), do: %{state | apk: path, app: {:error, reason}}
  defp finished(state, {:installing, {:error, reason}, nil}), do: %{state | apk: nil, app: {:error, reason}}
  defp finished(state, {:crashed, reason}), do: %{state | app: {:error, {:crashed, reason}}}

  ## Installing

  defp start_install(%{task: %Task{}} = state, _release), do: state

  defp start_install(state, release) do
    client = client()
    server = self()
    # the APK an earlier tap downloaded (then the install permission was missing), if it's still there
    downloaded = if state.apk && File.regular?(state.apk), do: state.apk
    task = guarded_task(fn -> download_and_install(client, release, downloaded, server) end)
    changed(%{state | task: task, release: release, apk: downloaded, app: {:downloading, 0, release.apk.size}})
  end

  defp download_and_install(client, release, downloaded, server) do
    case downloaded || client.download(release, notify: server) do
      {:error, _} = error -> {:installing, error, nil}
      {:ok, path} -> {:installing, {:ok, path}, client.install(path, notify: server)}
      path -> {:installing, {:ok, path}, client.install(path, notify: server)}
    end
  end

  # A task is linked to this server: an exception in it (a network library's, a plugin's) is an error to show,
  # not a crash that takes the server down, restarts it and checks again at once.
  defp guarded_task(fun), do: Task.async(fn -> guarded(fun) end)

  defp guarded(fun) do
    fun.()
  catch
    kind, reason ->
      Logger.error("updates: " <> Exception.format(kind, reason, __STACKTRACE__))
      {:crashed, Exception.format_banner(kind, reason, __STACKTRACE__)}
  end

  # the downloaded APK still belongs to the release a check found (it's the same file), else nothing
  defp same_apk(%{apk: apk, release: %{apk: %{sha256: sha}}}, %{apk: %{sha256: sha}}), do: apk
  defp same_apk(_state, _release), do: nil

  # Android replaces the app (and stops this process) on success, so :success is rarely seen here
  defp installer(state, :pending_user_action), do: %{state | app: {:confirm, state.release}}
  defp installer(state, :success), do: %{state | app: :idle, apk: nil}

  defp installer(state, {:failure, status, message}),
    do: %{state | app: {:error, {:install_failed, status, message}}, apk: nil}

  ## State

  defp public(state),
    do: Map.take(state, [:installed, :app, :release, :checked_at, :updated_from, :code])

  defp changed(state) do
    message = {:updates, public(state)}
    for {_ref, pid} <- state.subscribers, do: send(pid, message)
    state
  end

  # mob_deliver's state now (it checks at boot and on its own interval too), with this server's last code check
  # and the rollback this launch took
  defp refresh_code(state) do
    code = %{
      state: code_client().state(),
      modules: delivered_modules(),
      check: state.code_check,
      rollback: state.rollback,
      channel: Application.get_env(:mob_deliver, :channel)
    }

    Map.put(state, :code, code)
  end

  # How many modules the active manifest delivers: 0 for an empty one (published to take devices back to the APK's
  # own code: mob_deliver still reports it as active), nil while mob_deliver's store isn't up.
  defp delivered_modules do
    if Process.whereis(MobDeliver.Store) do
      case MobDeliver.Store.active(MobDeliver.Store) do
        {_id, %{modules: modules}} -> map_size(modules)
        nil -> 0
      end
    end
  rescue
    # its table went away meanwhile
    ArgumentError -> nil
  end

  defp installed do
    case client().installed() do
      {:ok, installed} -> installed
      {:error, _} -> nil
    end
  end

  defp newer(%{version_code: code, package: package} = release, %{version_code: installed, package: package})
       when code > installed,
       do: release

  defp newer(_release, _installed), do: nil

  defp updated_from(nil, _installed), do: nil
  defp updated_from(_code, nil), do: nil
  defp updated_from(code, %{version_code: now}) when code < now, do: code
  defp updated_from(_code, _installed), do: nil

  defp client, do: Application.get_env(:fmutate_app, :app_update_client, MobAppUpdate)
  defp code_client, do: Application.get_env(:fmutate_app, :code_client, MobDeliver)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  ## Persistence (updates.term)

  # Plain data only (string keys, strings, integers, booleans, nil). The release map's atom keys exist only once
  # mob_app_update's modules are loaded, which a launch hasn't done yet when it reads this file: with atoms in it,
  # `binary_to_term(bin, [:safe])` refuses the whole file and the launch forgets everything in it.

  defp file(config), do: Keyword.get_lazy(config, :file, fn -> Path.join(Paths.data_dir(), "updates.term") end)

  # an unreadable file, or one from an earlier format, is a first launch
  defp load(config) do
    with {:ok, bin} <- File.read(file(config)),
         {:ok, %{} = saved} <- safe_term(bin) do
      %{
        checked_at: decode_time(saved["checked_at"]),
        release: decode_release(saved["release"]),
        version_code: positive(saved["version_code"])
      }
    else
      _ -> %{checked_at: nil, release: nil, version_code: nil}
    end
  end

  defp safe_term(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    ArgumentError -> :error
  end

  defp persist(state) do
    saved = %{
      "checked_at" => encode_time(state.checked_at),
      "release" => encode_release(state.release),
      "version_code" => state.installed && state.installed.version_code
    }

    # a failed save costs a check too many at the next launch; it mustn't take the server (or its supervisor) down
    path = file(state.config)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, :erlang.term_to_binary(saved)) do
      :ok
    else
      {:error, reason} -> Logger.warning("updates: couldn't save #{path}: #{inspect(reason)}")
    end

    state
  end

  # the release map MobAppUpdate.check/1 returns (MobAppUpdate.Release.t()), field by field
  defp encode_release(nil), do: nil

  defp encode_release(r) do
    %{
      "tag" => r.tag,
      "name" => r.name,
      "notes" => r.notes,
      "published_at" => encode_time(r.published_at),
      "html_url" => r.html_url,
      "prerelease" => r.prerelease,
      "version_code" => r.version_code,
      "version_name" => r.version_name,
      "package" => r.package,
      "apk" => %{"name" => r.apk.name, "url" => r.apk.url, "size" => r.apk.size, "sha256" => r.apk.sha256}
    }
  end

  # what download and install need must be there and of the right type, or nothing is offered from the file
  defp decode_release(%{"tag" => tag, "version_name" => version_name, "package" => package} = r)
       when is_binary(tag) and is_binary(version_name) and is_binary(package) do
    with code when is_integer(code) <- positive(r["version_code"]),
         %{} = apk <- decode_apk(r["apk"]) do
      %{
        tag: tag,
        name: string_or_nil(r["name"]),
        notes: string_or_nil(r["notes"]) || "",
        published_at: decode_time(r["published_at"]),
        html_url: string_or_nil(r["html_url"]),
        prerelease: r["prerelease"] == true,
        version_code: code,
        version_name: version_name,
        package: package,
        apk: apk
      }
    end
  end

  defp decode_release(_), do: nil

  defp decode_apk(%{"name" => name, "url" => url, "size" => size, "sha256" => sha256})
       when is_binary(name) and is_binary(url) and is_integer(size) and size > 0 and is_binary(sha256),
       do: %{name: name, url: url, size: size, sha256: sha256}

  defp decode_apk(_), do: nil

  defp encode_time(nil), do: nil
  defp encode_time(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp decode_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> at
      {:error, _} -> nil
    end
  end

  defp decode_time(_), do: nil

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_), do: nil

  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_), do: nil
end
