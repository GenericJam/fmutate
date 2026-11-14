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
  them (`"c"`), and a control that hasn't picked up the current value is ignored. `run_anyway` (a tap on
  the screen area in safe mode) is `FMutate.Instance.run_anyway/1`.
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
      bend: cap?(view.firmware, :pitch_bend),
      # pressing OCT− and OCT+ together sets the firmware's octave to 0 (strike-velocity strips start in step)
      oct0: cap?(view.firmware, :octave_reset_both),
      # the Opling's mood (docs/design/creature.md) and the message in the screen area
      quarantined: view.quarantined,
      restarts: view.restarts,
      slow: view[:slow] == true,
      speed: if(view[:slow] == true, do: view[:clock_pct] || 0, else: 0),
      hint: hint(view[:advice], view[:cpu_mhz]),
      editing: assigns[:editing] == true,
      page: assigns[:page] || "",
      toast: toast,
      toast_seq: toast_seq,
      add_menu: assigns[:add_menu] || ""
    }
  end

  # what the screen area says under "Too slow" (or alone: dropouts), from FMutate.Instance.Health.advice/1
  defp hint(:lowering, mhz), do: "Slowing the emulated CPU · #{mhz} MHz…"
  defp hint(:lower_in_io, mhz), do: "Lower the emulated CPU in I/O (#{mhz} MHz)"
  defp hint(:limit, _mhz), do: "This phone can't run it at full speed"
  defp hint(:raise_buffer, _mhz), do: "Raise the buffer in I/O"
  defp hint(_advice, _mhz), do: ""

  @impl true
  def handle_event("in", payload, socket) do
    {event, bindings} = arbitrate(socket.assigns.bindings, payload)
    if event, do: Instance.input(socket.assigns.instance, event)
    {:noreply, Mob.Socket.assign(socket, :bindings, bindings)}
  end

  # safe mode: a tap on the screen area is "Run anyway"
  def handle_event("run_anyway", _payload, socket) do
    _ = Instance.run_anyway(socket.assigns.instance)
    {:noreply, socket}
  end

  # the surface let go of fingers it never saw lift (a cancelled gesture, …): kept in the instance's journal
  def handle_event("diag", payload, socket) do
    Instance.note(socket.assigns.instance, payload)
    {:noreply, socket}
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

  defp cap?(firmware_id, cap) do
    case FMutate.Firmware.get(firmware_id) do
      %{caps: caps} -> Map.get(caps, cap, false)
      nil -> false
    end
  end
end
