defmodule FMutate.PanelEdgesTest.Rig do
  # An engine through FMutate.Engine as the instances run it, its ring drained by the host Audio in real time (so
  # firmware time advances), and what the tests below read back: STATUS, the button LEDs, the ring's loudest sample.
  import ExUnit.Assertions

  alias FMutate.{Audio, Engine, Paths}

  def setup_data_dir(name) do
    dir = Path.join(System.tmp_dir!(), "fmutate_#{name}_test_#{System.unique_integer([:positive])}")
    Application.put_env(:fmutate_app, :data_dir, dir)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:fmutate_app, :data_dir)
      File.rm_rf(dir)
    end)
  end

  # started, attached to the mixer, and past the firmware's boot screen (OberVave's stands 2.4 s): input from here
  # on goes to the instrument
  def start_engine(bin, file, prefix, flash, boot_ms) do
    {:ok, pid} = Engine.start_link(owner: self(), tag: :edges, bin: bin, cart: file, prefix: prefix, flash: flash)
    assert_receive {:engine, ^pid, {:ready, _ms}}, 5_000
    {:ok, slot} = Audio.claim()
    :ok = Audio.attach(slot, Paths.ring(prefix))
    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(pid), do: Engine.kill9(pid) end)
    Stream.repeatedly(fn -> next_status(pid) end) |> Enum.find(&(&1.ms >= boot_ms))
    pid
  end

  def next_status(pid, timeout \\ 1_000) do
    assert_receive {:engine, ^pid, {:status, status}}, timeout
    status
  end

  # the status after `ms` more of wall time
  def status_after(pid, ms) do
    deadline = System.monotonic_time(:millisecond) + ms
    Stream.repeatedly(fn -> next_status(pid) end) |> Enum.find(fn _ -> System.monotonic_time(:millisecond) >= deadline end)
  end

  # the loudest sample the engine writes into its ring over the next `ms` of wall time (the ring holds ~93 ms:
  # read every 10 ms, each time what was written since)
  def peak_during(prefix, ms) do
    deadline = System.monotonic_time(:millisecond) + ms
    {w0, _} = ring(prefix)
    peak_from(prefix, w0, 0, deadline)
  end

  defp peak_from(prefix, from, peak, deadline) do
    Process.sleep(10)
    {w, data} = ring(prefix)
    cap = div(byte_size(data), 4)

    peak =
      for i <- max(from, w - cap)..(w - 1)//1, reduce: peak do
        acc ->
          <<l::little-signed-16, r::little-signed-16>> = binary_part(data, 4 * rem(i, cap), 4)
          acc |> max(abs(l)) |> max(abs(r))
      end

    if System.monotonic_time(:millisecond) >= deadline, do: peak, else: peak_from(prefix, w, peak, deadline)
  end

  defp ring(prefix) do
    <<_::binary-16, w::little-64, _::binary-40, data::binary>> = File.read!(Paths.ring(prefix))
    {w, data}
  end

  def tap(b), do: [{:button, b, true}, {:button, b, false}]
end

