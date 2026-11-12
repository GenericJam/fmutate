defmodule FMutate.Paths do
  @moduledoc """
  Where things live. On a device: the engine and cartridges in the APK's native library dir
  (`MOB_NATIVE_LIB_DIR`), state in the app's private data dir (`MOB_DATA_DIR`). On a host (tests,
  development) both come from application env, so the same code runs against a desktop build of the
  engine.
  """

  @doc "Directory holding `libfm1engine.so` and `libcart_<id>.so`."
  def native_lib_dir do
    System.get_env("MOB_NATIVE_LIB_DIR") || Application.get_env(:fmutate_app, :native_lib_dir) ||
      Path.expand("native/build/host", File.cwd!())
  end

  @doc "The app's private data directory."
  def data_dir do
    System.get_env("MOB_DATA_DIR") || Application.get_env(:fmutate_app, :data_dir) ||
      Path.join(System.tmp_dir!(), "fmutate")
  end

  def engine_bin, do: Path.join(native_lib_dir(), "libfm1engine.so")

  @doc "The emulator engine (fm1-emu behind the same protocol), for `.fwsc` packages."
  def emu_bin, do: Path.join(native_lib_dir(), "libfm1emu.so")

  @doc "Where downloaded and imported firmware packages are kept."
  def packages_dir, do: ensure(Path.join(data_dir(), "packages"))

  @doc "A bundled cartridge's path, or nil if this build doesn't carry it."
  def bundled_cart(firmware_id) do
    path = Path.join(native_lib_dir(), "libcart_#{firmware_id}.so")
    if File.exists?(path), do: path
  end

  @doc "Shared-memory prefix for an instance's engine slot (`<prefix>.ring`, `<prefix>.fb`)."
  def shm_prefix(instance, slot), do: Path.join(ensure(Path.join(data_dir(), "run")), "#{instance}#{slot}")

  def ring(prefix), do: prefix <> ".ring"
  def fb(prefix), do: prefix <> ".fb"

  @doc """
  The firmware's saved state (settings, patches) for one instance and backend:
  `flash/<instance>/<id>.bin` for a native cartridge, `flash/<instance>/emu/<id>.bin` for a package
  in the emulator. The two engines' flash files differ (the cartridge's own image vs fm1-emu's changed
  sectors), so one id never shares a file across backends.
  """
  def flash(instance, firmware_id, :native),
    do: Path.join(ensure(Path.join([data_dir(), "flash", instance])), "#{firmware_id}.bin")

  def flash(instance, firmware_id, :emu),
    do: Path.join(ensure(Path.join([data_dir(), "flash", instance, "emu"])), "#{firmware_id}.bin")

  @doc "Per-instance app state (current firmware, crash counts)."
  def instance_state(instance),
    do: Path.join(ensure(Path.join(data_dir(), "instances")), "#{instance}.term")

  # ── I/O (FMutate.IO, FMutate.MIDI, FMutate.Dist) ──

  @doc "Per-instance MIDI settings (clock mode, tempo, per-source channel)."
  def midi_settings(instance),
    do: Path.join(ensure(Path.join(data_dir(), "instances")), "#{instance}.midi.term")

  @doc "Device-level I/O state (MIDI devices to reopen)."
  def io_state, do: Path.join(ensure(data_dir()), "io.term")

  @doc """
  Distribution files: `sibling` (node, port and cookie for sibling apps, read by the Android provider
  `FMutateSiblingProvider`; the path is fixed there as `files/dist/sibling`) and `allowed.term`.
  """
  def dist_dir, do: ensure(Path.join(data_dir(), "dist"))

  @doc "The current layout of one instance for one firmware (HANDOFF §3, §5)."
  def layout(instance, firmware_id),
    do: Path.join(ensure(Path.join([data_dir(), "layouts", instance])), "#{firmware_id}.layout.json")

  defp ensure(dir) do
    File.mkdir_p!(dir)
    dir
  end
end
