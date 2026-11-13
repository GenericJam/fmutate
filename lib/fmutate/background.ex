defmodule FMutate.Background do
  @moduledoc """
  Keeps the app running in the background while a firmware plays (docs/architecture.md "Background").

  Android freezes a cached app's process shortly after it leaves the screen: the BEAM, the engines and the
  MIDI port stop, and the audio with them. While any instance has an engine (phase `:booting`, `:running`
  or `:crashed`, which restarts it) this process holds the `mob_background` keep-alive on: a
  `mediaPlayback` foreground service with the notification "FMutate is playing". Nothing to play (safe
  mode, a firmware that can't run here) lets it go, and Android may freeze the app again.

  Android only starts a foreground service while the app is in the foreground. A start it refuses
  (`{:error, :start_not_allowed}`: the instance came back from safe mode while the app was away) is tried
  again when the app returns to the foreground. The first start asks for the notification permission
  (Android 13+), without which the notification shows only in the system's running-apps list.

  iOS keeps an app running in the background while its audio session plays (`UIBackgroundModes` `audio`), which
  FMutate's own output does whenever an engine runs; mob_background's iOS keep-alive (a silent audio engine)
  would be a second one, so the keep-alive does nothing there.
  """

  use GenServer
  require Logger
  require FMutate.Subscription

  alias FMutate.{Instance, Subscription}

  @playing [:booting, :running, :crashed]

  defmodule Native do
    @moduledoc false
    # The device side: mob_background's keep-alive and Mob's permission request (Android); nothing on iOS.
    def keep_alive do
      if ios?(), do: :ok, else: MobBackground.keep_alive(type: :media_playback, text: "FMutate is playing")
    end

    def stop, do: if(ios?(), do: :ok, else: MobBackground.stop())
    def request_notifications, do: unless(ios?(), do: :mob_nif.request_permission(:notifications))

    defp ios?, do: :mob_nif.platform() == :ios
  end

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "`%{on: whether the keep-alive is held, want: whether something plays, last_error: the last refusal}`."
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  @impl true
  def init(opts) do
    instances = Keyword.fetch!(opts, :instances)
    if Process.whereis(Mob.Device), do: Mob.Device.subscribe(:app)

    state = %{
      backend: Keyword.get(opts, :backend, Native),
      phases: Map.new(instances, &{&1, nil}),
      on: false,
      asked: false,
      last_error: nil
    }

    {:ok, instances |> Enum.reduce(state, &subscribe/2) |> apply_want()}
  end

  # (an instance that isn't up yet arrives later through Subscription)
  defp subscribe(id, state) do
    case Subscription.subscribe({:instance, id}, Instance.via(id), fn ->
           Instance.subscribe(id)
         end) do
      {:ok, view} -> put_phase(state, id, view.phase)
      :pending -> state
    end
  end

  @impl true
  def handle_call(:state, _from, state),
    do: {:reply, %{on: state.on, want: want?(state), last_error: state.last_error}, state}

  @impl true
  def handle_info({:instance, id, {:state, view}}, state),
    do: {:noreply, state |> put_phase(id, view.phase) |> apply_want()}

  def handle_info(msg, state) when Subscription.message?(msg) do
    case Subscription.handle(msg) do
      {:subscribed, {:instance, id}, view} ->
        {:noreply, state |> put_phase(id, view.phase) |> apply_want()}

      # an instance going down (restarting) keeps its last phase until it answers again
      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:mob_device, :did_become_active}, state), do: {:noreply, apply_want(state)}

  def handle_info({:permission, :notifications, result}, state) do
    Logger.info("background: notification permission #{result}")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp put_phase(state, id, phase), do: %{state | phases: Map.put(state.phases, id, phase)}

  defp want?(state), do: Enum.any?(state.phases, fn {_id, phase} -> phase in @playing end)

  defp apply_want(state) do
    case {want?(state), state.on} do
      {true, false} -> start(state)
      {false, true} -> stop(state)
      _ -> state
    end
  end

  defp start(state) do
    case state.backend.keep_alive() do
      :ok ->
        Logger.info("background: keep-alive on (mediaPlayback)")
        unless state.asked, do: state.backend.request_notifications()
        %{state | on: true, asked: true, last_error: nil}

      {:error, reason} ->
        Logger.warning(
          "background: keep-alive refused: #{inspect(reason)}; trying again in the foreground"
        )

        %{state | last_error: reason}
    end
  end

  defp stop(state) do
    :ok = state.backend.stop()
    Logger.info("background: keep-alive off, nothing plays")
    %{state | on: false}
  end
end
