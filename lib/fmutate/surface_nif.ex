defmodule FMutate.SurfaceNif do
  @moduledoc """
  iOS: what learned MIDI controls show on the instrument surface, handed to the Swift surface's queue
  (`c_src/fm1surface.c`, statically linked on iOS; `ios/FMutateMidiSurface.swift`). `FMutate.MIDI` uses it
  where Android uses `FMutate.IONif.surface/1`.

  Elsewhere (Android, hosts) the NIF isn't there and every function raises; `loaded?/0` says which.
  """

  @on_load :load_nif

  @doc false
  def load_nif do
    # Static NIFs ignore the path; a missing native side (Android, hosts) must not stop the module loading.
    case :erlang.load_nif(~c"fm1surface", 0) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  @doc "True when the native side is linked in (on an iPhone)."
  def loaded? do
    loaded()
  rescue
    ErlangError -> false
  end

  @doc false
  def loaded, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Text lines as `FMutate.MIDI.Controls.surface_text/1` makes them; `:ok`."
  def surface(_text), do: :erlang.nif_error(:nif_not_loaded)
end
