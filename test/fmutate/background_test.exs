defmodule FMutate.BackgroundTest do
  use ExUnit.Case, async: false

  alias FMutate.Background

  # an instance as FMutate.Background sees it: answers subscribe with its view, publishes phase changes; quit/1
  # reports to the test and leaves it stopped
  defmodule FakeInstance do
    use GenServer

    def start_link({id, phase}),
      do: GenServer.start_link(__MODULE__, phase, name: FMutate.Instance.via(id))

    def set_phase(id, phase), do: GenServer.call(FMutate.Instance.via(id), {:phase, phase})

    @impl true
    def init(phase), do: {:ok, %{phase: phase, subs: []}}

    @impl true
    def handle_call({:subscribe, pid, _status?}, _from, s),
      do: {:reply, %{phase: s.phase}, %{s | subs: [pid | s.subs]}}

    def handle_call({:phase, phase}, _from, s) do
      for pid <- s.subs, do: send(pid, {:instance, "a", {:state, %{phase: phase}}})
      {:reply, :ok, %{s | phase: phase}}
    end

    def handle_call(:quit, _from, s) do
      send(:persistent_term.get({FMutate.BackgroundTest.Backend, :test}), {:instance, :quit})
      for pid <- s.subs, do: send(pid, {:instance, "a", {:state, %{phase: :stopped}}})
      {:reply, :ok, %{s | phase: :stopped}}
    end
  end

  # the keep-alive, permission and quit calls, reported to the test; keep_alive answers what the test set
  defmodule Backend do
    def keep_alive, do: report(:keep_alive, :persistent_term.get({__MODULE__, :answer}, :ok))
    def stop, do: report(:stop, :ok)
    def on?, do: false
    def resume, do: report(:resume, :ok)
    def request_notifications, do: report(:request_notifications, :ok)
    def quit, do: report(:quit, :ok)

    defp report(call, answer) do
      send(:persistent_term.get({__MODULE__, :test}), {:backend, call})
      answer
    end
  end

  setup do
    :persistent_term.put({Backend, :test}, self())
    :persistent_term.put({Backend, :answer}, :ok)
    on_exit(fn -> :persistent_term.erase({Backend, :answer}) end)
    start_supervised!({Registry, keys: :unique, name: FMutate.Registry})
    :ok
  end

  defp start(phase) do
    start_supervised!({FakeInstance, {"a", phase}})
    start_supervised!({Background, instances: ["a"], backend: Backend, name: :background_test})
  end

  test "held while a firmware plays, through a crash and its restart, let go in safe mode" do
    start(:booting)
    assert_receive {:backend, :keep_alive}
    assert_receive {:backend, :request_notifications}

    for phase <- [:running, :crashed, :running] do
      FakeInstance.set_phase("a", phase)
      assert Background.state(:background_test).on
    end

    refute_received {:backend, _}

    FakeInstance.set_phase("a", :safe_mode)
    assert_receive {:backend, :stop}
    refute Background.state(:background_test).on

    # Run anyway: held again, without asking for the notification permission a second time
    FakeInstance.set_phase("a", :booting)
    assert_receive {:backend, :keep_alive}
    refute_receive {:backend, :request_notifications}, 50
  end

  test "nothing to play, no keep-alive" do
    start(:not_installed)
    assert %{on: false, want: false} = Background.state(:background_test)
    refute_received {:backend, _}
  end

  test "a start Android refuses in the background is tried again when the app comes back" do
    :persistent_term.put({Backend, :answer}, {:error, :refused})
    pid = start(:running)
    assert_receive {:backend, :keep_alive}

    assert %{on: false, want: true, last_error: :refused} = Background.state(:background_test)

    :persistent_term.put({Backend, :answer}, :ok)
    send(pid, {:mob_device, :did_become_active})
    assert_receive {:backend, :keep_alive}
    assert %{on: true, last_error: nil} = Background.state(:background_test)
  end

  test "a service Android refuses after the start returned is no longer held, and is started again in the foreground" do
    pid = start(:running)
    assert_receive {:backend, :keep_alive}

    send(pid, {:mob_background, {:error, :foreground_refused}})

    assert %{on: false, want: true, last_error: :foreground_refused} =
             Background.state(:background_test)

    send(pid, {:mob_device, :did_become_active})
    assert_receive {:backend, :keep_alive}
    assert Background.state(:background_test).on
  end

  test "Quit stops the instances, then lets the keep-alive go, then ends the app" do
    pid = start(:running)
    assert_receive {:backend, :keep_alive}
    assert_receive {:backend, :request_notifications}

    send(pid, {:mob_background, {:action, :quit}})
    # in this order: the engines end (their flash saved) while the app is still kept alive
    assert [{:instance, :quit}, {:backend, :stop}, {:backend, :quit}] =
             Enum.map(1..3, fn _ -> next_message() end)

    assert %{on: false, want: false} = Background.state(:background_test)
  end

  defp next_message do
    receive do
      msg -> msg
    after
      1_000 -> flunk("no message")
    end
  end

  test "after Quit nothing starts the keep-alive again or quits twice: a second tap, a late phase, the foreground" do
    pid = start(:running)
    assert_receive {:backend, :keep_alive}
    assert_receive {:backend, :request_notifications}
    send(pid, {:mob_background, {:action, :quit}})
    assert_receive {:instance, :quit}
    assert_receive {:backend, :stop}
    assert_receive {:backend, :quit}

    send(pid, {:mob_background, {:action, :quit}})
    FakeInstance.set_phase("a", :booting)
    send(pid, {:mob_device, :did_become_active})
    send(pid, {:mob_background, {:error, :foreground_refused}})

    assert %{on: false, want: false} = Background.state(:background_test)
    refute_receive {:instance, :quit}, 50
    refute_received {:backend, _}
  end

  test "Quit while the keep-alive isn't held (refused) still stops the instances and ends the app, releasing nothing" do
    :persistent_term.put({Backend, :answer}, {:error, :refused})
    pid = start(:booting)
    assert_receive {:backend, :keep_alive}

    send(pid, {:mob_background, {:action, :quit}})
    assert_receive {:instance, :quit}
    assert_receive {:backend, :quit}
    refute_received {:backend, :stop}
  end

  test "Quit ends the app even when an instance is down" do
    pid = start(:running)
    assert_receive {:backend, :keep_alive}
    stop_supervised!(FakeInstance)

    send(pid, {:mob_background, {:action, :quit}})
    assert_receive {:backend, :stop}
    assert_receive {:backend, :quit}
  end
end
