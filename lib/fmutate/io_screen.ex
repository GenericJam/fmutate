defmodule FMutate.IOScreen do
  @moduledoc """
  I/O and the instance (HANDOFF §10). This first version shows the audio output (rate, latency, level,
  underruns) and the engine's test actions; MIDI ports and connected sibling apps come next.
  """

  use Mob.Screen

  alias FMutate.{Audio, Instance}

  @instance "a"
  @refresh_ms 250

  def mount(_params, _session, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:ok, Mob.Socket.assign(socket, view: Instance.subscribe(@instance), audio: Audio.stats())}
  end

  def render(assigns) do
    a = assigns.audio
    v = assigns.view
    crash = {self(), {:debug, :crash}}
    hang = {self(), {:debug, :hang}}
    kill = {self(), {:debug, :kill9}}

    latency =
      case a.latency_ms do
        ms when is_number(ms) -> "#{round(ms)} ms"
        _ -> "—"
      end

    audio_line = "#{a.rate} Hz · #{a.sharing} · latency #{latency} · xruns #{a.xruns}"
    level = "level #{level_db(a.peak)} · underruns #{inspect(a.underruns)}"
    engine = "#{v.firmware}: #{v.phase} · restarts #{v.restarts}" <> if(v.last_exit, do: " · last exit #{inspect(v.last_exit)}", else: "")

    ~MOB"""
    <Scroll background="#14121A">
      <Column padding={20} gap={12} background="#14121A">
        <Text text="I/O" text_size={:xl} text_color="#F3EFF8" font_weight="bold" />
        <Text text="Audio out" text_size={:lg} text_color="#F3EFF8" font_weight="bold" />
        <Text text={audio_line} text_size={:sm} text_color="#C9C3D6" />
        <Text text={level} text_size={:sm} text_color="#C9C3D6" />
        <Text text="Instance a" text_size={:lg} text_color="#F3EFF8" font_weight="bold" />
        <Text text={engine} text_size={:sm} text_color="#C9C3D6" />
        <Row gap={8}>
          <Button text="Crash" on_tap={crash} background="#4A1F1A" text_color="#FFB4A3" />
          <Button text="Hang" on_tap={hang} background="#4A1F1A" text_color="#FFB4A3" />
          <Button text="Kill -9" on_tap={kill} background="#4A1F1A" text_color="#FFB4A3" />
        </Row>
      </Column>
    </Scroll>
    """
  end

  defp level_db(0), do: "silent"
  defp level_db(peak), do: "#{Float.round(20 * :math.log10(peak / 32_767), 1)} dBFS"

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, Mob.Socket.assign(socket, :audio, Audio.stats())}
  end

  def handle_info({:tap, {:debug, what}}, socket) do
    Instance.debug(@instance, what)
    {:noreply, socket}
  end

  def handle_info({:instance, @instance, {:state, view}}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :view, view)}

  def handle_info(_message, socket), do: {:noreply, socket}
end
