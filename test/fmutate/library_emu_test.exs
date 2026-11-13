defmodule FMutate.LibraryEmuTest do
  # The library and the emulator engine together, as the app runs them: Hub packages on the phone
  # (as a download leaves them) run through FMutate.Instance in libfm1emu.so next to the native
  # cartridges, and each keeps its own flash file.
  use ExUnit.Case, async: false

  import Bitwise

  alias FMutate.{Firmware, Instance, Library, Paths}
  alias FMutate.Library.Catalog

  @moduletag :emu

  @emu Path.expand("native/build/host/libfm1emu.so")
  @packages Path.expand("native/build/packages")

  unless File.exists?(@emu) and File.exists?(Path.join(@packages, "dinghy.fwsc")) and
           File.exists?(Path.join(@packages, "obervave.fwsc")) do
    @moduletag skip: "run native/build_emu.sh: no #{@emu} or test packages in #{@packages}"
  end

  @hub %{
    "updated" => "2026-11-12 18:01 UTC",
    "firmwares" => [
      %{
        "id" => "obervave",
        "name" => "OberVave",
        "author" => "zvenson",
        "pkg" => "fw/obervave-3.5.fwsc"
      },
      %{
        "id" => "dinghy",
        "name" => "Dinghy",
        "author" => "zvenson",
        "pkg" => "fw/dinghy-0.5.fwsc"
      }
    ]
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "fmutate_libemu_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:fmutate_app, :data_dir, dir)
    # a fresh cache: no network
    File.write!(Path.join(dir, "hub_catalog.json"), JSON.encode!(@hub))

    start_supervised!({Registry, keys: :unique, name: FMutate.Registry})
    start_supervised!(FMutate.Audio)
    start_supervised!(Library)

    on_exit(fn ->
      Application.delete_env(:fmutate_app, :data_dir)
      File.rm_rf(dir)
    end)

    :ok
  end

  # what a finished download leaves: the Hub's file name under the packages dir
  defp download(id, package) do
    fw = Firmware.get(id)
    File.cp!(Path.join(@packages, package), Catalog.hub_package_path(fw, Paths.packages_dir()))
  end

  # the first instance event `match` returns non-nil for; status events arrive every 100 ms, so the
  # wait has a deadline rather than a receive timeout
  defp await(what, match, timeout \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      left = deadline - System.monotonic_time(:millisecond)

      receive do
        {:instance, "a", event} -> match.(event)
      after
        max(left, 0) -> flunk("#{what} within #{timeout} ms")
      end
    end)
    |> Enum.find(& &1)
  end

  # (a switch publishes the new firmware at once, while the old engine still plays: wait for the new
  # engine to be the live one)
  defp await_running(fw) do
    await("#{fw} running", fn
      {:state, %{phase: :running, firmware: ^fw} = view} ->
        if match?(%{live: %{firmware: ^fw, ready: true}}, :sys.get_state(Instance.via("a"))),
          do: view

      {:state, %{phase: phase}} when phase in [:not_installed, :crashed, :safe_mode] ->
        flunk("#{fw}: #{phase}")

      _ ->
        nil
    end)
  end

  defp await_status(what, pred, timeout) do
    await(
      what,
      fn
        {:status, status} -> if pred.(status), do: status
        _ -> nil
      end,
      timeout
    )
  end

  defp await_file(path, timeout) when timeout <= 0, do: flunk("no #{path}")

  defp await_file(path, timeout) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(50)
      await_file(path, timeout - 50)
    end
  end

  test "Hub packages run in the emulator beside the native cartridge, each with its own flash" do
    download("hub:obervave", "obervave.fwsc")
    download("dinghy", "dinghy.fwsc")

    assert %{backend: :native} = Firmware.runnable("obervave")
    assert %{backend: :emu} = Firmware.runnable("hub:obervave")
    assert %{backend: :emu} = Firmware.runnable("dinghy")

    start_supervised!({Instance, id: "a"})
    Instance.subscribe("a", status: true)
    await_running("obervave")

    # the Hub's package of the same firmware, in the emulator
    :ok = Instance.switch_firmware("a", "hub:obervave")
    await_running("hub:obervave")

    # a downloaded package: its screen runs and a key lights its LED
    :ok = Instance.switch_firmware("a", "dinghy")
    view = await_running("dinghy")
    assert File.exists?(view.fb)

    # (READY comes before the firmware has set itself up: give it a second, as the engine's own test does)
    first = await_status("a status", fn _ -> true end, 2_000)
    await_status("a second of firmware time", &(&1.ms - first.ms >= 1_000), 5_000)
    Instance.input("a", {:key, 7, :down})
    await_status("key 7's LED", &((&1.led_keys >>> 7 &&& 1) == 1), 3_000)
    Instance.input("a", {:key, 7, :up})

    # back to the native one (Undo)
    :ok = Instance.switch_firmware("a", "obervave")
    await_running("obervave")

    # the emulator saves its flash when its engine stops: under emu/, never the native file
    await_file(Paths.flash("a", "hub:obervave", :emu), 5_000)
    await_file(Paths.flash("a", "dinghy", :emu), 5_000)
    refute File.exists?(Paths.flash("a", "hub:obervave", :native))
    refute File.exists?(Paths.flash("a", "obervave", :emu))
    refute File.exists?(Paths.flash("a", "dinghy", :native))
  end
end
