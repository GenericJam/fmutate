defmodule FMutate.InprocEngineTest do
  # Engines on threads of the app, as on iOS (c_src/fm1host.c), run on this computer: native/build_ios.sh's host
  # target builds native/build/host/fm1host.so (macOS only; skipped until then).
  use ExUnit.Case, async: false

  alias FMutate.Engine.Wire
  alias FMutate.EngineNif

  @nif Path.expand("native/build/host/fm1host.so")
  @package Path.expand("native/build/packages/dinghy.fwsc")

  unless File.exists?(@nif) and File.exists?(@package) do
    @moduletag skip:
                 "run TARGETS=host native/build_ios.sh (macOS) and native/build_emu.sh: no #{@nif} or #{@package}"
  end

  setup_all do
    # (once per run; the NIF stays loaded)
    if File.exists?(@nif), do: :ok = EngineNif.load_host(@nif)
    :ok
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "fmutate_inproc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp start(ctx, name, kind, file) do
    ref = make_ref()
    prefix = Path.join(ctx.dir, name)
    flash = Path.join(ctx.dir, name <> ".bin")
    {:ok, handle} = EngineNif.start(ref, kind, file, prefix, flash, 0, 0)
    assert_receive {^ref, {:data, ready}}, 5_000
    {:ok, {:ready, ms}} = Wire.decode(ready)
    %{ref: ref, handle: handle, prefix: prefix, flash: flash, ready_ms: ms}
  end

  # play the ring out as the mixer would, for `ms`; returns the frames the engine wrote
  defp drain(eng, ms) do
    {:ok, f} = :file.open(eng.prefix <> ".ring", [:read, :write, :binary, :raw])
    {:ok, <<w0::little-64>>} = :file.pread(f, 16, 8)

    for _ <- 1..div(ms, 10) do
      {:ok, <<w::little-64>>} = :file.pread(f, 16, 8)
      :ok = :file.pwrite(f, 24, <<w::little-64>>)
      Process.sleep(10)
    end

    {:ok, <<w1::little-64>>} = :file.pread(f, 16, 8)
    :file.close(f)
    w1 - w0
  end

  defp exit_status(eng, timeout \\ 5_000) do
    ref = eng.ref

    receive do
      {^ref, {:exit_status, code}} -> code
      {^ref, {:data, _}} -> exit_status(eng, timeout)
    after
      timeout -> :timeout
    end
  end

  test "a cartridge stopped and started again boots fresh: its clock from 0, its flash saved and loaded",
       ctx do
    a = start(ctx, "a", :native, "obervave")
    assert drain(a, 1_000) > 30_000, "renders ahead of a draining mixer"
    :ok = EngineNif.close(a.handle)
    assert exit_status(a) == 0
    assert File.stat!(a.flash).size > 0

    # (same cartridge, same flash file: its globals were put back as before its first boot)
    b = start(ctx, "b", :native, "obervave")
    assert b.ready_ms == 0
    assert drain(b, 300) > 0
    :ok = EngineNif.close(b.handle)
    assert exit_status(b) == 0
  end

  test "two cartridges run side by side; one cartridge can't run twice, and a second start says so at once",
       ctx do
    obv = start(ctx, "obv", :native, "obervave")
    shn = start(ctx, "shn", :native, "shineon")
    assert drain(obv, 300) > 0 and drain(shn, 300) > 0

    {us, started} =
      :timer.tc(fn ->
        EngineNif.start(
          make_ref(),
          :native,
          "obervave",
          Path.join(ctx.dir, "x"),
          Path.join(ctx.dir, "x.bin"),
          0,
          0
        )
      end)

    assert started == {:error, :busy}
    assert us < 50_000

    for e <- [obv, shn], do: EngineNif.close(e.handle)
    assert exit_status(obv) == 0 and exit_status(shn) == 0
  end

  test "a firmware loop that really hangs: no STATUS, kill gives the thread back, the cartridge is hung until the loop ends",
       ctx do
    a = start(ctx, "a", :native, "shineon")
    drain(a, 200)
    flush(a.ref)
    :ok = EngineNif.command(a.handle, Wire.encode(:stall))
    t0 = System.monotonic_time(:millisecond)
    drain(a, 400)

    # (the engine's thread waits for a pass that doesn't come back: STATUS stops, as the watchdog expects)
    flush(a.ref)
    drain(a, 300)
    refute_received {_, {:data, <<0x82, _::binary>>}}

    :ok = EngineNif.kill(a.handle)
    assert exit_status(a, 1_000) == 137
    assert eventually(fn -> {"shineon", :hung} in EngineNif.cartridges() end, 2_000)

    assert {:error, :hung} =
             EngineNif.start(
               make_ref(),
               :native,
               "shineon",
               Path.join(ctx.dir, "y"),
               Path.join(ctx.dir, "y.bin"),
               0,
               0
             )

    # (other cartridges are unaffected)
    o = start(ctx, "o", :native, "obervave")
    EngineNif.close(o.handle)
    assert exit_status(o) == 0

    # the stall (4 s of firmware code) ends: its loop parks, sees the stop and leaves; the cartridge is free
    Process.sleep(max(0, t0 + 4_200 - System.monotonic_time(:millisecond)))
    assert eventually(fn -> {"shineon", :ok} in EngineNif.cartridges() end, 2_000)
    b = start(ctx, "b", :native, "shineon")
    assert drain(b, 300) > 0
    EngineNif.close(b.handle)
    assert exit_status(b) == 0
  end

  test "an Engine starting a cartridge whose engine is still ending waits for it without blocking its owner",
       ctx do
    opts = fn name ->
      [
        owner: self(),
        tag: name,
        bin: :inproc,
        backend: :native,
        cart: "obervave",
        prefix: Path.join(ctx.dir, name),
        flash: Path.join(ctx.dir, name <> ".bin")
      ]
    end

    {:ok, a} = FMutate.Engine.start_link(opts.("a"))
    assert_receive {:engine, ^a, {:ready, _}}, 5_000

    # a switch back to the same firmware: the new engine is asked for while the old one still runs
    {us, {:ok, b}} = :timer.tc(fn -> FMutate.Engine.start_link(opts.("b")) end)
    assert us < 50_000
    Process.sleep(300)
    refute_received {:engine, ^b, {:ready, _}}

    FMutate.Engine.stop(a)
    assert_receive {:engine, ^a, {:exit, :stopped}}, 3_000
    assert_receive {:engine, ^b, {:ready, _}}, 3_000
    FMutate.Engine.stop(b)
    assert_receive {:engine, ^b, {:exit, :stopped}}, 3_000
  end

  test "an Engine whose firmware loop really hangs is killed by its watchdog; the next one says :hung",
       ctx do
    opts = fn name ->
      [
        owner: self(),
        tag: name,
        bin: :inproc,
        backend: :native,
        cart: "shineon",
        prefix: Path.join(ctx.dir, name),
        flash: Path.join(ctx.dir, name <> ".bin")
      ]
    end

    {:ok, a} = FMutate.Engine.start_link(opts.("a"))
    assert_receive {:engine, ^a, {:ready, _}}, 5_000
    FMutate.Engine.commands(a, [:stall])
    assert_receive {:engine, ^a, {:exit, :hung}}, 2_500

    # (the restart the instance would make: it tries while the hung loop is seen, then gives up)
    {:ok, b} = FMutate.Engine.start_link(opts.("b"))
    assert_receive {:engine, ^b, {:exit, {:start_failed, :hung}}}, 3_000

    # (and the cartridge is free again once the 4 s stall is over)
    assert eventually(fn -> {"shineon", :ok} in EngineNif.cartridges() end, 4_000)
  end

  test "a real crash in a firmware's loop ends the app, leaving that cartridge's id in the crash marker",
       ctx do
    marker = Path.join(ctx.dir, "crash_marker")
    ebin = Path.dirname(:code.which(EngineNif))

    # (no `receive` in the script: an interpreted receive waiting for a message a NIF thread sends crashes OTP 29's
    # VM in its GC, erts_move_multi_frags; compiled receives, as the app's, don't)
    script = """
    :ok = FMutate.EngineNif.load_host(#{inspect(@nif)})
    :ok = FMutate.EngineNif.crash_marker(#{inspect(marker)})
    ref = make_ref()
    {:ok, _} = FMutate.EngineNif.start(ref, :emu, #{inspect(@package)}, #{inspect(Path.join(ctx.dir, "e"))}, #{inspect(Path.join(ctx.dir, "e.bin"))}, 0, 0)
    {:ok, h} = FMutate.EngineNif.start(ref, :native, "obervave", #{inspect(Path.join(ctx.dir, "c"))}, #{inspect(Path.join(ctx.dir, "c.bin"))}, 0, 0)
    Process.sleep(300)
    :ok = FMutate.EngineNif.command(h, FMutate.Engine.Wire.encode(:segv))
    {:ok, f} = :file.open(#{inspect(Path.join(ctx.dir, "c.ring"))}, [:read, :write, :binary, :raw])
    for _ <- 1..100 do
      {:ok, <<w::little-64>>} = :file.pread(f, 16, 8)
      :ok = :file.pwrite(f, 24, <<w::little-64>>)
      Process.sleep(10)
    end
    IO.puts("still alive")
    """

    {out, status} = System.cmd("elixir", ["-pa", ebin, "-e", script], stderr_to_stdout: true)
    refute out =~ "still alive"
    # (SIGSEGV: 128 + 11)
    assert status == 139, out
    # (only the firmware that crashed: the emulator engine running beside it isn't named)
    assert FMutate.CrashMarker.take(marker) == ["obervave"]
    refute File.exists?(marker)
  end

  test "kill ends a hung engine at once (137) and its cartridge boots again", ctx do
    a = start(ctx, "a", :native, "shineon")
    :ok = EngineNif.command(a.handle, Wire.encode(:hang))
    drain(a, 200)
    :ok = EngineNif.kill(a.handle)
    assert exit_status(a, 1_000) == 137

    # (the debug hang let go when killed: the thread ends and gives the cartridge back)
    Process.sleep(300)
    assert {"shineon", :ok} in EngineNif.cartridges()
    b = start(ctx, "b", :native, "shineon")
    :ok = EngineNif.close(b.handle)
    assert exit_status(b) == 0
  end

  test "the debug crash ends the engine as a SIGSEGV would (139), without saving the flash",
       ctx do
    a = start(ctx, "a", :native, "obervave")
    :ok = EngineNif.command(a.handle, Wire.encode(:crash))
    drain(a, 200)
    assert exit_status(a) == 139
    refute File.exists?(a.flash)
  end

  test "a package runs in-process and stops with its flash saved", ctx do
    e = start(ctx, "e", :emu, @package)
    assert drain(e, 1_000) > 30_000
    :ok = EngineNif.close(e.handle)
    assert exit_status(e) == 0
    assert File.exists?(e.flash)
  end

  defp flush(ref) do
    receive do
      {^ref, _} -> flush(ref)
    after
      0 -> :ok
    end
  end

  defp eventually(f, ms) do
    cond do
      f.() -> true
      ms <= 0 -> false
      true -> Process.sleep(50) && eventually(f, ms - 50)
    end
  end
end
