defmodule FMutate.IONif do
  @moduledoc """
  The I/O bridge NIF (`c_src/fm1io.c`, statically linked on Android; `mob.exs` `:static_nifs`) between the
  BEAM and the Kotlin side (`fmutate/FMutateIO.kt`): MIDI ports, audio devices, the Bluetooth MIDI scan.
  Use `FMutate.IO` (device events) and `FMutate.MIDI` (MIDI routes), which own it.

  Messages it sends:

    * `{:fm1io, :midi, source, bytes, sent_ns, recv_ns}` to the pid routed for `source` (or the default
      route). `source` is `-1 - instance_index` for an instance's virtual port (`-1` = `"a"`) and
      `device_id * 16 + port` for an opened device's output port. `sent_ns` is the sender's timestamp,
      `recv_ns` when Kotlin got the bytes (both `CLOCK_MONOTONIC`, the clock of `now_ns/0`).
    * `{:fm1io, :event, json}` to the event subscriber: the Kotlin side's state (see `FMutate.IO`).

  On a host (tests, `mix run`) the NIF isn't there and every function raises; `loaded?/0` says which.
  """

  @on_load :load_nif

  @doc false
  def load_nif do
    case :erlang.load_nif(~c"fm1io", 0) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  @doc "True when the native side is linked in (on an Android device)."
  def loaded? do
    now_ns()
    true
  rescue
    ErlangError -> false
  end

  @doc "Send MIDI from `source` (an integer, or `:default` for unrouted sources) to `pid`."
  def route_midi(_source, _pid), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Remove a MIDI route."
  def unroute_midi(_source), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Send the Kotlin side's JSON events to `pid`."
  def subscribe_events(_pid), do: :erlang.nif_error(:nif_not_loaded)

  @doc "A JSON command to the Kotlin side (`FMutateIO.call`): `{:ok, json_reply}` or `{:error, reason}`."
  def call(_json), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Send MIDI bytes out of instance `port`'s virtual port (0 = `"a"`), stamped `timestamp_ns` (0 = now).
  `{:error, :no_listener}` when no app has the port open.
  """
  def midi_send(_port, _bytes, _timestamp_ns), do: :erlang.nif_error(:nif_not_loaded)

  @doc "`CLOCK_MONOTONIC` in ns, the clock of Android's `System.nanoTime` and of MIDI timestamps."
  def now_ns, do: :erlang.nif_error(:nif_not_loaded)
end
