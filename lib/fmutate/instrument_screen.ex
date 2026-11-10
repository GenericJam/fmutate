defmodule FMutate.InstrumentScreen do
  @moduledoc """
  The instrument (HANDOFF §4, P1-a): the current layout full screen. The creature button is the only app
  chrome: tap → menu (Library, Edit layout, I/O), long-press → page grid.
  """

  use Mob.Screen

  alias FMutate.{Instance, Layouts}

  @instance "a"

  def mount(_params, _session, socket) do
    view =
      try do
        Instance.subscribe(@instance)
      catch
        :exit, _ -> placeholder_view()
      end

    {:ok,
     Mob.Socket.assign(socket,
       instance: @instance,
       view: view,
       layout: Layouts.classic(),
       menu: false,
       editing: false
     )}
  end

  def render(assigns) do
    instrument =
      Mob.UI.native_view(FMutate.InstrumentView,
        id: :instrument,
        instance: assigns.instance,
        layout: assigns.layout.json,
        view: assigns.view,
        owner: self()
      )

    dismiss = {self(), :menu}
    library = {self(), :library}
    edit = {self(), :edit}
    io = {self(), :io}

    ~MOB"""
    <Box background="#14121A" padding={0} fill_width={true} fill_height={true}>
      {instrument}
      <Sheet id="menu" detents={[:content]} on_dismiss={dismiss} background="#1C1925" :if={@menu}>
        <Column padding={20} gap={10}>
          <Button text="Library" on_tap={library} background="#221F2B" text_color="#F3EFF8" />
          <Button text="Edit layout" on_tap={edit} background="#221F2B" text_color="#F3EFF8" />
          <Button text="I/O" on_tap={io} background="#221F2B" text_color="#F3EFF8" />
        </Column>
      </Sheet>
    </Box>
    """
  end

  def handle_info({:instance, @instance, {:state, view}}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :view, view)}

  def handle_info({:instance, _id, _event}, socket), do: {:noreply, socket}

  def handle_info({:instrument, "menu", _}, socket), do: {:noreply, Mob.Socket.assign(socket, :menu, true)}

  def handle_info({:instrument, "use_classic", _}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :layout, Layouts.classic())}

  def handle_info({:instrument, _event, _payload}, socket), do: {:noreply, socket}

  def handle_info({:dismiss, :menu}, socket), do: {:noreply, Mob.Socket.assign(socket, :menu, false)}

  def handle_info({:tap, :library}, socket),
    do: {:noreply, socket |> Mob.Socket.assign(:menu, false) |> Mob.Socket.push_screen(FMutate.LibraryScreen)}

  def handle_info({:tap, :io}, socket),
    do: {:noreply, socket |> Mob.Socket.assign(:menu, false) |> Mob.Socket.push_screen(FMutate.IOScreen)}

  # the layout editor arrives with the edit mode of the instrument view
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
      master: 1.0
    }
  end
end
