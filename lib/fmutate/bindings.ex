defmodule FMutate.Bindings do
  @moduledoc """
  Two controls bound to one input (HANDOFF §6 rule 7), at play time.

    * **Encoders** are relative: every control's clicks are sent, so the deltas add up in the firmware.
    * **Absolute targets** (the master pot, a MIDI CC) hold one value. The last control to move it owns
      it; every other control bound to it is *stale* (drawn greyed out) and uses **pickup**: its moves are
      ignored until it reaches the current value (lands within `pickup/0` of it, or passes over it).

  Pure: the instrument view keeps one of these per surface (`FMutate.InstrumentView`) and the native
  surface mirrors it for drawing. Targets are keyed like the native side keys them (`"pot:master"`,
  `"cc:<channel>:<number>"`).
  """

  defstruct targets: %{}

  @type target :: String.t()
  @type control :: String.t()
  @type t :: %__MODULE__{targets: %{target => %{value: float, owner: control | nil, last: %{control => float}}}}

  # how close (0..1) a stale control must come to the current value to pick it up
  @pickup 0.04

  @doc "An empty arbiter."
  def new, do: %__MODULE__{}

  @doc "The pickup window."
  def pickup, do: @pickup

  @doc """
  `target` is at `value` (0..1) with no owner yet (the master pot as the instance has it): every control,
  including a learned hardware knob, has to pick it up; touch, which moves from the current value, does at
  once. A target some control has moved is left alone.
  """
  @spec seed(t, target, number) :: t
  def seed(%__MODULE__{} = state, target, value) do
    if Map.has_key?(state.targets, target),
      do: state,
      else: %{state | targets: Map.put(state.targets, target, %{value: value * 1.0, owner: nil, last: %{}})}
  end

  @doc """
  `control` moved absolute `target` to `value` (0..1): `{:send, value, state}` when it may set it (it owns
  the target, picked it up, or nobody has set it yet), `{:ignore, state}` while it still has to pick up.
  """
  @spec absolute(t, target, control, number) :: {:send, float, t} | {:ignore, t}
  def absolute(%__MODULE__{} = state, target, control, value) do
    value = value |> max(0.0) |> min(1.0) |> Kernel.*(1.0)

    case state.targets[target] do
      nil ->
        accept(state, target, control, value, %{})

      %{owner: ^control} = t ->
        accept(state, target, control, value, t.last)

      t ->
        if abs(value - t.value) <= @pickup or crossed?(t.last[control], value, t.value) do
          accept(state, target, control, value, t.last)
        else
          t = %{t | last: Map.put(t.last, control, value)}
          {:ignore, %{state | targets: Map.put(state.targets, target, t)}}
        end
    end
  end

  defp accept(state, target, control, value, last) do
    t = %{value: value, owner: control, last: Map.put(last, control, value)}
    {:send, value, %{state | targets: Map.put(state.targets, target, t)}}
  end

  # moving from `from` to `to` passed over `current`
  defp crossed?(nil, _to, _current), do: false
  defp crossed?(from, to, current), do: (from - current) * (to - current) <= 0

  @doc """
  A relative move: encoder clicks always go through, so two controls on one encoder add up.
  """
  @spec encoder(t, String.t(), control, integer) :: {:send, integer, t}
  def encoder(%__MODULE__{} = state, _encoder, _control, clicks) when is_integer(clicks), do: {:send, clicks, state}

  @doc "Whether `control` is stale on `target` (another control moved it last)."
  def stale?(%__MODULE__{} = state, target, control) do
    case state.targets[target] do
      %{owner: nil} -> false
      %{owner: owner} -> owner != control
      nil -> false
    end
  end

  @doc "The current value of a target, or nil if no control has set it."
  def value(%__MODULE__{} = state, target), do: get_in(state.targets, [target, :value])
end
