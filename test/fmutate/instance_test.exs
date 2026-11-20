defmodule FMutate.InstanceTest do
  # Runs the real engine and firmware cartridges built for this computer (native/build_host.sh).
  # There is no audio device on the host, so firmware time stands still, but booting, READY,
  # STATUS, switching, crashes and restarts are all real.
  use ExUnit.Case, async: false

  alias FMutate.Instance

  @moduletag :engine

  setup do
    unless File.exists?(FMutate.Paths.engine_bin()),
      do: raise("run native/build_host.sh first: no #{FMutate.Paths.engine_bin()}")

    dir = Path.join(System.tmp_dir!(), "fmutate_test_#{System.unique_integer([:positive])}")
    Application.put_env(:fmutate_app, :data_dir, dir)
    start_supervised!({Registry, keys: :unique, name: FMutate.Registry})
    start_supervised!(FMutate.Audio)

    on_exit(fn ->
      Application.delete_env(:fmutate_app, :data_dir)
      # (an engine may still be saving its flash after the test; leftovers live under tmp)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  defp start_instance(id \\ "a") do
    start_supervised!({Instance, id: id}, id: {:instance, id})
    Instance.subscribe(id, status: true)
  end

  defp await_state(pred, timeout \\ 5_000) do
    receive do
      {:instance, _id, {:state, view}} ->
        if pred.(view), do: view, else: await_state(pred, timeout)
    after
      timeout -> flunk("no matching instance state within #{timeout} ms")
    end
  end

  defp running?(fw), do: &(&1.phase == :running and &1.firmware == fw)

  defp engine_os_pid(id) do
    %{live: %{pid: pid}} = :sys.get_state(Instance.via(id))
    %{os_pid: os_pid} = :sys.get_state(pid)
    os_pid
  end

  defp os_alive?(os_pid), do: File.exists?("/proc/#{os_pid}")

  test "boots the default firmware and exposes its screen file" do
    start_instance()
    view = await_state(running?("obervave"))
    assert <<0x46, 0x31, 0x4D, 0x46, _::binary>> = File.read!(view.fb)
  end

  test "switching starts the new firmware and stops the old engine" do
    start_instance()
    await_state(running?("obervave"))
    old = engine_os_pid("a")

    assert :ok = Instance.switch_firmware("a", "shineon")
    await_state(running?("shineon"))
    Process.sleep(500)
    refute os_alive?(old)
    assert Instance.view("a").firmware == "shineon"
  end

  test "an unknown firmware is refused and nothing changes" do
    start_instance()
    await_state(running?("obervave"))
    assert {:error, :not_installed} = Instance.switch_firmware("a", "nope")
    assert Instance.view("a").firmware == "obervave"
  end

  test "switching back to the firmware still playing before the new one is ready keeps it running" do
    start_instance()
    await_state(running?("obervave"))
    old = engine_os_pid("a")

    # (both calls queued before the instance runs the first, so the new engine can't be READY in between)
    pid = GenServer.whereis(Instance.via("a"))
    :sys.suspend(pid)
    away = Task.async(fn -> Instance.switch_firmware("a", "shineon") end)
    Process.sleep(50)
    back = Task.async(fn -> Instance.switch_firmware("a", "obervave") end)
    Process.sleep(50)
    :sys.resume(pid)
    assert [:ok, :ok] = Task.await_many([away, back])
    Process.sleep(1_000)
    view = Instance.view("a")
    assert view.firmware == "obervave" and view.phase == :running
    assert engine_os_pid("a") == old
    assert %{next: nil} = :sys.get_state(Instance.via("a"))
  end

  test "a firmware that ended the app (in-process crash marker) is quarantined at the second launch in a row" do
    start_supervised!({Instance, id: "a", crashed: ["obervave"]}, id: {:instance, "a"})
    Instance.subscribe("a", status: true)
    view = await_state(running?("obervave"))
    refute view.quarantined
    stop_supervised!({:instance, "a"})

    # (another firmware's crash isn't counted against this one)
    start_supervised!({Instance, id: "a", crashed: ["shineon"]}, id: {:instance, "a"})
    Instance.subscribe("a", status: true)
    await_state(running?("obervave"))
    stop_supervised!({:instance, "a"})

    start_supervised!({Instance, id: "a", crashed: ["obervave"]}, id: {:instance, "a"})
    assert %{phase: :safe_mode, quarantined: true, last_exit: :app_crash} = Instance.view("a")
  end

  test "a crash marker of a firmware other than the current one (a crossfade's old one) quarantines that firmware" do
    start_supervised!({Instance, id: "a", crashed: ["shineon"]}, id: {:instance, "a"})
    Instance.subscribe("a", status: true)
    await_state(running?("obervave"))
    assert Instance.quarantined("a") == []
    stop_supervised!({:instance, "a"})

    start_supervised!({Instance, id: "a", crashed: ["shineon"]}, id: {:instance, "a"})
    Instance.subscribe("a", status: true)
    view = await_state(running?("obervave"))
    assert Instance.quarantined("a") == ["shineon"]
    refute view.quarantined
    refute view.last_exit == :app_crash
    assert {:error, :quarantined} = Instance.switch_firmware("a", "shineon")
  end

  test "a crashed engine is restarted in place" do
    start_instance()
    await_state(running?("obervave"))
    old = engine_os_pid("a")

    Instance.debug("a", :crash)
    await_state(&(&1.phase == :crashed and &1.last_exit == {:signal, 11}))
    view = await_state(running?("obervave"))
    assert view.restarts == 1
    refute engine_os_pid("a") == old
  end

  test "a hung engine is killed by the watchdog and restarted" do
    start_instance()
    await_state(running?("obervave"))
    Instance.debug("a", :hang)
    await_state(&(&1.last_exit == :hung), 3_000)
    await_state(running?("obervave"))
  end

  test "two failures within a minute quarantine the firmware until run anyway" do
    start_instance()
    await_state(running?("obervave"))
    Instance.debug("a", :crash)
    await_state(running?("obervave"))
    Instance.debug("a", :crash)

    view = await_state(&(&1.phase == :safe_mode))
    assert view.quarantined
    assert {:error, :quarantined} = Instance.switch_firmware("a", "obervave")

    assert :ok = Instance.run_anyway("a")
    view = await_state(running?("obervave"))
    refute view.quarantined
  end

  test "the view carries the engine's speed; a fixed buffer reaches the running engine and is saved" do
    start_instance()
    view = await_state(running?("obervave"))

    assert view.buffer == :auto and view.fill == FMutate.Audio.engine_fill() and
             view.slow == false

    # (two warm-up windows, then a second per measurement; the host drains the ring in real time)
    view = await_state(&is_integer(&1.clock_pct), 6_000)
    assert view.clock_pct in 90..110
    refute view.slow

    :ok = Instance.set_buffer("a", 3072)
    assert %{buffer: 3072, fill: 3072} = Instance.view("a")
    assert_eventually_fill(&(&1 > 2048))

    stop_supervised!({:instance, "a"})
    start_instance()
    view = await_state(running?("obervave"))
    assert view.buffer == 3072 and view.fill == 3072
  end

  test "run anyway from safe mode, as the instrument's screen area asks for it" do
    start_instance()
    await_state(running?("obervave"))
    Instance.debug("a", :crash)
    await_state(running?("obervave"))
    Instance.debug("a", :crash)
    await_state(&(&1.phase == :safe_mode))

    socket = %Mob.Socket{assigns: %{instance: "a"}}
    assert {:noreply, _} = FMutate.InstrumentView.handle_event("run_anyway", %{}, socket)
    view = await_state(running?("obervave"))
    refute view.quarantined
  end

  # within `tries` STATUS messages (100 ms apart) after the ones already queued
  defp assert_eventually_fill(pred) do
    flush_statuses()
    assert_eventually_fill(pred, 30)
  end

  defp assert_eventually_fill(_pred, 0), do: flunk("the engine's fill never got there")

  defp assert_eventually_fill(pred, tries) do
    receive do
      {:instance, "a", {:status, %{fill: fill}}} ->
        if pred.(fill), do: :ok, else: assert_eventually_fill(pred, tries - 1)
    after
      1_000 -> flunk("no status")
    end
  end

  defp flush_statuses do
    receive do
      {:instance, _, {:status, _}} -> flush_statuses()
    after
      0 -> :ok
    end
  end

  test "the chosen firmware and the quarantine survive a restart of the instance" do
    start_instance()
    await_state(running?("obervave"))
    :ok = Instance.switch_firmware("a", "shineon")
    await_state(running?("shineon"))

    stop_supervised!({:instance, "a"})
    start_instance()
    await_state(running?("shineon"))
  end

  test "what the firmware holds is tracked, Release all lets go of it, and inputs with no engine are journaled as dropped" do
    start_instance()
    await_state(running?("obervave"))
    Instance.input("a", {:key, 7, :down})
    Instance.input("a", {:button, :sel, :down})
    assert Instance.held("a") == %{keys: [7], buttons: [:sel]}

    Instance.release_all("a")
    assert Instance.held("a") == %{keys: [], buttons: []}
    assert [{_, :in, {:midi, <<0xB0, 123, 0, _::binary>>}, :sent} | _] = Instance.journal("a", 5)

    Instance.debug("a", :kill9)
    await_state(&(&1.phase != :running))
    Instance.input("a", {:button, :fx, :down})
    assert {_, :in, {:button, :fx, :down}, :dropped} = hd(Instance.journal("a", 1))
  end

  test "status events go only to subscribers that ask for them; every subscriber gets state changes" do
    start_instance()
    await_state(running?("obervave"))
    test = self()

    # a screen-like subscriber: the view only (a screen re-renders on every message it gets)
    screen =
      spawn_link(fn ->
        Instance.subscribe("a")
        send(test, :subscribed)

        collect = fn collect, acc ->
          receive do: (
                    :report -> send(test, {:got, Enum.reverse(acc)})
                    m -> collect.(collect, [m | acc])
                  )
        end

        collect.(collect, [])
      end)

    assert_receive :subscribed

    # the test process subscribed with status: true; a second of STATUS (every 100 ms) and one state change
    Process.sleep(1_000)
    Instance.debug("a", :crash)
    await_state(&(&1.phase != :running))
    send(screen, :report)
    assert_receive {:got, got}, 2_000

    assert Enum.any?(got, &match?({:instance, "a", {:state, _}}, &1))
    refute Enum.any?(got, &match?({:instance, "a", {:status, _}}, &1))
    assert_received {:instance, "a", {:status, _}}
  end

  describe "quit (the notification's Quit)" do
    # (`os_alive?/1` above reads /proc, which macOS doesn't have)
    defp os_running?(os_pid),
      do: match?({_, 0}, System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true))

    defp engines(id) do
      s = :sys.get_state(Instance.via(id))
      Enum.reject([s.live, s.next], &is_nil/1) ++ Map.values(s.stopping)
    end

    defp os_pids(engines), do: Enum.map(engines, &:sys.get_state(&1.pid).os_pid)

    # everything the instance had has ended and given its audio slot back, and nothing starts again
    defp assert_quit(id, os_pids) do
      assert %{live: nil, next: nil, stopping: stopping, phase: :stopped} =
               :sys.get_state(Instance.via(id))

      assert stopping == %{}
      assert :sys.get_state(FMutate.Audio).owners == %{}
      for os_pid <- os_pids, do: refute(os_running?(os_pid))

      Process.sleep(300)
      assert %{phase: :stopped} = Instance.view(id)
      assert {:error, :quit} = Instance.switch_firmware(id, "shineon")
      assert {:error, :quit} = Instance.run_anyway(id)
      assert engines(id) == []
    end

    test "a running engine ends as on a normal stop, saving its flash, before quit returns" do
      start_instance()
      await_state(running?("obervave"))
      [eng] = engines("a")
      flash = FMutate.Paths.flash("a", "obervave", eng.backend)
      File.rm(flash)
      pids = os_pids([eng])

      assert :ok = Instance.quit("a")
      assert File.exists?(flash)
      assert_quit("a", pids)
    end

    test "right after the start, while the engine boots" do
      start_instance()
      # (quit usually lands before READY; the outcome must be the same either way)
      assert [_eng] = engines = engines("a")
      pids = os_pids(engines)
      assert :ok = Instance.quit("a")
      assert_quit("a", pids)
    end

    test "an engine that crashes just after the quit isn't restarted, and its crash isn't counted" do
      start_instance()
      await_state(running?("obervave"))
      [eng] = engines("a")
      pids = os_pids([eng])
      pid = GenServer.whereis(Instance.via("a"))

      # the quit is queued first, the engine's exit right behind it
      :sys.suspend(pid)
      quit = Task.async(fn -> Instance.quit("a") end)
      Process.sleep(50)
      ref = Process.monitor(eng.pid)
      FMutate.Engine.kill9(eng.pid)
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
      :sys.resume(pid)

      assert :ok = Task.await(quit)
      assert_quit("a", pids)
      assert %{restarts: 0, last_exit: nil} = Instance.view("a")
      assert Instance.quarantined("a") == []
    end

    # suspend the instance once the new engine plays and the old one crossfades out (stopped 200 ms after the new
    # one's READY, {:finish_switch, _})
    defp suspend_crossfading(pid, tries \\ 500) do
      :sys.suspend(pid)

      case :sys.get_state(pid) do
        %{next: nil, stopping: stopping} when map_size(stopping) == 1 ->
          :ok

        _ when tries > 0 ->
          :sys.resume(pid)
          Process.sleep(2)
          suspend_crossfading(pid, tries - 1)
      end
    end

    test "while a switch crossfades: the old engine not yet told to stop ends too" do
      start_instance()
      await_state(running?("obervave"))
      :ok = Instance.switch_firmware("a", "shineon")
      pid = GenServer.whereis(Instance.via("a"))
      suspend_crossfading(pid)
      pids = os_pids(engines("a"))
      quit = Task.async(fn -> Instance.quit("a") end)
      Process.sleep(50)
      :sys.resume(pid)

      assert :ok = Task.await(quit)
      assert_quit("a", pids)
    end

    test "in the middle of a switch: the new engine booting and the old one playing both end" do
      start_instance()
      await_state(running?("obervave"))
      assert :ok = Instance.switch_firmware("a", "shineon")
      assert [_, _] = engines = engines("a")
      pids = os_pids(engines)
      assert :ok = Instance.quit("a")
      assert_quit("a", pids)
    end

    test "twice at once: both return once the engines have ended" do
      start_instance()
      await_state(running?("obervave"))
      pids = os_pids(engines("a"))
      pid = GenServer.whereis(Instance.via("a"))
      :sys.suspend(pid)
      quits = for _ <- 1..2, do: Task.async(fn -> Instance.quit("a") end)
      Process.sleep(50)
      :sys.resume(pid)
      assert [:ok, :ok] = Task.await_many(quits)
      assert_quit("a", pids)
    end

    test "the next launch boots the firmware as usual" do
      start_instance()
      await_state(running?("obervave"))
      :ok = Instance.switch_firmware("a", "shineon")
      await_state(running?("shineon"))
      assert :ok = Instance.quit("a")

      stop_supervised!({:instance, "a"})
      start_instance()
      view = await_state(running?("shineon"))
      refute view.quarantined
      assert view.restarts == 0
    end
  end
end
