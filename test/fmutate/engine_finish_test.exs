defmodule FMutate.EngineFinishTest do
  # `FMutate.Engine.finish/1` (op 0x09): the engine saves its flash and ends with the port open, so its exit status
  # is seen; only status 0, given once the flash file is written, is `{:exit, :stopped}`. Every engine as the app
  # runs it: the native executable, the emulator executable (native/build_emu.sh), and the native engine
  # in-process (iOS: native/build_ios.sh's host build, macOS only).
  use ExUnit.Case, async: false

  alias FMutate.{Engine, EngineNif, Paths}

  @moduletag :engine
  @emu Path.expand("native/build/host/libfm1emu.so")
  @dinghy Path.expand("native/build/packages/dinghy.fwsc")
  @nif Path.expand("native/build/host/fm1host.so")

  setup do
    dir = Path.join(System.tmp_dir!(), "fmutate_finish_test_#{System.unique_integer([:positive])}")
    Application.put_env(:fmutate_app, :data_dir, dir)
    File.mkdir_p!(Path.join(dir, "flash"))

    on_exit(fn ->
      File.chmod(Path.join(dir, "flash"), 0o700)
      Application.delete_env(:fmutate_app, :data_dir)
      File.rm_rf(dir)
    end)

    {:ok, flash_dir: Path.join(dir, "flash")}
  end

  defp start(:native, flash),
    do: start_link(bin: Paths.engine_bin(), cart: Paths.bundled_cart("obervave"), flash: flash)

  defp start(:emu, flash), do: start_link(bin: @emu, cart: @dinghy, flash: flash)

  defp start(:inproc, flash) do
    :ok = EngineNif.load_host(@nif)
    start_link(bin: :inproc, backend: :native, cart: "obervave", flash: flash)
  end

  defp start_link(opts) do
    prefix = Path.join(Paths.data_dir(), "fin#{System.unique_integer([:positive])}")
    {:ok, pid} = Engine.start_link([owner: self(), tag: :finish, prefix: prefix] ++ opts)
    assert_receive {:engine, ^pid, {:ready, _}}, 5_000
    pid
  end

  defp exit_of(pid) do
    assert_receive {:engine, ^pid, {:exit, reason}}, 6_000
    reason
  end

  for engine <- [:native, :emu, :inproc] do
    describe "#{engine}" do
      if engine == :emu and not (File.exists?(@emu) and File.exists?(@dinghy)),
        do: @describetag(skip: "run native/build_emu.sh: no #{@emu} or #{@dinghy}")

      if engine == :inproc and not File.exists?(@nif),
        do: @describetag(skip: "run TARGETS=host native/build_ios.sh (macOS): no #{@nif}")

      test "finish saves the flash and ends cleanly", %{flash_dir: dir} do
        flash = Path.join(dir, "fw.bin")
        pid = start(unquote(engine), flash)
        File.rm(flash)

        Engine.finish(pid)
        assert exit_of(pid) == :stopped
        assert File.exists?(flash)
      end

      test "a flash that can't be written makes finish a failure, not a clean stop", %{flash_dir: dir} do
        flash = Path.join(dir, "fw.bin")
        pid = start(unquote(engine), flash)
        File.chmod!(dir, 0o500)

        Engine.finish(pid)
        assert {:status, 2} = exit_of(pid)
        refute File.exists?(flash)
      end
    end
  end

  test "an engine killed before it can save isn't a clean stop", %{flash_dir: dir} do
    pid = start(:native, Path.join(dir, "fw.bin"))
    :sys.suspend(pid)
    System.cmd("kill", ["-9", "#{:sys.get_state(pid).os_pid}"])
    Process.sleep(200)
    Engine.finish(pid)
    :sys.resume(pid)
    assert {:signal, 9} = exit_of(pid)
  end
end
