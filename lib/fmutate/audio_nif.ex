defmodule FMutate.AudioNif do
  @moduledoc """
  The audio output NIF (`c_src/fm1audio.c`, statically linked; `mob.exs` `:static_nifs`): an AAudio
  stream that mixes the engines' shared-memory rings. Use `FMutate.Audio`, which owns it.

  On a host build (tests, `mix run`) the NIF isn't there and every function raises
  `:nif_not_loaded`; `loaded?/0` says which.
  """

  @on_load :load_nif

  @doc false
  def load_nif do
    # Static NIFs ignore the path; a missing native side (host builds) must not stop the module loading.
    case :erlang.load_nif(~c"fm1audio", 0) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  @doc "True when the native side is linked in (on a device)."
  def loaded? do
    stats()
    true
  rescue
    ErlangError -> false
  end

  @doc "Open and start the output stream."
  def start, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Close the output stream."
  def stop, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Map an engine ring file into `slot` (0..3), silent until `gain/3`."
  def attach(_slot, _path), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Unmap the slot's ring."
  def detach(_slot), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Ramp the slot's gain to `permille`/1000 over `ramp_ms`."
  def gain(_slot, _permille, _ramp_ms), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  `%{frame, rate, peak, latency_ms, xruns, running, sharing, fills, underruns}`. `frame` is the
  mixer clock in 44.1 kHz frames; `peak` the loudest sample (0..32767) since the last call.
  """
  def stats, do: :erlang.nif_error(:nif_not_loaded)
end
