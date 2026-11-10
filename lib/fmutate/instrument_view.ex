defmodule FMutate.InstrumentView do
  @moduledoc """
  The instrument surface: a native view (android `fmutate/InstrumentView.kt`) that draws a layout, plays
  it with multitouch, and reads the firmware's screen and LEDs from shared memory. This component passes it
  the layout and the screen file, and turns its events into instance inputs.

  Props: `:instance` (id), `:layout` (JSON text), `:view` (`FMutate.Instance.view/1`), `:owner` (the screen
  pid, which gets `{:instrument, event, payload}` for everything that isn't an input: menu, pages, edit,
  page, use_classic).
  """

  use Mob.Component

  alias FMutate.Instance

  @impl true
  def mount(props, socket) do
    {:ok, Mob.Socket.assign(socket, Map.take(props, [:instance, :layout, :view, :owner]))}
  end

  @impl true
  def render(assigns) do
    view = assigns.view

    %{
      layout: assigns.layout,
      fb: view.fb,
      phase: to_string(view.phase),
      master: view.master,
      bend: pitch_bend?(view.firmware)
    }
  end

  @impl true
  def handle_event("in", payload, socket) do
    case decode(payload) do
      nil -> :ok
      event -> Instance.input(socket.assigns.instance, event)
    end

    {:noreply, socket}
  end

  def handle_event(event, payload, socket) do
    send(socket.assigns.owner, {:instrument, event, payload})
    {:noreply, socket}
  end

  @doc false
  # native payload → FMutate.Instance input (see FMutate.Instance's module doc)
  def decode(%{"t" => "key", "k" => k, "d" => d}) when k in 0..26, do: {:key, k, dir(d)}
  def decode(%{"t" => "button", "id" => id, "d" => d}), do: {:button, String.to_existing_atom(id), dir(d)}

  def decode(%{"t" => "encoder", "id" => id, "clicks" => n}) when is_integer(n),
    do: {:encoder, String.to_existing_atom(id), n}

  def decode(%{"t" => "pot", "v" => v}) when is_number(v), do: {:pot, :master, v / 1}

  def decode(%{"t" => "midi", "bytes" => bytes}) when is_list(bytes),
    do: {:midi, :binary.list_to_bin(Enum.map(bytes, &Bitwise.band(&1, 0xFF)))}

  def decode(_), do: nil

  defp dir(true), do: :down
  defp dir(false), do: :up

  defp pitch_bend?(firmware_id) do
    case FMutate.Firmware.get(firmware_id) do
      %{caps: caps} -> Map.get(caps, :pitch_bend, false)
      nil -> false
    end
  end
end
