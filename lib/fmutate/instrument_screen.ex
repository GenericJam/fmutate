defmodule FMutate.InstrumentScreen do
  @moduledoc """
  The instrument (HANDOFF §4, P1-a): the current layout full screen, and the creature menu (Library, Edit
  layout, I/O). v1 milestone: the menu sheet carries a minimal library (switch firmware) and the engine's
  test actions; the full library, the layout editor and I/O are their own screens later.
  """

  use Mob.Screen

  alias FMutate.{Firmware, Instance, Layouts}

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
       menu: false
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

    ~MOB"""
    <Box background="#14121A" padding={0} fill_width={true} fill_height={true}>
      {instrument}
      <Sheet id="menu" detents={[:medium, :large]} on_dismiss={dismiss} background="#1C1925" :if={@menu}>
        {menu(assigns.view)}
      </Sheet>
    </Box>
    """
  end

  defp menu(view) do
    rows = Enum.map(Firmware.all(), &firmware_row(&1, view))
    crash = {self(), {:debug, :crash}}
    hang = {self(), {:debug, :hang}}
    kill = {self(), {:debug, :kill9}}
    run_anyway = {self(), :run_anyway}
    status = status_line(view)
    quarantined = view.quarantined

    ~MOB"""
    <Scroll>
      <Column padding={20} gap={12}>
        <Text text="Firmware" text_size={:xl} text_color="#F3EFF8" font_weight="bold" />
        {rows}
        <Text text={status} text_size={:sm} text_color="#A9A3B8" />
        <Button text="Run anyway" on_tap={run_anyway} background="#2A2636" text_color="#F3EFF8" :if={quarantined} />
        <Text text="Engine" text_size={:lg} text_color="#F3EFF8" font_weight="bold" />
        <Row gap={8}>
          <Button text="Crash" on_tap={crash} background="#4A1F1A" text_color="#FFB4A3" />
          <Button text="Hang" on_tap={hang} background="#4A1F1A" text_color="#FFB4A3" />
          <Button text="Kill -9" on_tap={kill} background="#4A1F1A" text_color="#FFB4A3" />
        </Row>
      </Column>
    </Scroll>
    """
  end

  defp firmware_row(fw, view) do
    current = fw.id == view.firmware
    tap = {self(), {:switch, fw.id}}
    label = "#{fw.name} #{fw.version} · #{fw.author}" <> if(current, do: "  ✓", else: "")
    bg = if current, do: "#34304A", else: "#221F2B"
    fg = if current, do: "#C6F24E", else: "#F3EFF8"

    ~MOB"""
    <Button text={label} on_tap={tap} background={bg} text_color={fg} />
    """
  end

  defp status_line(view) do
    base = "#{view.firmware}: #{view.phase}"
    base = if view.restarts > 0, do: base <> " · restarted #{view.restarts}×", else: base
    if view.last_exit, do: base <> " · last exit #{inspect(view.last_exit)}", else: base
  end

  def handle_info({:instance, @instance, {:state, view}}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :view, view)}

  def handle_info({:instance, _id, _event}, socket), do: {:noreply, socket}

  def handle_info({:instrument, "menu", _}, socket), do: {:noreply, Mob.Socket.assign(socket, :menu, true)}

  def handle_info({:instrument, "use_classic", _}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :layout, Layouts.classic())}

  def handle_info({:instrument, _event, _payload}, socket), do: {:noreply, socket}

  def handle_info({:dismiss, :menu}, socket), do: {:noreply, Mob.Socket.assign(socket, :menu, false)}

  def handle_info({:tap, {:switch, fw}}, socket) do
    _ = Instance.switch_firmware(@instance, fw)
    {:noreply, Mob.Socket.assign(socket, :menu, false)}
  end

  def handle_info({:tap, {:debug, what}}, socket) do
    Instance.debug(@instance, what)
    {:noreply, socket}
  end

  def handle_info({:tap, :run_anyway}, socket) do
    _ = Instance.run_anyway(@instance)
    {:noreply, socket}
  end

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
