defmodule FMutate.InstrumentView do
  @moduledoc """
  The instrument surface: a native view (android `fmutate/InstrumentView.kt`) that draws a layout, plays
  it with multitouch, and reads the firmware's screen and LEDs from shared memory. This component passes it
  the layout and the screen file, and turns its events into instance inputs.

  Props: `:instance` (id), `:layout` (JSON text), `:view` (`FMutate.Instance.view/1`), `:owner` (the screen
  pid, which gets `{:instrument, event, payload}` for everything that isn't an input: menu, pages, edit,
  page, use_classic and the edit-mode events of `FMutate.Editor`), `:editing` (edit mode on), `:page` (the
  page id to show), `:toast` (`{seq, text}` or nil: a short message drawn over the surface), `:add_menu`
  (JSON text of the open "Add here" menu, or "").

  Inputs go through `FMutate.Bindings` (HANDOFF §6 rule 7): absolute moves carry the control that made
  them (`"c"`), and a control that hasn't picked up the current value is ignored.
  """

  use Mob.Component

  alias FMutate.{Bindings, Inputs, Instance}

  @impl true
  def mount(props, socket) do
    keys = [:instance, :layout, :view, :owner, :editing, :page, :toast, :add_menu]
    socket = Mob.Socket.assign(socket, Map.take(props, keys))
    socket = if Map.has_key?(socket.assigns, :bindings), do: socket, else: Mob.Socket.assign(socket, :bindings, Bindings.new())
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    view = assigns.view
    {toast_seq, toast} = assigns[:toast] || {0, ""}

    %{
      layout: assigns.layout,
      fb: view.fb,
      phase: to_string(view.phase),
      master: view.master,
      bend: pitch_bend?(view.firmware),
      # the Opling's mood (docs/design/creature.md)
      quarantined: view.quarantined,
      restarts: view.restarts,
      editing: assigns[:editing] == true,
      page: assigns[:page] || "",
      toast: toast,
      toast_seq: toast_seq,
      add_menu: assigns[:add_menu] || ""
    }
  end

  @impl true
  def handle_event("in", payload, socket) do
    {event, bindings} = arbitrate(socket.assigns.bindings, payload)
    if event, do: Instance.input(socket.assigns.instance, event)
    {:noreply, Mob.Socket.assign(socket, :bindings, bindings)}
  end

  def handle_event(event, payload, socket) do
    send(socket.assigns.owner, {:instrument, event, payload})
    {:noreply, socket}
  end

  @doc """
  A native input payload through rule 7: `{instance_input | nil, bindings}`. Absolute moves (`pot`, and
  MIDI CC sent with `"abs"`/`"v"`) from a control (`"c"`) that hasn't picked up the value are dropped.
  """
  def arbitrate(bindings, %{"t" => "pot", "v" => v, "c" => c} = payload) when is_number(v) do
    case Bindings.absolute(bindings, "pot:master", c, v) do
      {:send, v, b} -> {decode(%{payload | "v" => v}), b}
      {:ignore, b} -> {nil, b}
    end
  end

  def arbitrate(bindings, %{"t" => "midi", "abs" => key, "v" => v, "c" => c} = payload) when is_number(v) do
    case Bindings.absolute(bindings, key, c, v) do
      {:send, _v, b} -> {decode(payload), b}
      {:ignore, b} -> {nil, b}
    end
  end

  def arbitrate(bindings, %{"t" => "encoder", "id" => id, "clicks" => n, "c" => c} = payload) when is_integer(n) do
    {:send, _n, b} = Bindings.encoder(bindings, id, c, n)
    {decode(payload), b}
  end

  def arbitrate(bindings, payload), do: {decode(payload), bindings}

  @doc false
  # native payload → FMutate.Instance input (see FMutate.Instance's module doc)
  def decode(%{"t" => "key", "k" => k, "d" => d}) when k in 0..26, do: {:key, k, dir(d)}
  # input ids are looked up in FMutate.Inputs, not String.to_existing_atom/1: on a device modules load lazily,
  # so the atoms may not exist yet when the first touch arrives (and an unknown id must not crash the view)
  def decode(%{"t" => "button", "id" => id, "d" => d}) do
    case input_id(id, Inputs.buttons()) do
      nil -> nil
      b -> {:button, b, dir(d)}
    end
  end

  def decode(%{"t" => "encoder", "id" => id, "clicks" => n}) when is_integer(n) do
    case input_id(id, Inputs.encoders()) do
      nil -> nil
      e -> {:encoder, e, n}
    end
  end

  def decode(%{"t" => "pot", "v" => v}) when is_number(v), do: {:pot, :master, v / 1}

  def decode(%{"t" => "midi", "bytes" => bytes}) when is_list(bytes),
    do: {:midi, :binary.list_to_bin(Enum.map(bytes, &Bitwise.band(&1, 0xFF)))}

  def decode(_), do: nil

  defp input_id(name, ids), do: Enum.find(ids, &(Atom.to_string(&1) == name))

  defp dir(true), do: :down
  defp dir(false), do: :up

  defp pitch_bend?(firmware_id) do
    case FMutate.Firmware.get(firmware_id) do
      %{caps: caps} -> Map.get(caps, :pitch_bend, false)
      nil -> false
    end
  end
end
