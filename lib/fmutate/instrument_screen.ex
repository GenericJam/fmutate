defmodule FMutate.InstrumentScreen do
  @moduledoc """
  The instrument (HANDOFF §4, P1-a): the current layout full screen. The creature button is the only app
  chrome: tap → menu (Library, Edit layout, Layouts, Sounds, I/O, Pair an app), long-press → page grid.
  """

  use Mob.Screen

  require FMutate.Subscription

  alias FMutate.{Editor, Instance, LayoutsSheet, MIDI, SoundsSheet, Subscription}

  @instance "a"
  @editor_events Editor.events()

  def mount(_params, _session, socket) do
    # a placeholder until the instance is up (it arrives through the subscription)
    view =
      case Subscription.subscribe(:instance, Instance.via(@instance), fn -> Instance.subscribe(@instance) end) do
        {:ok, view} -> view
        :pending -> placeholder_view()
      end

    # the current layout saved elsewhere (learned MIDI controls cleared in I/O): the editor takes it
    _ = Subscription.subscribe(:midi, MIDI.via(@instance), fn -> MIDI.subscribe(@instance) end)

    socket =
      socket
      |> Mob.Socket.assign(instance: @instance, view: view, menu: false, editing: false, layouts: nil, sounds: nil)
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
        add_menu: Editor.add_menu_json(assigns),
        undo: Editor.undo_prop(assigns)
      )

    dismiss = {self(), :menu}
    library = {self(), :library}
    edit = {self(), :edit}
    layouts = {self(), :layouts}
    io = {self(), :io}
    pair = {self(), :pair}
    sounds = {self(), :sounds}
    # (no pairing on iOS yet: FMutate.Pairing.available?/0)
    pair_button =
      if FMutate.Pairing.available?(),
        do: [
          ~MOB"""
          <Button text="Pair an app" on_tap={pair} background="#221F2B" text_color="#F3EFF8" />
          """
        ],
        else: []

    editor_sheets = Editor.sheets(assigns)
    layouts_sheet = LayoutsSheet.sheets(assigns)
    sounds_sheet = SoundsSheet.sheets(assigns)

    ~MOB"""
    <Box background="#14121A" padding={0} fill_width={true} fill_height={true}>
      {instrument}
      <Sheet id="menu" detents={[:content]} on_dismiss={dismiss} background="#1C1925" :if={@menu}>
        <Column padding={20} gap={10}>
          <Button text="Library" on_tap={library} background="#221F2B" text_color="#F3EFF8" />
          <Button text="Edit layout" on_tap={edit} background="#221F2B" text_color="#F3EFF8" />
          <Button text="Layouts" on_tap={layouts} background="#221F2B" text_color="#F3EFF8" />
          <Button text="Sounds" on_tap={sounds} background="#221F2B" text_color="#F3EFF8" />
          <Button text="I/O" on_tap={io} background="#221F2B" text_color="#F3EFF8" />
          {pair_button}
        </Column>
      </Sheet>
      {editor_sheets}
      {layouts_sheet}
      {sounds_sheet}
    </Box>
    """
    |> FMutate.Style.native_colors()
  end

  def handle_info({:instance, @instance, {:state, view}}, socket),
    do: {:noreply, socket |> Mob.Socket.assign(:view, view) |> Editor.firmware(view.firmware)}

  def handle_info({:instance, _id, _event}, socket), do: {:noreply, socket}

  def handle_info({:midi, @instance, {:layout, firmware, layout}}, socket),
    do: {:noreply, Editor.saved_elsewhere(socket, firmware, layout)}

  # MIDI learn (FMutate.MIDI.learn/2, armed from the binding sheet)
  def handle_info({:midi_learn, @instance, result}, socket), do: {:noreply, Editor.learned(socket, result)}

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

  # the Layouts sheet (FMutate.LayoutsSheet): the layout library, Original layout, Undo
  def handle_info({:tap, :layouts}, socket),
    do: {:noreply, socket |> Mob.Socket.assign(:menu, false) |> LayoutsSheet.open()}

  def handle_info({kind, {:layouts, _} = tag}, socket) when kind in [:tap, :dismiss],
    do: {:noreply, LayoutsSheet.event(kind, tag, socket)}

  def handle_info({kind, {:layouts, _} = tag, value}, socket) when kind in [:change, :submit],
    do: {:noreply, LayoutsSheet.event(kind, tag, value, socket)}

  def handle_info({:files, _, _} = msg, %{assigns: %{picking: :layouts}} = socket),
    do: {:noreply, LayoutsSheet.picked(socket, msg)}

  def handle_info({:files, :cancelled} = msg, %{assigns: %{picking: :layouts}} = socket),
    do: {:noreply, LayoutsSheet.picked(socket, msg)}

  # an export's share sheet didn't open (Mob.Share.file/3)
  def handle_info({:mob_share, :error, reason}, socket),
    do: {:noreply, Mob.Alert.toast(socket, "Couldn't open the share sheet (#{reason})", duration: :long)}

  def handle_info({:tap, :sounds}, socket),
    do: {:noreply, socket |> Mob.Socket.assign(:menu, false) |> SoundsSheet.open()}

  # the Sounds sheet's own events, while it is open or its work runs (FMutate.SoundsSheet)
  def handle_info(msg, %{assigns: %{sounds: %{}}} = socket), do: {:noreply, SoundsSheet.event(msg, socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # a picked layout file, read and checked in a task (FMutate.LayoutsSheet.picked/2)
  def handle_async({:layouts, :import}, result, socket), do: {:noreply, LayoutsSheet.imported(socket, result)}

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
