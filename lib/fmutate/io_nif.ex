defmodule FMutate.IONif do
  @moduledoc """
  The audio-output bridge NIF (`c_src/fm1io.c`, statically linked on Android; `mob.exs` `:static_nifs`)
  between the BEAM and the Kotlin side (`fmutate/FMutateIO.kt`). Use `FMutate.IO`, which owns it. MIDI goes
  through the mob_midi plugin (`MobMidi`), not this.

  It sends `{:fm1io, :event, json}` (the audio outputs, see `FMutate.IO`) to the event subscriber.

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
    loaded()
  rescue
    ErlangError -> false
  end

  @doc false
  def loaded, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Send the Kotlin side's JSON events to `pid`."
  def subscribe_events(_pid), do: :erlang.nif_error(:nif_not_loaded)

  @doc "A JSON command to the Kotlin side (`FMutateIO.call`): `{:ok, json_reply}` or `{:error, reason}`."
  def call(_json), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  What learned MIDI controls show on the instrument surface (`FMutateIO.surface`): text lines as
  `FMutate.MIDI.Controls.surface_text/1` makes them; `:ok` or `{:error, reason}`.
  """
  def surface(_text), do: :erlang.nif_error(:nif_not_loaded)
end
