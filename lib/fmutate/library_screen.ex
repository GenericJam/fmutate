defmodule FMutate.LibraryScreen do
  @moduledoc """
  The firmware library (HANDOFF §9, P1-b). This first version lists the firmwares the app can run and
  switches between them; browsing the Hub, downloading, importing `.fwsc`, statuses and undo come with
  `FMutate.Library`.
  """

  use Mob.Screen

  alias FMutate.{Firmware, Instance}

  @instance "a"

  def mount(_params, _session, socket) do
    {:ok, Mob.Socket.assign(socket, view: Instance.subscribe(@instance), firmwares: Firmware.all())}
  end

  def render(assigns) do
    rows = Enum.map(assigns.firmwares, &row(&1, assigns.view))
    run_anyway = {self(), :run_anyway}
    quarantined = assigns.view.quarantined
    status = "#{assigns.view.firmware}: #{assigns.view.phase}"

    ~MOB"""
    <Scroll background="#14121A">
      <Column padding={20} gap={12} background="#14121A">
        <Text text="Library" text_size={:xl} text_color="#F3EFF8" font_weight="bold" />
        {rows}
        <Text text={status} text_size={:sm} text_color="#A9A3B8" />
        <Button text="Run anyway" on_tap={run_anyway} background="#2A2636" text_color="#F3EFF8" :if={quarantined} />
      </Column>
    </Scroll>
    """
  end

  defp row(fw, view) do
    current = fw.id == view.firmware
    tap = {self(), {:switch, fw.id}}
    label = "#{fw.name} #{fw.version} · #{fw.author}" <> if(current, do: "  ✓", else: "")
    bg = if current, do: "#34304A", else: "#221F2B"
    fg = if current, do: "#C6F24E", else: "#F3EFF8"

    ~MOB"""
    <Button text={label} on_tap={tap} background={bg} text_color={fg} />
    """
  end

  def handle_info({:tap, {:switch, fw}}, socket) do
    _ = Instance.switch_firmware(@instance, fw)
    {:noreply, Mob.Socket.pop_screen(socket)}
  end

  def handle_info({:tap, :run_anyway}, socket) do
    _ = Instance.run_anyway(@instance)
    {:noreply, socket}
  end

  def handle_info({:instance, @instance, {:state, view}}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :view, view)}

  def handle_info(_message, socket), do: {:noreply, socket}
end