defmodule FMutate.PanelEdgesTest do
  # Panel input whose press and release reach the engine together (one batch of port messages: a quick tap, a busy
  # phone) still reaches the firmware, as the device's own debounced matrix would deliver it: each key's and each
  # button's edges are queued and spaced in firmware time (docs/engine_protocol.md, "Panel edges"). The native
  # engine running the OberVave cartridge (native/build_host.sh).
  use ExUnit.Case, async: false

  import Bitwise
  import FMutate.PanelEdgesTest.Rig

  alias FMutate.{Audio, Engine, Paths}

  @moduletag :engine

  # OberVave: OCT- / OCT+ step the octave (-2..2); their LEDs show it below / above 0, both pressed is octave 0
  @oct_down 0
  @oct_up 1

  setup do
    unless File.exists?(Paths.engine_bin()), do: raise("run native/build_host.sh first: no #{Paths.engine_bin()}")
    setup_data_dir("edges")
    start_supervised!(Audio)
    prefix = Paths.shm_prefix("edges", 0)
    flash = Paths.flash("edges", "obervave", :native)
    pid = start_engine(Paths.engine_bin(), Paths.bundled_cart("obervave"), prefix, flash, 3_000)
    {:ok, pid: pid, prefix: prefix}
  end

  test "a key pressed and let go in one batch is played", %{pid: pid, prefix: prefix} do
    quiet = peak_during(prefix, 300)
    assert quiet < 64, "OberVave is silent with no key down (#{quiet})"
    Engine.commands(pid, [{:key, 12, true}, {:key, 12, false}])
    loud = peak_during(prefix, 500)
    assert loud > 1_000, "the tap is heard (peak #{loud})"
  end

  test "a button tapped twice in one batch counts twice", %{pid: pid} do
    Engine.commands(pid, tap(@oct_up) ++ tap(@oct_up))
    status_after(pid, 300)
    Engine.commands(pid, tap(@oct_down))
    s = status_after(pid, 300)
    assert (s.led_buttons &&& 3) == 1 <<< @oct_up, "octave 2, then 1: above 0 (LEDs #{inspect(s.led_buttons, base: :binary)})"
  end

  test "taps of different buttons in one batch reach the firmware together", %{pid: pid} do
    Engine.commands(pid, tap(@oct_up))
    s = status_after(pid, 300)
    assert (s.led_buttons &&& 3) == 1 <<< @oct_up, "octave 1"
    # OCT- and OCT+ down in the same scan: octave 0 (one after the other would step down to 0 and back up to 1)
    Engine.commands(pid, tap(@oct_down) ++ tap(@oct_up))
    s = status_after(pid, 300)
    assert (s.led_buttons &&& 3) == 0, "both at once: octave 0 (LEDs #{inspect(s.led_buttons, base: :binary)})"
  end
end

defmodule FMutate.EmuPanelEdgesTest do
  # The same through the emulator engine (native/build_emu.sh): keys with Dinghy (a 4-voice sine, silent until a
  # key is down), buttons with OberVave's package (its octave LEDs, as the native cartridge's above).
  use ExUnit.Case, async: false

  import Bitwise
  import FMutate.PanelEdgesTest.Rig

  alias FMutate.{Audio, Engine, Paths}

  @moduletag :emu

  @emu Path.expand("native/build/host/libfm1emu.so")
  @dinghy Path.expand("native/build/packages/dinghy.fwsc")
  @obervave Path.expand("native/build/packages/obervave.fwsc")

  unless File.exists?(@emu) and File.exists?(@dinghy) and File.exists?(@obervave) do
    @moduletag skip: "run native/build_emu.sh: no #{@emu}, #{@dinghy} or #{@obervave}"
  end

  @oct_down 0
  @oct_up 1

  setup do
    setup_data_dir("emu_edges")
    start_supervised!(Audio)
    {:ok, prefix: Paths.shm_prefix("emu_edges", 0)}
  end

  defp start(prefix, id, package), do: start_engine(@emu, package, prefix, Paths.flash("emu_edges", id, :emu), 3_000)

  test "a key pressed and let go in one batch is played", %{prefix: prefix} do
    pid = start(prefix, "dinghy", @dinghy)
    quiet = peak_during(prefix, 300)
    assert quiet < 64, "Dinghy is silent with no key down (#{quiet})"
    Engine.commands(pid, [{:key, 12, true}, {:key, 12, false}])
    loud = peak_during(prefix, 500)
    assert loud > 1_000, "the tap is heard (peak #{loud})"
  end

  test "a button tapped twice in one batch counts twice", %{prefix: prefix} do
    pid = start(prefix, "obervave", @obervave)
    Engine.commands(pid, tap(@oct_up) ++ tap(@oct_up))
    status_after(pid, 300)
    Engine.commands(pid, tap(@oct_down))
    s = status_after(pid, 300)
    assert (s.led_buttons &&& 3) == 1 <<< @oct_up, "octave 2, then 1: above 0 (LEDs #{inspect(s.led_buttons, base: :binary)})"
  end

  test "taps of different buttons in one batch reach the firmware together", %{prefix: prefix} do
    pid = start(prefix, "obervave", @obervave)
    Engine.commands(pid, tap(@oct_up))
    s = status_after(pid, 300)
    assert (s.led_buttons &&& 3) == 1 <<< @oct_up, "octave 1"
    Engine.commands(pid, tap(@oct_down) ++ tap(@oct_up))
    s = status_after(pid, 300)
    assert (s.led_buttons &&& 3) == 0, "both at once: octave 0 (LEDs #{inspect(s.led_buttons, base: :binary)})"
  end
end
