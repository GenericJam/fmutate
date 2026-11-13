defmodule FMutate.InprocEngineTest do
  # Engines on threads of the app, as on iOS (c_src/fm1host.c), run on this computer: native/build_ios.sh's host
  # target builds native/build/host/fm1host.so (macOS only; skipped until then).
  use ExUnit.Case, async: false

  alias FMutate.Engine.Wire
  alias FMutate.EngineNif

  @nif Path.expand("native/build/host/fm1host.so")
  @package Path.expand("native/build/packages/dinghy.fwsc")

  unless File.exists?(@nif) and File.exists?(@package) do
    @moduletag skip: "run TARGETS=host native/build_ios.sh (macOS) and native/build_emu.sh: no #{@nif} or #{@package}"
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

  test "a cartridge stopped and started again boots fresh: its clock from 0, its flash saved and loaded", ctx do
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

  test "two cartridges run side by side; one cartridge can't run twice", ctx do
    obv = start(ctx, "obv", :native, "obervave")
    shn = start(ctx, "shn", :native, "shineon")
    assert drain(obv, 300) > 0 and drain(shn, 300) > 0

    started = EngineNif.start(make_ref(), :native, "obervave", Path.join(ctx.dir, "x"), Path.join(ctx.dir, "x.bin"), 0, 0)
    assert started == {:error, :busy}

    for e <- [obv, shn], do: EngineNif.close(e.handle)
    assert exit_status(obv) == 0 and exit_status(shn) == 0
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

  test "the debug crash ends the engine as a SIGSEGV would (139), without saving the flash", ctx do
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
end
