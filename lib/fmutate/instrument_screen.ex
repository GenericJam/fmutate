defmodule FMutate.InstrumentScreen do
  @moduledoc """
  The instrument (HANDOFF §4, P1-a): the current layout full screen. The creature button is the only app
  chrome: tap → menu (Library, Edit layout, I/O, Pair an app), long-press → page grid.
  """

  use Mob.Screen

  require FMutate.Subscription

  alias FMutate.{Editor, Instance, Subscription}

  @instance "a"
  @editor_events Editor.events()

  def mount(_params, _session, socket) do
    # a placeholder until the instance is up (it arrives through the subscription)
    view =
      case Subscription.subscribe(:instance, Instance.via(@instance), fn -> Instance.subscribe(@instance) end) do
        {:ok, view} -> view
        :pending -> placeholder_view()
      end

    socket =
      socket
      |> Mob.Socket.assign(instance: @instance, view: view, menu: false, editing: false)
      # layout editing: the layout for the running firmware, pages, sheets (FMutate.Editor)
      |> Editor.load(@instance, view.firmware)

    {:ok, socket}
  end

  def render(assigns) do
    instrument =
      Mob.UI.native_view(FMutate.InstrumentView,
        id: :instrument,
        instance: assigns.instance,
        layout: assigns.layout_json,
        view: assigns.view,
        owner: self(),
        editing: assigns.editing,
        page: assigns.page,
        toast: assigns.toast,
        add_menu: Editor.add_menu_json(assigns)
      )

    dismiss = {self(), :menu}
    library = {self(), :library}
    edit = {self(), :edit}
    io = {self(), :io}
    pair = {self(), :pair}
    editor_sheets = Editor.sheets(assigns)

    ~MOB"""
    <Box background="#14121A" padding={0} fill_width={true} fill_height={true}>
      {instrument}
      <Sheet id="menu" detents={[:content]} on_dismiss={dismiss} background="#1C1925" :if={@menu}>
        <Column padding={20} gap={10}>
          <Button text="Library" on_tap={library} background="#221F2B" text_color="#F3EFF8" />
          <Button text="Edit layout" on_tap={edit} background="#221F2B" text_color="#F3EFF8" />
          <Button text="I/O" on_tap={io} background="#221F2B" text_color="#F3EFF8" />
          <Button text="Pair an app" on_tap={pair} background="#221F2B" text_color="#F3EFF8" />
        </Column>
      </Sheet>
      {editor_sheets}
    </Box>
    """
    |> FMutate.Style.native_colors()
  end

  def handle_info({:instance, @instance, {:state, view}}, socket),
    do: {:noreply, socket |> Mob.Socket.assign(:view, view) |> Editor.firmware(view.firmware)}

  def handle_info({:instance, _id, _event}, socket), do: {:noreply, socket}

  # the instance restarted (or wasn't up at mount): subscribed again, with its current view
  def handle_info(msg, socket) when Subscription.message?(msg) do
    case Subscription.handle(msg) do
      {:subscribed, :instance, view} -> handle_info({:instance, @instance, {:state, view}}, socket)
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:instrument, "menu", _}, socket), do: {:noreply, Mob.Socket.assign(socket, :menu, true)}

  # layout editing, pages and their sheets
  def handle_info({:instrument, event, payload}, socket) when event in @editor_events,
    do: {:noreply, Editor.event(event, payload, socket)}

  def handle_info({kind, {:editor, _} = tag}, socket) when kind in [:tap, :dismiss],
    do: {:noreply, Editor.dispatch(kind, tag, nil, socket)}

  def handle_info({kind, {:editor, _} = tag, value}, socket) when kind in [:change, :submit],
    do: {:noreply, Editor.dispatch(kind, tag, value, socket)}

  def handle_info({:instrument, _event, _payload}, socket), do: {:noreply, socket}

  def handle_info({:dismiss, :menu}, socket), do: {:noreply, Mob.Socket.assign(socket, :menu, false)}

  def handle_info({:tap, :library}, socket),
    do: {:noreply, socket |> Mob.Socket.assign(:menu, false) |> Mob.Socket.push_screen(FMutate.LibraryScreen)}

  def handle_info({:tap, :io}, socket),
    do: {:noreply, socket |> Mob.Socket.assign(:menu, false) |> Mob.Socket.push_screen(FMutate.IOScreen)}

  def handle_info({:tap, :pair}, socket),
    do:
      {:noreply,
       socket |> Mob.Socket.assign(:menu, false) |> Mob.Socket.push_screen(FMutate.PairScreen)}

  def handle_info({:tap, :edit}, socket),
    do: {:noreply, Mob.Socket.assign(socket, menu: false, editing: true)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp placeholder_view do
    %{
      id: @instance,
      firmware: nil,
      phase: :stopped,
      fb: nil,
      quarantined: false,
      restarts: 0,
      last_exit: nil,
      master: 1.0,
      buffer: :auto,
      clock_pct: nil,
      slow: false,
      fill: nil,
      cpu_mhz: nil,
      cpu_mode: nil,
      advice: nil
    }
  end
end
