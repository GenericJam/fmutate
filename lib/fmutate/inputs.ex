defmodule FMutate.Inputs do
  @moduledoc """
  The firmware's inputs by the design's names (HANDOFF §2, `layout.schema.json`) and their numbers on the
  engine wire (`docs/engine_protocol.md`, taken from the firmwares' own simulator API).
  """

  @buttons ~w(oct_down oct_up fx sel env lfo edit glo home save arp seq play rec)a
  # wire order: 0 select, 1 algorithm, 2-5 knob1-4, 6 presets
  @encoders ~w(select algorithm knob1 knob2 knob3 knob4 presets)a

  @doc "The 14 buttons, in wire order."
  def buttons, do: @buttons

  @doc "The 7 encoders, in wire order."
  def encoders, do: @encoders

  @doc "Wire number of a button (`:oct_down` → 0)."
  def button(id) when is_atom(id), do: index!(@buttons, id, :button)
  def button(id) when is_binary(id), do: button(atom!(id, @buttons))

  @doc "Wire number of an encoder (`:select` → 0, `:presets` → 6)."
  def encoder(id) when is_atom(id), do: index!(@encoders, id, :encoder)
  def encoder(id) when is_binary(id), do: encoder(atom!(id, @encoders))

  @doc "Button id for a wire number."
  def button_id(n) when n in 0..13, do: Enum.at(@buttons, n)

  @doc "Key 0..26 → MIDI note (key 0 is F3 = 53)."
  def key_note(key) when key in 0..26, do: 53 + key

  defp index!(list, id, kind) do
    Enum.find_index(list, &(&1 == id)) || raise ArgumentError, "unknown #{kind} #{inspect(id)}"
  end

  defp atom!(name, list) do
    Enum.find(list, &(Atom.to_string(&1) == name)) ||
      raise ArgumentError, "unknown input #{inspect(name)}"
  end
end
