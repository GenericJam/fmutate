defmodule FMutate.EngineNif do
  @moduledoc """
  Engines in the app process (iOS, where an app can't start processes): `c_src/fm1host.c`, statically linked
  (`mob.exs` `:static_nifs`, iOS only) with the engines themselves (`native/build_ios.sh`). Each engine runs on a
  thread of the app behind the messages a Port would carry; `FMutate.Engine` uses it in place of a Port when
  `available?/0` (docs/decisions/2026-11-13-ios-port.md).

  To the process that called `start/7`: `{ref, {:data, binary}}` for each message from the engine and
  `{ref, {:exit_status, code}}` when it ends (0 closed, 2 error, 3 the package halted, 134 a panic in the
  emulator, 137 killed, 139 the debug crash).

  Elsewhere (Android, hosts) the NIF isn't there and every function raises `:nif_not_loaded`.
  """

  @on_load :load_nif

  @doc false
  def load_nif do
    # Static NIFs ignore the path; a missing native side (Android, hosts) must not stop the module loading.
    case :erlang.load_nif(~c"fm1host", 0) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  @doc false
  # The tests on a Mac load native/build_ios.sh's host build (native/build/host/fm1host.so) to run engines
  # in-process as iOS does (test/fmutate/inproc_engine_test.exs). It doesn't make the app on the host run its
  # engines in-process (`available?/0` stays false): the other tests keep the executables. Loads once.
  def load_host(path) do
    if :persistent_term.get({__MODULE__, :host}, false) do
      :ok
    else
      with :ok <- :erlang.load_nif(String.to_charlist(Path.rootname(path)), 0),
           do: :persistent_term.put({__MODULE__, :host}, true)
    end
  end

  @doc "True when the app runs its engines in-process (the iOS build, where the NIF is linked in)."
  def available? do
    not :persistent_term.get({__MODULE__, :host}, false) and match?([_ | _], cartridges())
  rescue
    ErlangError -> false
  end

  @doc """
  Start an engine on a thread: `kind` `:native` (`file` is a cartridge id, `cartridges/0`) or `:emu` (`file` is a
  package path); `fill` the target ring fill in frames (0: the engine's default), `mhz` the emulated CPU's clock
  at start (0: 240; the native engine ignores it). `{:error, :busy}`: the cartridge's previous engine hasn't
  ended within 3 s; `{:error, :hung}`: one of its engines hung in firmware code, so it can't boot again until the
  app restarts.
  """
  def start(_ref, _kind, _file, _prefix, _flash, _fill, _mhz), do: :erlang.nif_error(:nif_not_loaded)

  @doc "One port message (`FMutate.Engine.Wire.encode/1`). `{:error, :closed}` after `close/1`."
  def command(_handle, _message), do: :erlang.nif_error(:nif_not_loaded)

  @doc "As `Port.close/1`: the engine saves its flash and ends with exit status 0."
  def close(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @doc "As kill -9: exit status 137 now; the thread is abandoned (it ends when it next looks, if ever)."
  def kill(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @doc "The cartridges linked in, `[{id, :ok | :hung}]`."
  def cartridges, do: :erlang.nif_error(:nif_not_loaded)

  @doc "From now on a fatal signal writes the ids of the cartridges running to `path` (one per line)."
  def crash_marker(_path), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  `fm1emu --bench` in the app: a package flat out for `seconds` of emulated time with a chord held, interpreted,
  at `mhz` (0: 240), on a thread like an engine's. `{:ok, report}` (lines of text) or `{:error, reason}`.
  """
  def bench(_package, _seconds, _mhz), do: :erlang.nif_error(:nif_not_loaded)
end
