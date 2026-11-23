defmodule FMutate.Background do
  @moduledoc """
  Keeps the app running in the background while a firmware plays (docs/architecture.md "Background").

  Android freezes a cached app's process shortly after it leaves the screen: the BEAM, the engines and the
  MIDI port stop, and the audio with them. While any instance has an engine (phase `:booting`, `:running`
  or `:crashed`, which restarts it) this process holds the `mob_background` keep-alive on: a
  `mediaPlayback` foreground service with the notification "FMutate is playing". The session is owned by
  `FMutate.Background.Session` (it ends if its owner does), started before everything else that could fail,
  so a restart of this process (with the instances or the I/O before it) finds the keep-alive still held:
  Android wouldn't start it again from the background. Nothing to play (safe mode, a firmware that can't
  run here) lets it go, and Android may freeze the app again.

  Android only starts a foreground service while the app is in the foreground. A start it refuses (`{:error,
  :refused}` at once, or `{:mob_background, {:error, :foreground_refused}}` after: the instance came back from
  safe mode while the app was away) is tried again when the app returns to the foreground. The first start
  asks for the notification permission (Android 13+), without which the notification shows only in the
  system's running-apps list.

  The notification's **Quit** (`{:mob_background, {:action, :quit}}`) ends the app: every instance stops its
  engines as a normal stop does (`FMutate.Instance.quit/1`: each saves its flash), the keep-alive goes (and
  the notification with it), and the backend closes the audio output and ends the app (Android: finishes the
  activity and its task, then ends the process; `FMutateIO.kt`). Nothing restarts it: the service is
  `START_NOT_STICKY`, and the next launch starts as any other.

  iOS keeps an app running in the background while its audio session plays (`UIBackgroundModes` `audio`), so
  there the keep-alive is FMutate's own output (mob_background's iOS keep-alive, a silent audio engine, would be
  a second one): this process starts from whether the output runs (it starts with the app, and a restarted
  Background finds it as it was left), and when nothing plays it stops it, releasing the audio session (other
  apps' audio is no longer mixed with a silent FMutate, and iOS may suspend the app in the background);
  something playing again starts it. iOS has no notification to put a Quit on (docs/architecture.md
  "Background").
  """

  use GenServer
  require Logger
  require FMutate.Subscription

  alias FMutate.{Instance, Subscription}

  @playing [:booting, :running, :crashed]

  defmodule Session do
    @moduledoc false
    # Owns mob_background's session (Android), which ends when its owner exits: this process does nothing that
    # can fail, and FMutate.Supervisor starts it right after the Registry, so it outlives restarts of
    # FMutate.Background. The notification's actions and Android's refusals go on to FMutate.Background.
    use GenServer

    @notification %{
      title: "FMutate",
      text: "FMutate is playing",
      actions: [%{id: :quit, label: "Quit"}]
    }

    def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

    def start, do: GenServer.call(__MODULE__, :start)
    def stop, do: GenServer.call(__MODULE__, :stop)
    def on?, do: GenServer.call(__MODULE__, :on?)

    @impl true
    def init(nil), do: {:ok, false}

    @impl true
    def handle_call(:start, _from, _on) do
      result = MobBackground.start(self(), mode: :media_playback, notification: @notification)
      {:reply, result, result == :ok}
    end

    def handle_call(:stop, _from, _on), do: {:reply, MobBackground.stop(), false}
    def handle_call(:on?, _from, on), do: {:reply, on, on}

    @impl true
    def handle_info({:mob_background, event} = msg, on) do
      if pid = Process.whereis(FMutate.Background), do: send(pid, msg)
      {:noreply, on and not match?({:error, _}, event)}
    end
  end

  defmodule Native do
    @moduledoc false
    # The device side: mob_background's keep-alive (through Session) and Mob's permission request (Android); the
    # audio output (iOS).
    def keep_alive, do: if(ios?(), do: FMutate.Audio.start(), else: Session.start())

    def stop, do: if(ios?(), do: FMutate.Audio.stop(), else: Session.stop())

    # whether the keep-alive is already held when this process starts: on iOS (in-process engines) the output's
    # own state; on Android the session's
    def on? do
      cond do
        FMutate.Paths.inproc?() -> FMutate.Audio.running?()
        Process.whereis(Session) -> Session.on?()
        true -> false
      end
    end

    # back in the foreground with the keep-alive held: on iOS open the output if nothing has it open (Audio.start
    # leaves an open stream alone; mob_audio_io reopens one an interruption stopped when the app is back in the
    # foreground, whether or not iOS reported the interruption's end); elsewhere nothing
    def resume, do: if(ios?(), do: FMutate.Audio.start(), else: :ok)
    def request_notifications, do: unless(ios?(), do: :mob_nif.request_permission(:notifications))

    # Quit (Android; the engines have ended): close the audio output, then FMutateIO.kt finishes the activity and
    # its task and ends the process
    def quit do
      FMutate.Audio.stop()

      with {:ok, _reply} <- FMutate.IONif.call(~s({"op":"quit"})), do: :ok
    end

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

    backend = Keyword.get(opts, :backend, Native)

    state = %{
      backend: backend,
      phases: Map.new(instances, &{&1, nil}),
      on: backend.on?(),
      asked: false,
      last_error: nil,
      # the notification's Quit was tapped: the app is ending, nothing is started again
      quit: false
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

  def handle_info({:mob_device, :did_become_active}, state) do
    if state.on and want?(state) do
      with {:error, reason} <- state.backend.resume(),
           do: Logger.warning("background: output didn't resume: #{inspect(reason)}")
    end

    {:noreply, apply_want(state)}
  end

  def handle_info({:permission, :notifications, result}, state) do
    Logger.info("background: notification permission #{result}")
    {:noreply, state}
  end

  def handle_info({:mob_background, {:action, :quit}}, %{quit: false} = state) do
    Logger.info("background: Quit from the notification")
    state = %{state | quit: true}
    Enum.each(Map.keys(state.phases), &quit_instance/1)
    state = if state.on, do: stop(state), else: state

    with {:error, reason} <- state.backend.quit(),
         do: Logger.error("background: the app didn't end: #{inspect(reason)}")

    {:noreply, state}
  end

  # Android ended the service (a start refused after it was asked for, a time limit): held no longer; tried again
  # when the app comes back to the foreground
  def handle_info({:mob_background, {:error, reason}}, %{quit: false} = state) do
    Logger.warning("background: keep-alive ended by Android: #{inspect(reason)}")
    {:noreply, %{state | on: false, last_error: reason}}
  end

  # (a second Quit while quitting, an action FMutate doesn't show)
  def handle_info(_msg, state), do: {:noreply, state}

  # (an instance that is down, restarting under its supervisor, has no engine to stop; the app ends regardless)
  defp quit_instance(id) do
    Instance.quit(id)
  catch
    :exit, reason -> Logger.warning("background: instance #{id} didn't quit: #{inspect(reason)}")
  end

  defp put_phase(state, id, phase), do: %{state | phases: Map.put(state.phases, id, phase)}

  defp want?(%{quit: true}), do: false
  defp want?(state), do: Enum.any?(state.phases, fn {_id, phase} -> phase in @playing end)

  defp apply_want(%{quit: true} = state), do: state

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
