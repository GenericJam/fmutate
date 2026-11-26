defmodule FMutate.SoundsTest do
  # Sound snapshots against the real OberVave cartridge built for this computer (native/build_host.sh), through
  # FMutate.Instance as the app runs it; the host Audio drains its ring, so the firmware's time runs and it
  # saves its settings itself (OberVave: ~3 s after a change).
  use ExUnit.Case, async: false

  alias FMutate.{Instance, Paths, Sounds}

  @moduletag :engine

  setup do
    unless File.exists?(Paths.engine_bin()),
      do: raise("run native/build_host.sh first: no #{Paths.engine_bin()}")

    dir = Path.join(System.tmp_dir!(), "fmutate_sounds_test_#{System.unique_integer([:positive])}")
    Application.put_env(:fmutate_app, :data_dir, dir)
    start_supervised!({Registry, keys: :unique, name: FMutate.Registry})
    start_supervised!(FMutate.Audio)

    on_exit(fn ->
      Application.delete_env(:fmutate_app, :data_dir)
      File.rm_rf(dir)
    end)

    start_supervised!({Instance, id: "a"}, id: {:instance, "a"})
    Instance.subscribe("a", status: true)
    await_running("obervave")
    firmware_wait(1_000)
    {:ok, flash: Paths.flash("a", "obervave", :native)}
  end

  defp await_running(fw, timeout \\ 8_000) do
    receive do
      {:instance, "a", {:state, %{phase: :running, firmware: ^fw}}} -> :ok
      {:instance, "a", {:state, _}} -> await_running(fw, timeout)
    after
      timeout -> flunk("#{fw} isn't running within #{timeout} ms")
    end
  end

  # (after the instance is stopped: what the old one sent is no news about the next)
  defp forget_instance do
    receive do
      {:instance, "a", _} -> forget_instance()
    after
      0 -> :ok
    end
  end

  # until the firmware's own clock is `ms` further on (from the next STATUS after those already queued)
  defp firmware_wait(ms) do
    target = fresh_status_ms() + ms
    Stream.repeatedly(&next_status_ms/0) |> Enum.find(&(&1 >= target))
  end

  defp fresh_status_ms do
    receive do
      {:instance, "a", {:status, _}} -> fresh_status_ms()
    after
      0 -> next_status_ms()
    end
  end

  defp next_status_ms do
    receive do
      {:instance, "a", {:status, %{ms: ms}}} -> ms
    after
      2_000 -> flunk("no STATUS from the firmware")
    end
  end

  defp tap(button) do
    Instance.input("a", {:button, button, :down})
    Instance.input("a", {:button, button, :up})
  end

  # PERFORM (HOME) KNOB 1 is CUTOFF; OberVave saves its settings by itself a few seconds later, and the engine
  # writes the flash file when the firmware's save memory changes
  defp turn_cutoff(flash, clicks) do
    before = read_flash(flash)
    tap(:home)
    firmware_wait(300)
    Instance.input("a", {:encoder, :knob1, clicks})

    Enum.find_value(1..100, fn _ ->
      firmware_wait(100)
      bytes = read_flash(flash)
      if bytes != before, do: bytes
    end) || flunk("OberVave didn't save the change")
  end

  test "a saved sound loads back: the flash holds its bytes again, and Undo toggles the load", %{flash: flash} do
    {:ok, saved} = Sounds.save("a", "Bright")
    assert saved.bytes == File.read!(flash)
    assert %{id: "obervave", name: "OberVave", version: "3.3.2", backend: :native} = saved.firmware
    refute Sounds.undo?("a", "obervave", :native)

    changed = turn_cutoff(flash, -20)
    assert byte_size(changed) == byte_size(saved.bytes)

    {:ok, running} = Sounds.running("a")
    [listed] = Sounds.list("obervave")
    {:ok, read} = Sounds.read(listed.path)
    assert read.bytes == saved.bytes
    assert Sounds.check(read, running) == :ok

    assert :ok = Sounds.load("a", read)
    assert File.read!(flash) == saved.bytes
    assert %{phase: :running, firmware: "obervave"} = Instance.view("a")
    # the restarted firmware runs on the loaded memory and keeps it
    firmware_wait(1_000)
    assert File.read!(flash) == saved.bytes

    assert Sounds.undo?("a", "obervave", :native)
    assert :ok = Sounds.undo("a")
    assert File.read!(flash) == changed
    assert :ok = Sounds.undo("a")
    assert File.read!(flash) == saved.bytes
    # an undo isn't a saved sound
    assert length(Sounds.list("obervave")) == 1
  end

  test "Reset to original: the synth runs on its first settings again; Undo puts back what was there", %{flash: flash} do
    # an edit from the fresh synth's defaults gives these bytes
    changed = turn_cutoff(flash, -20)

    assert :ok = Sounds.reset("a")
    assert %{phase: :running, firmware: "obervave"} = Instance.view("a")
    assert Sounds.undo?("a", "obervave", :native)

    assert :ok = Sounds.undo("a")
    assert File.read!(flash) == changed
    # a second undo resets again (an empty memory fits the synth's length; or OberVave's own defaults, written
    # meanwhile: what it saves when it runs on no memory)
    assert :ok = Sounds.undo("a")

    # the same edit from the reset synth writes the same memory: it runs on its defaults, nothing of the edit kept
    assert turn_cutoff(flash, -20) == changed
    assert Sounds.list("obervave") == []
  end

  defp read_flash(flash) do
    case File.read(flash) do
      {:ok, bytes} -> bytes
      {:error, :enoent} -> nil
    end
  end

  test "saving twice under one name keeps both, newest first" do
    {:ok, first} = Sounds.save("a", "Pad")
    # (a second later, so the second has a later time)
    Process.sleep(1_100)
    {:ok, second} = Sounds.save("a", "Pad")
    assert first.path != second.path
    assert [%{path: p2}, %{path: p1}] = Sounds.list("obervave")
    assert {p2, p1} == {second.path, first.path}
  end

  test "a sound for another synth or backend is refused, naming the synth it is for", %{flash: flash} do
    {:ok, saved} = Sounds.save("a", "Mine")
    {:ok, running} = Sounds.running("a")

    shine = %{saved | firmware: %{saved.firmware | id: "shineon", name: "Shine On"}}
    assert {:error, msg} = Sounds.check(shine, running)
    assert msg =~ "Shine On"

    # the Hub package of the same firmware is another synth
    hub = %{saved | firmware: %{saved.firmware | id: "hub:obervave"}}
    assert {:error, _} = Sounds.check(hub, running)

    emu = %{saved | firmware: %{saved.firmware | backend: :emu}}
    assert {:error, _} = Sounds.check(emu, running)

    # a native memory of another length isn't this build's
    short = %{saved | bytes: binary_part(saved.bytes, 0, 4096)}
    assert {:error, _} = Sounds.check(short, running)
    # an empty memory (a reset, or its undo) fits any length; a running synth with an empty file takes any memory
    assert Sounds.check(%{saved | bytes: <<>>}, running) == :ok
    assert Sounds.check(short, %{running | flash_size: 0}) == :ok

    # nor does the instance take bytes for a firmware that isn't running (the flash is untouched)
    before = File.read!(flash)
    assert {:error, :wrong_synth} = Instance.restore("a", "shineon", :native, saved.bytes)
    assert {:error, :wrong_synth} = Instance.restore("a", "obervave", :emu, saved.bytes)
    assert File.read!(flash) == before

    # an import for Shine On while OberVave runs is refused and not added
    file = Path.join(System.tmp_dir!(), "shine_#{System.unique_integer([:positive])}.sound.json")
    File.cp!(saved.path, file)
    doc = file |> File.read!() |> JSON.decode!()
    doc = doc |> put_in(["firmware", "id"], "shineon") |> put_in(["firmware", "name"], "Shine On")
    File.write!(file, JSON.encode!(doc))
    assert {:error, msg} = Sounds.import(file, "a")
    assert msg =~ "Shine On"
    assert length(Sounds.list("obervave")) == 1
    File.rm(file)
  end

  test "another version of the same synth needs the player's say; an import of it is kept, marked", %{flash: flash} do
    {:ok, saved} = Sounds.save("a", "Old")
    changed = turn_cutoff(flash, 10)
    {:ok, running} = Sounds.running("a")
    old = %{saved | firmware: %{saved.firmware | version: "3.3.0"}}
    assert Sounds.check(old, running) == {:other_version, "3.3.0", "3.3.2"}
    assert Sounds.load("a", old) == {:other_version, "3.3.0", "3.3.2"}
    assert File.read!(flash) == changed
    assert :ok = Sounds.load("a", old, anyway: true)
    assert File.read!(flash) == saved.bytes

    file = Path.join(System.tmp_dir!(), "old_#{System.unique_integer([:positive])}.sound.json")
    doc = saved.path |> File.read!() |> JSON.decode!()
    File.write!(file, JSON.encode!(put_in(doc, ["firmware", "version"], "3.3.0")))
    assert {:ok, imported} = Sounds.import(file, "a")
    # it keeps when it was saved
    assert imported.saved_at == saved.saved_at
    assert Enum.any?(Sounds.list("obervave"), &(&1.firmware.version == "3.3.0"))
    File.rm(file)
  end

  test "a damaged or malformed sound is refused" do
    {:ok, saved} = Sounds.save("a", "Whole")
    doc = saved.path |> File.read!() |> JSON.decode!()
    reencode = &JSON.encode!/1

    assert {:ok, _} = Sounds.parse(reencode.(doc))

    <<first, rest::binary>> = saved.bytes
    bad_data = Base.encode64(<<Bitwise.bxor(first, 1), rest::binary>>)
    assert {:error, msg} = Sounds.parse(reencode.(put_in(doc, ["payload", "data"], bad_data)))
    assert msg =~ "SHA-256"

    assert {:error, _} = Sounds.parse(reencode.(put_in(doc, ["payload", "bytes"], 12)))
    assert {:error, _} = Sounds.parse(reencode.(put_in(doc, ["payload", "data"], "not base64!")))
    assert {:error, _} = Sounds.parse(reencode.(Map.delete(doc, "firmware")))
    assert {:error, _} = Sounds.parse(reencode.(put_in(doc, ["format"], "fmutate.layout/1")))
    assert {:error, _} = Sounds.parse("{nope")
  end

  test "an emulator memory must be whole records of distinct aligned sectors inside the flash" do
    {:ok, saved} = Sounds.save("a", "Emu")
    doc = saved.path |> File.read!() |> JSON.decode!() |> put_in(["firmware", "backend"], "emu")

    with_bytes = fn bytes ->
      doc
      |> put_in(["payload", "data"], Base.encode64(bytes))
      |> put_in(["payload", "bytes"], byte_size(bytes))
      |> put_in(["payload", "sha256"], :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower))
      |> JSON.encode!()
      |> Sounds.parse()
    end

    sector = :binary.copy(<<0xA5>>, 4096)
    record = fn offset -> <<offset::little-32, sector::binary>> end

    assert {:ok, %{firmware: %{backend: :emu}}} = with_bytes.(<<>>)
    assert {:ok, _} = with_bytes.(record.(0) <> record.(1_044_480))
    assert {:error, _} = with_bytes.(record.(0) <> <<0>>)
    assert {:error, _} = with_bytes.(record.(100))
    assert {:error, _} = with_bytes.(record.(1_048_576))
    assert {:error, _} = with_bytes.(record.(8192) <> record.(8192))
  end

  test "nothing is saved or loaded while the firmware switches", %{flash: flash} do
    {:ok, saved} = Sounds.save("a", "Before")
    before = File.read!(flash)
    assert :ok = Instance.switch_firmware("a", "shineon")
    assert {:error, :switching} = Instance.restore("a", "obervave", :native, saved.bytes)
    assert {:error, :switching} = Instance.snapshot("a")
    assert {:error, _} = Sounds.load("a", saved)
    await_running("shineon")
    assert File.read!(flash) == before
  end

  # (the engine's process is held while it is told to stop, so the load stays at that step; `meanwhile` runs
  # once it is held, before the load starts)
  defp holding_engine(fun, meanwhile \\ fn _engine -> :ok end) do
    %{live: %{pid: engine}} = :sys.get_state(Instance.via("a"))
    :sys.suspend(engine)
    meanwhile.(engine)
    task = Task.async(fun)
    await(fn -> :sys.get_state(Instance.via("a")).sound != nil end)
    {engine, task}
  end

  defp await(pred, tries \\ 200) do
    cond do
      pred.() -> :ok
      tries == 0 -> flunk("never")
      true ->
        Process.sleep(10)
        await(pred, tries - 1)
    end
  end

  test "a switch asked for while a load runs is refused; the load completes", %{flash: flash} do
    {:ok, saved} = Sounds.save("a", "Busy")
    turn_cutoff(flash, 15)
    {engine, task} = holding_engine(fn -> Sounds.load("a", saved) end)

    assert {:error, :busy} = Instance.switch_firmware("a", "shineon")
    assert {:error, :busy} = Instance.run_anyway("a")
    assert {:error, :busy} = Instance.snapshot("a")
    :sys.resume(engine)

    assert :ok = Task.await(task, 15_000)
    assert File.read!(flash) == saved.bytes
    assert %{phase: :running, firmware: "obervave"} = Instance.view("a")
  end

  test "an engine that doesn't end cleanly fails the load and leaves the memory as it was", %{flash: flash} do
    {:ok, saved} = Sounds.save("a", "Crash")
    changed = turn_cutoff(flash, 15)
    # it dies (its exit is seen before it is told to stop) instead of saving and ending
    die = fn engine ->
      System.cmd("kill", ["-9", "#{:sys.get_state(engine).os_pid}"])
      Process.sleep(200)
    end

    {engine, task} = holding_engine(fn -> Sounds.load("a", saved) end, die)
    :sys.resume(engine)

    assert {:error, msg} = Task.await(task, 15_000)
    assert msg =~ "didn't stop cleanly"
    assert File.read!(flash) == changed
    refute Sounds.undo?("a", "obervave", :native)
    assert %{phase: :running, firmware: "obervave"} = Instance.view("a")
  end

  # The instance again, its engine a script around the real one that does what the files in its directory ask,
  # once: `fail` exits 1 at once (with `lock` too, it first makes the flash directory read-only), `slow` waits 1 s
  # before starting the engine. (A snapshot or restore starts the same build again, so the script has to be the
  # build the instance started with.)
  defp fake_engine do
    real = Paths.native_lib_dir()
    dir = Path.join(Paths.data_dir(), "fake_lib")
    File.mkdir_p!(dir)
    for f <- ~w(libcart_obervave.so libcart_shineon.so), do: File.ln_s!(Path.join(real, f), Path.join(dir, f))
    engine = Path.join(dir, "libfm1engine.so")

    File.write!(engine, """
    #!/bin/sh
    d="#{dir}"
    if [ -e "$d/fail" ]; then
      rm "$d/fail"
      if [ -e "$d/lock" ]; then rm "$d/lock"; chmod 500 "$(dirname "$3")"; fi
      exit 1
    fi
    if [ -e "$d/slow" ]; then rm "$d/slow"; sleep 1; fi
    exec "#{Path.join(real, "libfm1engine.so")}" "$@"
    """)

    File.chmod!(engine, 0o755)
    Application.put_env(:fmutate_app, :native_lib_dir, dir)
    on_exit(fn -> Application.delete_env(:fmutate_app, :native_lib_dir) end)

    stop_supervised!({:instance, "a"})
    forget_instance()
    start_supervised!({Instance, id: "a"}, id: {:instance, "a"})
    Instance.subscribe("a", status: true)
    await_running("obervave")
    firmware_wait(500)
    dir
  end

  defp ask(dir, what), do: File.touch!(Path.join(dir, what))

  test "a loaded memory the firmware doesn't start on goes back to what it replaced", %{flash: flash} do
    fake = fake_engine()
    {:ok, saved} = Sounds.save("a", "Fails")
    changed = turn_cutoff(flash, 15)
    ask(fake, "fail")

    assert {:error, msg} = Sounds.load("a", saved)
    assert msg =~ "back as it was"
    assert File.read!(flash) == changed
    refute File.exists?(flash <> ".rollback")
    assert %{phase: :running, firmware: "obervave", restarts: 0} = Instance.view("a")
    # not a crash of the firmware's own: nothing counts towards its quarantine
    assert :sys.get_state(Instance.via("a")).failures == []
  end

  test "when the previous memory can't go back, nothing starts until it can (Run anyway)", %{flash: flash} do
    fake = fake_engine()
    {:ok, saved} = Sounds.save("a", "Stuck")
    changed = turn_cutoff(flash, 15)
    ask(fake, "lock")
    ask(fake, "fail")
    on_exit(fn -> File.chmod(Path.dirname(flash), 0o700) end)

    assert {:error, msg} = Sounds.load("a", saved)
    assert msg =~ "couldn't be put back"
    # it doesn't boot the failing memory again, and doesn't count it as the firmware's crash
    assert %{phase: :safe_mode, quarantined: false, restarts: 0} = Instance.view("a")
    assert :sys.get_state(Instance.via("a")).live == nil
    assert :sys.get_state(Instance.via("a")).failures == []
    assert File.read!(flash <> ".rollback") == changed

    File.chmod!(Path.dirname(flash), 0o700)
    assert :ok = Instance.run_anyway("a")
    await_running("obervave")
    assert File.read!(flash) == changed
    refute File.exists?(flash <> ".rollback")
  end

  test "quit before the loaded memory is READY puts the previous one back before it answers", %{flash: flash} do
    fake = fake_engine()
    {:ok, saved} = Sounds.save("a", "Quit")
    changed = turn_cutoff(flash, 15)
    ask(fake, "slow")

    task = Task.async(fn -> Sounds.load("a", saved) end)
    await(fn -> match?(%{sound: %{step: :booting, restored: true}}, :sys.get_state(Instance.via("a"))) end)
    assert :ok = Instance.quit("a")

    assert File.read!(flash) == changed
    refute File.exists?(flash <> ".rollback")
    assert {:error, "FMutate is quitting."} = Task.await(task)
  end

  test "a crash of the app before READY: the previous memory is back before the firmware next starts, and the crash " <>
         "isn't the firmware's",
       %{flash: flash} do
    {:ok, saved} = Sounds.save("a", "Crash")
    changed = turn_cutoff(flash, 15)
    # (what a restore leaves when the app dies between the replace and READY; in-process the crash marker names it)
    stop_supervised!({:instance, "a"})
    forget_instance()
    File.rename!(flash, flash <> ".rollback")
    File.write!(flash, saved.bytes)

    start_supervised!({Instance, id: "a", crashed: ["obervave"]}, id: {:instance, "a"})
    Instance.subscribe("a")
    await_running("obervave")
    assert File.read!(flash) == changed
    refute File.exists?(flash <> ".rollback")
    assert %{last_exit: nil, restarts: 0} = Instance.view("a")
    assert :sys.get_state(Instance.via("a")).app_crashes == %{}
  end

  test "a load into a synth that had no memory file, undone, leaves none: its sounds still load", %{flash: flash} do
    {:ok, saved} = Sounds.save("a", "Fresh")
    # (an unconfirmed restore over no file keeps an empty rollback)
    stop_supervised!({:instance, "a"})
    forget_instance()
    File.write!(flash <> ".rollback", "")

    start_supervised!({Instance, id: "a"}, id: {:instance, "a"})
    Instance.subscribe("a", status: true)
    await_running("obervave")
    refute File.exists?(flash <> ".rollback")
    {:ok, running} = Sounds.running("a")
    assert Sounds.check(saved, running) == :ok
    assert :ok = Sounds.load("a", saved)
  end

  test "a snapshot says which build ran and starts that build again", %{flash: _flash} do
    fake = fake_engine()
    %{live: %{run: run}} = :sys.get_state(Instance.via("a"))
    assert Path.dirname(run.file) == fake
    # the library would now start another build of the firmware
    Application.delete_env(:fmutate_app, :native_lib_dir)
    refute FMutate.Firmware.runnable("obervave").file == run.file

    {:ok, saved} = Sounds.save("a", "Build")
    assert %{id: "obervave", version: "3.3.2", backend: :native, commit: "792535d" <> _} = saved.firmware
    assert :sys.get_state(Instance.via("a")).live.run == run
  end

  test "a cartridge replaced at the same path (an update) is what a snapshot starts again, not the old run" do
    fake = fake_engine()
    %{live: %{run: old}} = :sys.get_state(Instance.via("a"))
    cart = Path.join(fake, "libcart_obervave.so")
    assert old.file == cart

    # an update renames a new file in at the same path: another inode, the old run's binary is gone
    File.cp!(cart, cart <> ".new")
    File.rename!(cart <> ".new", cart)
    refute FMutate.Firmware.stamp(cart) == old.stamp

    {:ok, _} = Sounds.save("a", "Updated")
    %{live: %{run: run}} = :sys.get_state(Instance.via("a"))
    assert run.file == cart and run.stamp == FMutate.Firmware.stamp(cart)
    refute run == old
  end

  test "the running build's capabilities stay in the view while a snapshot restarts its engine" do
    caps = Instance.view("a").caps
    assert caps.note_pressure
    forget_instance()
    {:ok, _} = Sounds.save("a", "Steady")

    views = for {:instance, "a", {:state, v}} <- drain(), do: v
    assert Enum.any?(views, &(&1.phase == :booting))
    assert Enum.all?(views, &(&1.caps == caps))
  end

  defp drain(acc \\ []) do
    receive do
      msg -> drain([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "Undo is checked as a load: another version asks, another length is refused", %{flash: flash} do
    {:ok, saved} = Sounds.save("a", "Undo")
    changed = turn_cutoff(flash, 15)
    assert :ok = Sounds.load("a", saved)
    undo = Paths.sound_undo("a", "obervave")
    kept = undo |> File.read!() |> :erlang.binary_to_term()
    assert kept.bytes == changed

    File.write!(undo, :erlang.term_to_binary(%{kept | version: "3.2.0"}))
    assert Sounds.undo("a") == {:other_version, "3.2.0", "3.3.2"}
    assert File.read!(flash) == saved.bytes

    File.write!(undo, :erlang.term_to_binary(%{kept | bytes: binary_part(changed, 0, 4096)}))
    assert {:error, _} = Sounds.undo("a")
    assert File.read!(flash) == saved.bytes

    File.write!(undo, :erlang.term_to_binary(%{kept | version: "3.2.0"}))
    assert :ok = Sounds.undo("a", anyway: true)
    assert File.read!(flash) == changed
  end

  test "an undo that can't be kept stops the load and leaves the last undo whole", %{flash: flash} do
    {:ok, first} = Sounds.save("a", "First")
    changed = turn_cutoff(flash, 15)
    assert :ok = Sounds.load("a", first)
    {:ok, second} = Sounds.save("a", "Second")

    undo_dir = Path.dirname(Paths.sound_undo("a", "obervave"))
    File.chmod!(undo_dir, 0o500)
    on_exit(fn -> File.chmod(undo_dir, 0o700) end)
    assert {:error, msg} = Sounds.load("a", second)
    assert msg =~ "Undo"
    assert File.read!(flash) == first.bytes

    File.chmod!(undo_dir, 0o700)
    assert :ok = Sounds.undo("a")
    assert File.read!(flash) == changed
  end

  test "no firmware id reaches outside its own directory of sounds" do
    root = Path.join(Paths.data_dir(), "sounds")

    for id <- ["..", ".", ".undo", "a/b", "hub:obervave"] do
      dir = Paths.sounds(id)
      assert Path.dirname(dir) == root
      refute Path.basename(dir) in [".", "..", ".undo"]
    end

    refute Paths.sounds("hub:obervave") == Paths.sounds("obervave")
  end

  test "sounds added at once with one name and time each get a file of their own" do
    {:ok, saved} = Sounds.save("a", "Same")

    results =
      1..8
      |> Enum.map(fn _ -> Task.async(fn -> Sounds.import(saved.path, "a") end) end)
      |> Enum.map(&Task.await/1)

    paths = for {:ok, s} <- results, do: s.path
    assert length(paths) == 8
    assert length(Enum.uniq([saved.path | paths])) == 9
    assert length(Sounds.list("obervave")) == 9

    for p <- paths do
      assert {:ok, %{bytes: bytes}} = Sounds.read(p)
      assert bytes == saved.bytes
    end
  end
end
