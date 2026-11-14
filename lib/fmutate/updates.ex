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
      first screen rolls the code back.

  Subscribers (`subscribe/0`) get `{:updates, state}` on every change. State persists in
  `updates.term` (when the app was last checked, the newest release seen, the app version that last
  ran).
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

    state = %{
      config: config,
      subscribers: %{},
      installed: installed,
      app: :idle,
      release: saved[:release],
      checked_at: saved[:checked_at],
      # the app version this launch replaced, when it differs from the last one that ran
      updated_from: updated_from(saved[:version_code], installed),
      code: code_state(),
      apk: nil,
      task: nil
    }

    persist(state)
    if launch_check?(state), do: send(self(), :launch_check)
    {:ok, state}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, public(state), state}

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, {:ok, public(state)}, %{state | subscribers: Map.put(state.subscribers, ref, pid)}}
  end

  @impl true
  def handle_cast(:check, state), do: {:noreply, start_check(state, :both)}

  def handle_cast(:install, %{app: {:available, release}} = state), do: {:noreply, start_install(state, release)}
  def handle_cast(:install, %{app: {:needs_permission, release}} = state), do: {:noreply, start_install(state, release)}
  def handle_cast(:install, %{app: {:error, _}, release: %{} = release} = state), do: {:noreply, start_install(state, release)}
  def handle_cast(:install, state), do: {:noreply, state}

  @impl true
  def handle_info(:launch_check, state), do: {:noreply, start_check(state, :app)}

  # results of the work started below (one task at a time)
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> Map.put(:task, nil) |> finished(result) |> changed()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("updates: #{inspect(reason)}")
    {:noreply, changed(%{state | task: nil, app: {:error, {:crashed, reason}}})}
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

    task =
      Task.async(fn ->
        code = if what == :both, do: MobDeliver.check(details: true)
        {:checked, code, client.check(opts)}
      end)

    changed(%{state | task: task, app: :checking})
  end

  defp check_opts(config), do: Keyword.take(config, [:repo, :prerelease, :metadata_asset])

  defp finished(state, {:checked, code, app}) do
    state = %{state | code: code_state(code)}

    case app do
      {:ok, :available, release} -> persist(%{state | app: {:available, release}, release: release, checked_at: now()})
      {:ok, :up_to_date, _} -> persist(%{state | app: :up_to_date, release: nil, checked_at: now()})
      {:error, reason} -> %{state | app: {:error, reason}}
    end
  end

  defp finished(state, {:installing, {:ok, path}, :ok}), do: %{state | apk: path, app: {:confirm, state.release}}

  defp finished(state, {:installing, {:ok, path}, {:error, :install_permission_required}}),
    do: %{state | apk: path, app: {:needs_permission, state.release}}

  defp finished(state, {:installing, {:ok, path}, {:error, reason}}), do: %{state | apk: path, app: {:error, reason}}
  defp finished(state, {:installing, {:error, reason}, nil}), do: %{state | apk: nil, app: {:error, reason}}

  ## Installing

  defp start_install(%{task: %Task{}} = state, _release), do: state

  defp start_install(state, release) do
    client = client()
    server = self()
    downloaded = state.apk

    task =
      Task.async(fn ->
        case downloaded || client.download(release, notify: server) do
          {:error, _} = error -> {:installing, error, nil}
          {:ok, path} -> {:installing, {:ok, path}, client.install(path, notify: server)}
          path -> {:installing, {:ok, path}, client.install(path, notify: server)}
        end
      end)

    changed(%{state | task: task, release: release, app: {:downloading, 0, release.apk.size}})
  end

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

  defp code_state(check \\ nil) do
    %{
      state: MobDeliver.state(),
      check: check,
      channel: Application.get_env(:mob_deliver, :channel)
    }
  end

  defp installed do
    case client().installed() do
      {:ok, installed} -> installed
      {:error, _} -> nil
    end
  end

  defp updated_from(nil, _installed), do: nil
  defp updated_from(_code, nil), do: nil
  defp updated_from(code, %{version_code: now}) when code < now, do: code
  defp updated_from(_code, _installed), do: nil

  defp client, do: Application.get_env(:fmutate_app, :app_update_client, MobAppUpdate)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  ## Persistence (updates.term)

  defp file(config), do: Keyword.get_lazy(config, :file, fn -> Path.join(Paths.data_dir(), "updates.term") end)

  defp load(config) do
    with {:ok, bin} <- File.read(file(config)),
         {:ok, %{} = saved} <- safe_term(bin) do
      saved
    else
      _ -> %{}
    end
  end

  defp safe_term(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    ArgumentError -> :error
  end

  defp persist(state) do
    saved = %{
      checked_at: state.checked_at,
      release: state.release,
      version_code: state.installed && state.installed.version_code
    }

    path = file(state.config)
    File.mkdir_p!(Path.dirname(path))

    case File.write(path, :erlang.term_to_binary(saved)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("updates: couldn't save #{path}: #{inspect(reason)}")
    end

    state
  end
end
