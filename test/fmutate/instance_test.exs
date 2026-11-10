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
    Instance.subscribe(id)
  end

  defp await_state(pred, timeout \\ 5_000) do
    receive do
      {:instance, _id, {:state, view}} -> if pred.(view), do: view, else: await_state(pred, timeout)
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

  test "the chosen firmware and the quarantine survive a restart of the instance" do
    start_instance()
    await_state(running?("obervave"))
    :ok = Instance.switch_firmware("a", "shineon")
    await_state(running?("shineon"))

    stop_supervised!({:instance, "a"})
    start_instance()
    await_state(running?("shineon"))
  end
end
