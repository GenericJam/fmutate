defmodule FMutate.EmuEngineTest do
  # The emulator engine (`libfm1emu.so`, native/build_emu.sh) running a real firmware package from the FM-1
  # Firmware Hub (Dinghy: a 4-voice sine, silent until a key is down), through FMutate.Engine as the
  # instances run it. The host Audio drains the ring in real time, so firmware time advances.
  use ExUnit.Case, async: false

  alias FMutate.{Audio, Engine, Paths}

  @moduletag :emu

  @emu Path.expand("native/build/host/libfm1emu.so")
  @package Path.expand("native/build/packages/dinghy.fwsc")
  # (OberVave's Hub package: a firmware that needs more of the CPU than Dinghy)
  @obervave Path.expand("native/build/packages/obervave.fwsc")

  unless File.exists?(@emu) and File.exists?(@package) and File.exists?(@obervave) do
    @moduletag skip: "run native/build_emu.sh: no #{@emu}, #{@package} or #{@obervave}"
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "fmutate_emu_test_#{System.unique_integer([:positive])}")
    Application.put_env(:fmutate_app, :data_dir, dir)
    start_supervised!(Audio)

    on_exit(fn ->
      Application.delete_env(:fmutate_app, :data_dir)
      File.rm_rf(dir)
    end)

    prefix = Paths.shm_prefix("emu", 0)
    {:ok, prefix: prefix, flash: Paths.flash("emu", "dinghy", :emu)}
  end

  # `opts`: `:package` (Dinghy's by default), `:env` for the engine
  defp start_engine(ctx, opts \\ []) do
    {:ok, pid} =
      Engine.start_link(
        owner: self(),
        tag: :emu,
        bin: @emu,
        cart: Keyword.get(opts, :package, @package),
        prefix: ctx.prefix,
        flash: ctx.flash,
        env: Keyword.get(opts, :env, [])
      )

    assert_receive {:engine, ^pid, {:spawned, os_pid}}
    assert_receive {:engine, ^pid, {:ready, _ms}}, 5_000
    {:ok, slot} = Audio.claim()
    :ok = Audio.attach(slot, Paths.ring(ctx.prefix))
    on_exit(fn -> if Process.alive?(pid), do: Engine.kill9(pid) end)
    {pid, os_pid}
  end

  defp next_status(pid, timeout \\ 1_000) do
    assert_receive {:engine, ^pid, {:status, status}}, timeout
    status
  end

  # the status after `ms` more of wall time
  defp status_after(pid, ms) do
    deadline = System.monotonic_time(:millisecond) + ms
    Stream.repeatedly(fn -> next_status(pid) end) |> Enum.find(fn _ -> System.monotonic_time(:millisecond) >= deadline end)
  end

  # the ring's write index and the loudest sample of its last `frames` frames
  defp ring_peak(prefix, frames) do
    <<_::binary-16, w::little-64, _::binary-40, data::binary>> = File.read!(Paths.ring(prefix))
    cap = div(byte_size(data), 4)

    peak =
      for i <- max(w - frames, 0)..(w - 1)//1, reduce: 0 do
        acc ->
          <<l::little-signed-16, r::little-signed-16>> = binary_part(data, 4 * rem(i, cap), 4)
          acc |> max(abs(l)) |> max(abs(r))
      end

    {w, peak}
  end

  test "boots a package: the screen, the clock and the audio run; a key makes sound", ctx do
    {pid, _} = start_engine(ctx)
    first = next_status(pid)
    later = status_after(pid, 1_500)

    assert later.ms - first.ms in 1_000..2_000, "firmware time runs at about real time: #{inspect({first, later})}"
    assert later.fb_seq > 0
    assert <<0x46, 0x31, 0x4D, 0x46, _seq::little-32, pixels::binary-size(115_200), _leds::binary>> =
             File.read!(Paths.fb(ctx.prefix))

    assert pixels != :binary.copy(<<0, 0>>, 57_600), "the firmware drew something"

    {w0, quiet} = ring_peak(ctx.prefix, 1024)
    assert w0 > 44_100
    assert quiet < 64, "Dinghy is silent with no key down (#{quiet})"

    Engine.commands(pid, [{:key, 7, true}, {:key, 11, true}, {:key, 14, true}])
    status_after(pid, 600)
    {w1, loud} = ring_peak(ctx.prefix, 2048)
    assert w1 > w0
    assert loud > 2_000, "a chord is heard (peak #{loud})"

    Engine.commands(pid, [{:key, 7, false}, {:key, 11, false}, {:key, 14, false}])
    status_after(pid, 1_500)
    {_, after_release} = ring_peak(ctx.prefix, 1024)
    assert after_release < 64, "and stops when the keys are let go (#{after_release})"
  end

  test "the screen and the key LEDs follow the keys", ctx do
    {pid, _} = start_engine(ctx)
    before = status_after(pid, 1_000)
    assert before.led_keys == 0
    # (Dinghy shows the note and lights the keys that are down)
    Engine.commands(pid, [{:key, 7, true}, {:key, 11, true}])
    later = status_after(pid, 500)
    assert later.fb_seq > before.fb_seq
    assert later.led_keys == Bitwise.bsl(1, 7) + Bitwise.bsl(1, 11)
  end

  test "a crash in the firmware's process ends it with SIGSEGV", ctx do
    {pid, _} = start_engine(ctx)
    Engine.commands(pid, [:crash])
    assert_receive {:engine, ^pid, {:exit, {:signal, 11}}}, 2_000
  end

  test "a hung firmware is killed by the watchdog", ctx do
    {pid, _} = start_engine(ctx)
    Engine.commands(pid, [:hang])
    assert_receive {:engine, ^pid, {:exit, :hung}}, 3_000
  end

  test "kill -9 from outside is an exit like any other", ctx do
    {pid, _} = start_engine(ctx)
    Engine.kill9(pid)
    assert_receive {:engine, ^pid, {:exit, {:signal, 9}}}, 2_000
  end

  test "closing the port saves the flash and exits; a damaged flash file doesn't stop a boot", ctx do
    {pid, _} = start_engine(ctx)
    Engine.stop(pid)
    assert_receive {:engine, ^pid, {:exit, :stopped}}, 4_000
    # (nothing saved by the firmware yet: no sectors changed)
    assert File.read!(ctx.flash) == ""

    File.write!(ctx.flash, "not a flash file")
    {pid, _} = start_engine(ctx)
    assert next_status(pid).ms > 0
  end

  test "the target fill changes at runtime (op 0x07), clamped to the ring", ctx do
    {pid, _} = start_engine(ctx)
    assert status_after(pid, 1_500).fill <= 1024

    Engine.commands(pid, [{:fill, 3072}])
    assert status_after(pid, 1_000).fill > 2048

    Engine.commands(pid, [{:fill, 60_000}])
    fill = status_after(pid, 1_000).fill
    assert fill > 3072 and fill <= 3840
  end

  # firmware ms per wall ms (%) over `ms` of wall time
  defp speed(pid, ms) do
    {t0, s0} = {System.monotonic_time(:millisecond), next_status(pid)}
    s1 = status_after(pid, ms)
    {round((s1.ms - s0.ms) * 100 / (System.monotonic_time(:millisecond) - t0)), s1}
  end

  test "the CPU clock (op 0x08): a firmware too slow at 240 MHz keeps up at 80, its time and sound still right",
       ctx do
    # (interpreted, Dinghy runs at ~0.65x real time on this computer at 240 MHz, ~1.8x at 80: a slow phone)
    {pid, _} = start_engine(ctx, env: [{"FM1_NO_JIT", "1"}])
    Engine.commands(pid, [{:key, 7, true}, {:key, 11, true}, {:key, 14, true}])
    status_after(pid, 1_000)
    {slow, s} = speed(pid, 2_000)
    assert s.cpu_mhz == 240
    assert slow < 90, "slower than real time at 240 MHz (#{slow} %)"

    Engine.commands(pid, [{:cpu_mhz, 80}])
    status_after(pid, 1_000)
    {fast, s} = speed(pid, 2_000)
    assert s.cpu_mhz == 80
    assert fast in 95..105, "real time at 80 MHz (#{fast} %): the firmware's clock stays right"
    {_, loud} = ring_peak(ctx.prefix, 2048)
    assert loud > 2_000, "the chord still plays (peak #{loud})"

    # (clamped to what the engine takes)
    Engine.commands(pid, [{:cpu_mhz, 1_000}])
    assert status_after(pid, 300).cpu_mhz == 240
  end

  test "a firmware starved of cycles leaves DMA halves stale; at 240 MHz it doesn't", ctx do
    # (OberVave's package falls behind its own audio at 80 MHz with a chord: measured with --bench too)
    {pid, _} = start_engine(ctx, package: @obervave)
    Engine.commands(pid, [{:key, 7, true}, {:key, 11, true}, {:key, 14, true}])
    s0 = status_after(pid, 1_500)
    s1 = status_after(pid, 2_000)
    assert s1.stale == s0.stale, "none at 240 MHz (#{s0.stale} → #{s1.stale})"

    Engine.commands(pid, [{:cpu_mhz, 80}])
    s2 = status_after(pid, 500)
    s3 = status_after(pid, 2_000)
    assert s3.stale - s2.stale >= 10, "stale halves at 80 MHz (#{s2.stale} → #{s3.stale})"

    Engine.commands(pid, [{:cpu_mhz, 180}])
    s4 = status_after(pid, 500)
    s5 = status_after(pid, 2_000)
    assert s5.stale == s4.stale, "none again at 180 MHz (#{s4.stale} → #{s5.stale})"
  end

  test "a file that is no FM-1 package fails to boot", ctx do
    bad = Path.join(Paths.data_dir(), "bad.fwsc")
    File.write!(bad, :crypto.strong_rand_bytes(4096))

    {:ok, pid} =
      Engine.start_link(owner: self(), tag: :emu, bin: @emu, cart: bad, prefix: ctx.prefix, flash: ctx.flash)

    assert_receive {:engine, ^pid, {:exit, {:status, 2}}}, 5_000
  end
end
