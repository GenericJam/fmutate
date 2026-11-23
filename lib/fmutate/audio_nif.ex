defmodule FMutate.AudioNif do
  @moduledoc """
  The mixer NIF (`c_src/fm1audio.c` over `c_src/fm1mix.c`, statically linked; `mob.exs` `:static_nifs`): it
  registers the `mob_audio_io` processor `"fm1_mixer"`, which mixes the engines' shared-memory rings into the
  output stream `FMutate.Audio` opens with `MobAudioIo.open/3`. Use `FMutate.Audio`, which owns both.

  On a host build (tests, `mix run`) the NIF isn't there and every function raises `:nif_not_loaded`;
  `loaded?/0` says which.
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

  @doc "The processor's name (`c_src/fm1mix.c`'s `FM1MIX_PROCESSOR`), for `MobAudioIo.open/3`."
  def processor, do: "fm1_mixer"

  @doc "True when the native side is linked in (on a device) and its processor registered."
  def loaded? do
    stats()
    true
  rescue
    ErlangError -> false
  end

  @doc "Map an engine ring file into `slot` (0..3), silent until `gain/3`."
  def attach(_slot, _path), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Unmap the slot's ring (once the output's callback no longer reads it)."
  def detach(_slot), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Ramp the slot's gain to `permille`/1000 over `ramp_ms`."
  def gain(_slot, _permille, _ramp_ms), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The mixer's side: `%{frame, rate, peak, running, callbacks, fills, underruns}`. `frame` is the mixer clock
  in 44.1 kHz frames; `rate` the output's rate at its last start (44 100 before one); `peak` the loudest
  sample (0..32767) since the last call; `running` whether the output stream is started (its callbacks may
  run); `fills` and `underruns` per slot.
  """
  def stats, do: :erlang.nif_error(:nif_not_loaded)
end
