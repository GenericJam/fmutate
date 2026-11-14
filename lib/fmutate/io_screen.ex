defmodule FMutate.IOScreen do
  @moduledoc """
  I/O and the instance (HANDOFF §10, board `IO.dc.html`): the instance card, audio out (where the sound
  goes, level, the whole latency), MIDI (the instance's virtual port, devices to play it from, clock),
  apps on this phone (Erlang distribution, Allow / Disconnect), and a developer section with the engine's
  test actions.

  Live data: `FMutate.Audio.stats/0` (polled), `FMutate.IO`, `FMutate.MIDI`, `FMutate.Dist` and the
  instance (subscribed).
  """

  use Mob.Screen

  require FMutate.Subscription

  import Mob.Canvas, only: [rect: 5, circle: 4]

  alias FMutate.{Audio, Dist, Firmware, IO, Instance, MIDI, Style, Subscription}
  alias FMutate.Instance.Health

  @instance "a"
  @refresh_ms 250
  @segments 24

  def mount(_params, _session, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)

    {:ok, view} =
      Subscription.subscribe(:instance, Instance.via(@instance), fn ->
        Instance.subscribe(@instance)
      end)

    {:ok,
     Mob.Socket.assign(socket,
       view: view,
       audio: Audio.stats(),
       # nil until the server is up (it arrives through the subscription)
       io: subscribed(:io, IO, &IO.subscribe/0),
       dist: subscribed(:dist, Dist, &Dist.subscribe/0),
       midi: MIDI.settings(@instance),
       latency: nil,
       sheet: nil
     )}
  end

  defp subscribed(key, server, fun) do
    case Subscription.subscribe(key, server, fun) do
      {:ok, result} -> result
      :pending -> nil
    end
  end

  ## Render

  def render(assigns) do
    back = {self(), :back}

    ~MOB"""
    <Scroll background={0xFF14121A}>
      <Column
        padding_left={16}
        padding_right={16}
        padding_top={12}
        padding_bottom={24}
        gap={12}
        background={0xFF14121A}
      >
        <Row gap={8} align={:center}>
          <Button
            text="‹"
            on_tap={back}
            background={0xFF14121A}
            text_color={0xFFF3EFF8}
            text_size={26}
            fill_width={false}
            padding={6}
          />
          <Text text="I/O" text_size={24} text_color={0xFFF3EFF8} font_weight="bold" />
        </Row>
        {instance_card(assigns)}
        {audio_section(assigns)}
        {midi_section(assigns)}
        {apps_section(assigns)}
        {developer_section(assigns)}
        {sheet(assigns)}
      </Column>
    </Scroll>
    """
  end

  # node colours as ARGB integers (FMutate.Style.argb/1); canvas ops take hex
  defp c(name), do: Style.argb(name)
  defp hex(name), do: Style.color(name)

  defp section_label(text) do
    ~MOB"""
    <Text text={text} text_size={11} text_color={0xFFA9A3B8} font="monospace" font_weight="bold" />
    """
  end

  defp card(children) do
    children = Enum.reject(children, &is_nil/1)

    ~MOB"""
    <Column
      background={0xFF1C1925}
      corner_radius={16}
      padding_left={14}
      padding_right={14}
      padding_top={12}
      padding_bottom={12}
      gap={10}
    >
      {children}
    </Column>
    """
  end

  ## Instance

  defp instance_card(assigns) do
    v = assigns.view
    fw = (v.firmware && Firmware.get(v.firmware)) || %{name: v.firmware || "no firmware"}
    clock = clock_label(v)
    node = node_label(assigns.dist)
    sub = "#{node} · #{phase_label(v.phase)}#{clock}"
    title = "Instance #{String.upcase(@instance)} · #{fw.name}"

    ~MOB"""
    <Row
      background={0xFF1C1925}
      corner_radius={16}
      padding_left={14}
      padding_right={14}
      padding_top={12}
      padding_bottom={12}
      gap={12}
      align={:center}
    >
      <Canvas width={44} height={44} draw={creature()} />
      <Column gap={2} weight={1}>
        <Text text={title} text_size={15} text_color={0xFFF3EFF8} font_weight="bold" />
        <Text text={sub} text_size={11} text_color={0xFFA9A3B8} font="monospace" />
      </Column>
      <Button
        text="+ Instance"
        disabled={true}
        background={0xFF1C1925}
        text_color={0xFF6B6580}
        text_size={12}
        fill_width={false}
        corner_radius={10}
        border_color={0xFF34304A}
        border_width={1}
      />
    </Row>
    """
  end

  defp node_label(%{node: node}), do: node |> Atom.to_string() |> String.split("@") |> hd()
  defp node_label(_), do: "fmutate_#{@instance}"

  defp phase_label(:safe_mode), do: "safe mode"
  defp phase_label(:not_installed), do: "can't run here"
  defp phase_label(:hung), do: "stuck: restart the app"
  defp phase_label(phase), do: to_string(phase)

  # the instance's speed (FMutate.Instance.Health): one source for this card, the instrument and sibling apps;
  # and the emulated CPU's clock for a firmware in the emulator engine
  defp clock_label(v), do: speed_label(v) <> if(v[:cpu_mhz], do: " · CPU #{v.cpu_mhz} MHz", else: "")

  defp speed_label(%{slow: true, clock_pct: pct}), do: " · too slow, speed #{pct}%"
  defp speed_label(%{clock_pct: pct}) when is_integer(pct), do: " · speed #{pct}%"
  defp speed_label(_view), do: ""

  # the Opling "twins" form (creature.md): two columns of two ops, one eye on each head op, lime tint
  defp creature do
    s = 0.9
    w = 22 * s
    h = 14 * s
    gap = 3 * s
    vgap = 2.5 * s
    x0 = (44 - (2 * w + gap)) / 2
    y0 = 44 - (2 * h + vgap) - 3.2 * s - 2

    ops =
      for col <- 0..1, row <- 0..1 do
        x = x0 + col * (w + gap)
        y = y0 + row * (h + vgap)

        rect(x, y, w, h,
          color: if(row == 1, do: "#93CF32", else: "#C6F24E"),
          fill: true,
          radius: 4 * s
        )
      end

    feet =
      for col <- 0..1, i <- 0..1 do
        fx = x0 + col * (w + gap) + 3 * s + i * (w - 6 * s - 6 * s)
        rect(fx, y0 + 2 * h + vgap, 6 * s, 3.2 * s, color: "#5E8F1A", fill: true, radius: 1.6 * s)
      end

    eyes =
      for col <- 0..1 do
        cx = x0 + col * (w + gap) + w / 2
        cy = y0 - 2 * s + 4 * s

        [
          circle(cx, cy, 4 * s, color: "#FFFFFF", fill: true),
          circle(cx, cy + 0.6, 1.9 * s, color: "#17141F", fill: true)
        ]
      end

    ops ++ feet ++ List.flatten(eyes)
  end

  ## Audio out

  defp audio_section(assigns) do
    a = assigns.audio
    route = route(assigns)
    db = db(a.peak)
    {total, detail} = latency(a)

    seg =
      for {label, type} <- [{"Speaker", :speaker}, {"Headphones", :headphones}, {"USB", :usb}],
          do: segment(label, type, route, assigns.io)

    other = route_note(route)
    buffer = if a.buffer > 0, do: " · buffer #{a.buffer}", else: ""
    latency_text = "#{total}#{buffer}"
    level = if db, do: "#{format_db(db)} dB", else: "silent"

    card([
      section_label("AUDIO OUT"),
      ~MOB"""
      <Row background={0xFF14121A} corner_radius={12} padding={3} gap={3}>
        {seg}
      </Row>
      """,
      other,
      ~MOB"""
      <Row gap={10} align={:center}>
        <Canvas width={260} height={10} draw={meter(db)} weight={1} />
        <Text text={level} text_size={11} text_color={0xFFC9C3D6} font="monospace" font_weight="bold" />
      </Row>
      """,
      ~MOB"""
      <Row align={:center}>
        <Text text="Latency" text_size={13} text_color={0xFFF3EFF8} weight={1} />
        <Text text={latency_text} text_size={13} text_color={0xFFC9C3D6} font="monospace" />
      </Row>
      """,
      ~MOB"""
      <Text text={detail} text_size={11} text_color={0xFFA9A3B8} font="monospace" />
      """,
      buffer_row(assigns),
      cpu_row(assigns)
    ])
  end

  # the engine's ring fill (FMutate.Instance.set_buffer/2): Auto, or a fixed larger one; each choice shows
  # the latency it gives. The instrument's "Audio dropouts" hint points here.
  defp buffer_row(assigns) do
    a = assigns.audio
    v = assigns.view
    current = Map.get(v, :buffer, :auto)
    out = if is_number(a.latency_ms), do: a.latency_ms, else: 0
    ms = fn frames -> "#{round(out + frames * 1000 / 44_100)} ms" end

    {row1, row2} =
      ([buffer_chip("Auto", current == :auto, :auto)] ++
         for(frames <- Health.fixed_buffers(), do: buffer_chip(ms.(frames), current == frames, frames)))
      |> Enum.split(2)

    note =
      case v do
        %{slow: true} ->
          "Too slow: no buffer helps an engine slower than real time"

        %{fill: fill} when is_integer(fill) and current == :auto ->
          "Auto: #{ms.(fill)} now (engine #{fill} frames); rises while the engine underruns"

        %{fill: fill} when is_integer(fill) ->
          "Fixed: engine #{fill} frames. Larger plays later but rides out a jittery phone"

        _ ->
          "Larger plays later but rides out a jittery phone"
      end

    ~MOB"""
    <Column gap={6}>
      <Text text="Buffer" text_size={13} text_color={0xFFF3EFF8} />
      <Row align={:center} gap={6}>
        {row1}
      </Row>
      <Row align={:center} gap={6}>
        {row2}
      </Row>
      <Text text={note} text_size={11} text_color={0xFFA9A3B8} font="monospace" />
    </Column>
    """
  end

  # the emulated CPU's clock (FMutate.Instance.set_cpu/2), for a firmware in the emulator engine: Auto lowers it
  # while the engine is too slow; a fixed one is used as is
  defp cpu_row(%{view: %{cpu_mode: mode, cpu_mhz: mhz}}) when mode != nil do
    chips = [cpu_chip("Auto", mode == :auto, :auto) | for(n <- Health.clocks(), do: cpu_chip("#{n} MHz", mode == n, n))]
    {row1, row2} = Enum.split(chips, 3)

    note =
      if mode == :auto,
        do: "Auto: #{mhz} MHz now (an FM-1's is 240); lowered while the phone can't keep up",
        else: "Fixed: #{mhz} MHz. Lower costs the phone less; too low and the firmware's own sound breaks up"

    ~MOB"""
    <Column gap={6}>
      <Text text="Emulated CPU" text_size={13} text_color={0xFFF3EFF8} />
      <Row align={:center} gap={6}>
        {row1}
      </Row>
      <Row align={:center} gap={6}>
        {row2}
      </Row>
      <Text text={note} text_size={11} text_color={0xFFA9A3B8} font="monospace" />
    </Column>
    """
  end

  defp cpu_row(_assigns), do: nil

  defp cpu_chip(label, selected, mode) do
    tap = {self(), {:cpu, mode}}
    {bg, fg} = if selected, do: {c(:selected), c(:fm)}, else: {c(:raised), c(:text)}

    ~MOB"""
    <Button
      text={label}
      on_tap={tap}
      background={bg}
      text_color={fg}
      text_size={12}
      corner_radius={9}
      padding={4}
      weight={1}
    />
    """
  end

  # two to a row on a phone: equal widths, as the route segments
  defp buffer_chip(label, selected, buffer) do
    tap = {self(), {:buffer, buffer}}
    {bg, fg} = if selected, do: {c(:selected), c(:fm)}, else: {c(:raised), c(:text)}

    ~MOB"""
    <Button
      text={label}
      on_tap={tap}
      background={bg}
      text_color={fg}
      text_size={12}
      corner_radius={9}
      padding={4}
      weight={1}
    />
    """
  end

  defp route(%{io: %{audio: devices}, audio: %{device_id: id}}), do: IO.route_of(devices, id)
  defp route(_), do: %{type: :unknown, name: nil}

  defp segment(label, type, route, io) do
    present = io == nil or Enum.any?(io.audio, &(&1.type == type))

    {bg, fg} =
      cond do
        route.type == type -> {c(:selected), c(:text)}
        present -> {0xFF14121A, c(:muted)}
        true -> {0xFF14121A, c(:faint)}
      end

    ~MOB"""
    <Box background={bg} corner_radius={9} padding={10} weight={1}>
      <Text text={label} text_size={12} text_color={fg} font_weight="bold" text_align="center" />
    </Box>
    """
  end

  defp route_note(%{type: type, name: name}) when type in [:bluetooth, :other] do
    text = "Playing to #{if type == :bluetooth, do: "Bluetooth", else: "another output"}: #{name}"

    ~MOB"""
    <Text text={text} text_size={12} text_color={0xFFC9C3D6} />
    """
  end

  defp route_note(_), do: nil

  defp db(0), do: nil
  defp db(peak) when is_integer(peak), do: 20 * :math.log10(peak / 32_767)
  defp db(_), do: nil

  defp format_db(db),
    do: db |> Float.round(0) |> trunc() |> then(&if(&1 < 0, do: "−#{-&1}", else: "#{&1}"))

  # 24 segments over −48..0 dBFS, 2 dB each: lime, amber above −12, coral above −4
  defp meter(db) do
    lit = if db, do: max(0, min(@segments, ceil((db + 48) / 2))), else: 0
    w = (260 - (@segments - 1) * 2) / @segments

    for i <- 0..(@segments - 1) do
      color =
        cond do
          i >= lit -> hex(:line_soft)
          i >= 22 -> hex(:danger)
          i >= 18 -> hex(:warn)
          true -> hex(:fm)
        end

      rect(i * (w + 2), 0, w, 10, color: color, fill: true, radius: 2)
    end
  end

  # the whole trip: the device's output latency plus how far ahead the engine keeps its ring
  defp latency(a) do
    engine_ms = Enum.max(a.fills, fn -> 0 end) * 1000 / 44_100

    case a.latency_ms do
      ms when is_number(ms) ->
        detail =
          "output #{round(ms)} ms + engine #{round(engine_ms)} ms · #{div(a.rate, 1000)} kHz #{a.sharing}"

        {"#{round(ms + engine_ms)} ms", detail}

      _ ->
        {"—", "no output stream"}
    end
  end

  ## MIDI

  defp midi_section(assigns) do
    io =
      assigns.io ||
        %{
          midi: [],
          virtual: [],
          bluetooth: %{scanning: false, permission: :unsupported, found: []}
        }

    m = assigns.midi
    port = MIDI.port_name(@instance)

    virtual =
      Enum.find(io.virtual, %{senders: 0, listeners: 0}, &(&1.instance == MIDI.index(@instance)))

    rows =
      [
        midi_row(
          "IN",
          port,
          "virtual port · " <> source_line(m, port),
          virtual.senders > 0,
          {:source, port, nil}
        )
      ] ++
        for dev <- io.midi do
          name = "#{dev.name} · #{type_label(dev.type)}"
          sub = if dev.open, do: source_line(m, dev.name), else: "not playing · tap to use"
          midi_row("IN", name, sub, dev.open, {:source, dev.name, dev.id})
        end ++
        bluetooth_rows(io.bluetooth, io.midi) ++
        [
          midi_row(
            "OUT",
            port <> " out",
            out_line(m, virtual.listeners),
            virtual.listeners > 0,
            :clock
          )
        ]

    scan = {self(), :scan}
    clock = {self(), {:sheet, :clock}}
    scan_label = scan_label(io.bluetooth)
    scan_disabled = io.bluetooth.permission == :unsupported or io.bluetooth.scanning
    clock_label = "Clock: #{m.clock} ▾"

    card(
      [section_label("MIDI")] ++
        rows ++
        [
          ~MOB"""
          <Row gap={8}>
            <Button
              text={scan_label}
              on_tap={scan}
              disabled={scan_disabled}
              background={0xFF2A2636}
              text_color={0xFFF3EFF8}
              text_size={13}
              corner_radius={12}
              weight={1}
            />
            <Button
              text={clock_label}
              on_tap={clock}
              background={0xFF2A2636}
              text_color={0xFFF3EFF8}
              text_size={13}
              corner_radius={12}
              weight={1}
            />
          </Row>
          """
        ]
    )
  end

  defp midi_row(dir, name, sub, live, tag) do
    tap = {self(), {:sheet, tag}}
    chip_bg = if dir == "IN", do: c(:key_white), else: c(:info)
    dot = if live, do: hex(:fm), else: "#4A4560"

    ~MOB"""
    <Row gap={10} align={:center} padding_top={4} padding_bottom={4} on_tap={tap}>
      <Text
        text={dir}
        text_size={10}
        text_color={0xFF14121A}
        font="monospace"
        font_weight="bold"
        background={chip_bg}
        corner_radius={6}
        padding={4}
      />
      <Column gap={2} weight={1}>
        <Text text={name} text_size={14} text_color={0xFFF3EFF8} font_weight="medium" max_lines={1} />
        <Text text={sub} text_size={11} text_color={0xFFA9A3B8} font="monospace" />
      </Column>
      <Canvas width={8} height={8} draw={[circle(4, 4, 4, color: dot, fill: true)]} />
    </Row>
    """
  end

  defp bluetooth_rows(%{found: found} = bt, midi) do
    connected = MapSet.new(for d <- midi, d.type == :bluetooth, do: d.name)
    fresh = Enum.reject(found, &MapSet.member?(connected, &1.name))

    case fresh do
      [] ->
        sub =
          cond do
            bt.scanning -> "scanning…"
            bt.permission == :unsupported -> "no Bluetooth on this phone"
            true -> "none paired · Scan Bluetooth to add one"
          end

        if Enum.any?(midi, &(&1.type == :bluetooth)),
          do: [],
          else: [midi_row("IN", "Bluetooth MIDI", sub, false, :none)]

      devices ->
        for d <- devices,
            do:
              midi_row(
                "IN",
                d.name,
                "Bluetooth · found · tap to connect",
                false,
                {:bluetooth, d.address}
              )
    end
  end

  defp scan_label(%{scanning: true}), do: "Scanning…"
  defp scan_label(%{permission: :unsupported}), do: "No Bluetooth"
  defp scan_label(_), do: "Scan Bluetooth"

  defp type_label(:usb), do: "USB"
  defp type_label(:bluetooth), do: "Bluetooth"
  defp type_label(_), do: "app"

  defp prefs(m, name), do: Map.get(m.sources, name, %{})

  defp source_line(m, name) do
    p = prefs(m, name)

    ch =
      case p[:channel] || :all,
        do: (
          :all -> "all channels"
          n -> "ch #{n}"
        )

    notes = if (p[:notes] || :keys) == :keys, do: "keys", else: "firmware MIDI"
    bend = if m.bend, do: " · pitch bend on", else: " · no pitch bend"
    "#{ch} → #{notes}#{bend}"
  end

  defp out_line(m, listeners) do
    clock = if m.clock == :send, do: "clock #{m.bpm} BPM", else: "no clock sent"

    apps =
      case listeners,
        do: (
          0 -> "no app listening"
          1 -> "1 app listening"
          n -> "#{n} apps listening"
        )

    "#{clock} · #{apps}"
  end

  ## Apps (distribution)

  defp apps_section(assigns) do
    d = assigns.dist

    rows =
      case d do
        %{apps: [_ | _] = apps} ->
          Enum.map(apps, &app_row(&1, d.driven))

        _ ->
          [
            ~MOB(<Text text="No app has asked to connect." text_size={13} text_color={0xFFA9A3B8} />)
          ]
      end

    status =
      case d do
        %{status: :running, node: node, port: port} -> "#{node} · 127.0.0.1:#{port}"
        %{status: :starting} -> "starting…"
        %{status: {:error, reason}} -> "not running: #{inspect(reason)}"
        nil -> "distribution not available"
      end

    card(
      [section_label("APPS ON THIS PHONE · ERLANG DISTRIBUTION")] ++
        rows ++
        [
          ~MOB"""
          <Text
            text="Only apps signed by FMutate's maker can ask. An app you allow gets full control of FMutate (Erlang distribution: it could run code here). Network pairing is off."
            text_size={11}
            text_color={0xFFA9A3B8}
          />
          """,
          ~MOB"""
          <Text text={status} text_size={11} text_color={0xFF6B6580} font="monospace" />
          """
        ]
    )
  end

  defp app_row(app, driven) do
    {dot, sub, act} =
      case app.state do
        :connected ->
          {hex(:fm),
           if(@instance in driven,
             do: "connected · controlling this instance",
             else: "connected"
           ), "Disconnect"}

        :pending ->
          {hex(:warn), "wants to connect", "Allow"}

        :allowed ->
          {"#4A4560", "allowed · not connected", "Disconnect"}

        :disconnected ->
          {"#4A4560", "disconnected", "Allow"}
      end

    tap = {self(), {String.downcase(act) |> String.to_existing_atom(), app.node}}
    name = app_name(app.node)

    ~MOB"""
    <Row gap={10} align={:center}>
      <Canvas width={8} height={8} draw={[circle(4, 4, 4, color: dot, fill: true)]} />
      <Column gap={2} weight={1}>
        <Text text={name} text_size={14} text_color={0xFFF3EFF8} font_weight="medium" />
        <Text text={sub} text_size={11} text_color={0xFFA9A3B8} font="monospace" />
      </Column>
      <Button
        text={act}
        on_tap={tap}
        background={0xFF1C1925}
        text_color={0xFFE4DFEE}
        text_size={12}
        fill_width={false}
        corner_radius={9}
        border_color={0xFF4A4560}
        border_width={1}
      />
    </Row>
    """
  end

  # fmutate_rig@127.0.0.1 → "Fmutate Rig"
  defp app_name(node) do
    node
    |> Atom.to_string()
    |> String.split("@")
    |> hd()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  ## Developer

  defp developer_section(assigns) do
    crash = {self(), {:debug, :crash}}
    hang = {self(), {:debug, :hang}}
    kill = {self(), {:debug, :kill9}}
    v = assigns.view
    a = assigns.audio

    engine =
      "#{v.firmware}: #{v.phase} · restarts #{v.restarts}" <>
        if(v.last_exit, do: " · last exit #{inspect(v.last_exit)}", else: "")

    audio = "xruns #{a.xruns} · underruns #{inspect(a.underruns)} · burst #{a.burst}"

    tools =
      case assigns.dist,
        do: (
          %{dev_tools: [_ | _] = t} -> "dev tools: " <> Enum.join(t, ", ")
          _ -> "no dev tools connected"
        )

    midi = midi_latency(assigns.latency)

    card([
      section_label("DEVELOPER"),
      ~MOB"""
      <Text
        text="Engine test actions: crash, hang or kill the running firmware engine to exercise recovery."
        text_size={11}
        text_color={0xFFA9A3B8}
      />
      """,
      ~MOB"""
      <Row gap={8}>
        <Button
          text="Crash"
          on_tap={crash}
          background={0xFF4A1F1A}
          text_color={0xFFFFB4A3}
          text_size={13}
          corner_radius={10}
          weight={1}
        />
        <Button
          text="Hang"
          on_tap={hang}
          background={0xFF4A1F1A}
          text_color={0xFFFFB4A3}
          text_size={13}
          corner_radius={10}
          weight={1}
        />
        <Button
          text="Kill -9"
          on_tap={kill}
          background={0xFF4A1F1A}
          text_color={0xFFFFB4A3}
          text_size={13}
          corner_radius={10}
          weight={1}
        />
      </Row>
      """,
      ~MOB"""
      <Text text={engine} text_size={11} text_color={0xFFC9C3D6} font="monospace" />
      """,
      ~MOB"""
      <Text text={audio} text_size={11} text_color={0xFFC9C3D6} font="monospace" />
      """,
      ~MOB"""
      <Text text={midi} text_size={11} text_color={0xFFC9C3D6} font="monospace" />
      """,
      ~MOB"""
      <Text text={tools} text_size={11} text_color={0xFFC9C3D6} font="monospace" />
      """
    ] ++ input_diagnostics(assigns))
  end

  # what the firmware is holding down right now, and what the instrument surface had to let go of by itself
  defp input_diagnostics(assigns) do
    release = {self(), :release_all}

    held =
      case assigns[:held] do
        %{keys: [], buttons: []} -> "Held by the firmware: nothing"
        %{keys: k, buttons: b} -> "Held by the firmware: keys #{inspect(k)} · buttons #{Enum.join(b, ", ")}"
        _ -> "Held by the firmware: —"
      end

    notes =
      for {ms, :surface, what, _} <- assigns[:surface_notes] || [] do
        line = "#{div(System.monotonic_time(:millisecond) - ms, 1000)} s ago: #{inspect(what)}"

        ~MOB"""
        <Text text={line} text_size={11} text_color={0xFFFFB547} font="monospace" />
        """
      end

    [
      ~MOB"""
      <Text text={held} text_size={11} text_color={0xFFC9C3D6} font="monospace" />
      """
    ] ++
      notes ++
      [
        ~MOB"""
        <Button text="Release all (stuck notes or buttons)" on_tap={release} background={0xFF2A2636} text_color={0xFFF3EFF8} text_size={13} corner_radius={10} />
        """
      ]
  end

  defp midi_latency(%{n: n, to_beam: %{median: med, max: max}}) when n > 0,
    do: "MIDI Kotlin → BEAM: median #{med} ms, max #{max} ms (#{n} msgs)"

  defp midi_latency(_), do: "MIDI: nothing received yet"

  ## Sheets

  defp sheet(%{sheet: nil}), do: nil

  defp sheet(%{sheet: {:source, name, device_id}} = assigns) do
    dismiss = {self(), :sheet}
    p = prefs(assigns.midi, name)
    current = p[:channel] || :all
    notes = p[:notes] || :keys
    open = device_id && Enum.find(assigns.io.midi, &(&1.id == device_id))

    channels =
      for ch <- [:all | Enum.to_list(1..16)] do
        label = if ch == :all, do: "All", else: Integer.to_string(ch)
        chip(label, ch == current, {:channel, name, ch})
      end

    use_toggle =
      case open do
        %{open: is_open} ->
          tag = {self(), {:open, device_id, not is_open}}

          label =
            if is_open,
              do: "Stop playing from this device",
              else: "Play this instance from this device"

          ~MOB"""
          <Button
            text={label}
            on_tap={tag}
            background={0xFF2A2636}
            text_color={0xFFF3EFF8}
            text_size={13}
            corner_radius={12}
          />
          """

        _ ->
          nil
      end

    keys_tap = {self(), {:notes, name, :keys}}
    fw_tap = {self(), {:notes, name, :firmware}}

    {keys_bg, fw_bg} =
      if notes == :keys, do: {c(:selected), c(:raised)}, else: {c(:raised), c(:selected)}

    ~MOB"""
    <Sheet id="source" detents={[:content]} on_dismiss={dismiss} background={0xFF1C1925}>
      <Column padding={20} gap={12}>
        <Text text={name} text_size={17} text_color={0xFFF3EFF8} font_weight="bold" />
        {use_toggle}
        <Text
          text="CHANNEL"
          text_size={11}
          text_color={0xFFA9A3B8}
          font="monospace"
          font_weight="bold"
        />
        <Wrap spacing={6} run_spacing={6}>
          {channels}
        </Wrap>
        <Text
          text="NOTES"
          text_size={11}
          text_color={0xFFA9A3B8}
          font="monospace"
          font_weight="bold"
        />
        <Row gap={8}>
          <Button
            text="→ keys"
            on_tap={keys_tap}
            background={keys_bg}
            text_color={0xFFF3EFF8}
            text_size={13}
            corner_radius={10}
            weight={1}
          />
          <Button
            text="→ firmware MIDI"
            on_tap={fw_tap}
            background={fw_bg}
            text_color={0xFFF3EFF8}
            text_size={13}
            corner_radius={10}
            weight={1}
          />
        </Row>
        <Text
          text="Keys: notes F3–G5 press the FM-1's keys (no velocity); others go to the firmware's MIDI in. Firmware MIDI: every note goes to the firmware with its velocity."
          text_size={11}
          text_color={0xFFA9A3B8}
        />
      </Column>
    </Sheet>
    """
  end

  defp sheet(%{sheet: :clock} = assigns) do
    dismiss = {self(), :sheet}
    m = assigns.midi

    modes =
      for mode <- [:follow, :send, :off],
          do: chip(to_string(mode), m.clock == mode, {:clock, mode})

    slower = {self(), {:bpm, max(20, m.bpm - 1)}}
    faster = {self(), {:bpm, min(300, m.bpm + 1)}}
    bpm = "#{m.bpm} BPM"

    ~MOB"""
    <Sheet id="clock" detents={[:content]} on_dismiss={dismiss} background={0xFF1C1925}>
      <Column padding={20} gap={12}>
        <Text text="MIDI clock" text_size={17} text_color={0xFFF3EFF8} font_weight="bold" />
        <Row gap={6}>
          {modes}
        </Row>
        <Text
          text="Follow: clock, start and stop from the devices above drive the firmware. Send: FMutate is the clock, out of the virtual port and into the firmware. Off: no clock either way."
          text_size={11}
          text_color={0xFFA9A3B8}
        />
        <Row gap={8} align={:center} :if={m.clock == :send}>
          <Button
            text="−"
            on_tap={slower}
            background={0xFF2A2636}
            text_color={0xFFF3EFF8}
            text_size={16}
            corner_radius={10}
            fill_width={false}
          />
          <Text
            text={bpm}
            text_size={15}
            text_color={0xFFF3EFF8}
            font="monospace"
            text_align="center"
            weight={1}
          />
          <Button
            text="+"
            on_tap={faster}
            background={0xFF2A2636}
            text_color={0xFFF3EFF8}
            text_size={16}
            corner_radius={10}
            fill_width={false}
          />
        </Row>
      </Column>
    </Sheet>
    """
  end

  defp chip(label, selected, tag) do
    tap = {self(), tag}
    {bg, fg} = if selected, do: {c(:selected), c(:fm)}, else: {c(:raised), c(:text)}

    ~MOB"""
    <Button
      text={label}
      on_tap={tap}
      background={bg}
      text_color={fg}
      text_size={13}
      corner_radius={9}
      fill_width={false}
      padding={8}
    />
    """
  end

  ## Events

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    surface = Instance.journal(@instance, 300) |> Enum.filter(&match?({_, :surface, _, _}, &1)) |> Enum.take(3)

    {:noreply,
     Mob.Socket.assign(socket,
       audio: Audio.stats(),
       latency: MIDI.latency(@instance),
       held: Instance.held(@instance),
       surface_notes: surface
     )}
  catch
    # Audio or the instance's MIDI restarting: keep the last figures until the next poll
    :exit, _ -> {:noreply, socket}
  end

  def handle_info({:tap, :back}, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}

  def handle_info({:tap, {:debug, what}}, socket) do
    Instance.debug(@instance, what)
    {:noreply, socket}
  end

  def handle_info({:tap, :release_all}, socket) do
    Instance.release_all(@instance)
    {:noreply, socket}
  end

  def handle_info({:tap, :scan}, socket) do
    _ = IO.scan_bluetooth()
    {:noreply, socket}
  end

  def handle_info({:tap, {:sheet, {:bluetooth, address}}}, socket) do
    _ = IO.open_bluetooth(address)
    {:noreply, socket}
  end

  def handle_info({:tap, {:sheet, :none}}, socket), do: {:noreply, socket}

  def handle_info({:tap, {:sheet, sheet}}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :sheet, sheet)}

  def handle_info({:dismiss, :sheet}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :sheet, nil)}

  def handle_info({:tap, {:open, id, true}}, socket) do
    _ = IO.open(id)
    {:noreply, socket}
  end

  def handle_info({:tap, {:open, id, false}}, socket) do
    _ = IO.close(id)
    {:noreply, socket}
  end

  def handle_info({:tap, {:channel, name, ch}}, socket) do
    :ok = MIDI.configure_source(@instance, name, channel: ch)
    {:noreply, Mob.Socket.assign(socket, :midi, MIDI.settings(@instance))}
  end

  def handle_info({:tap, {:notes, name, mode}}, socket) do
    :ok = MIDI.configure_source(@instance, name, notes: mode)
    {:noreply, Mob.Socket.assign(socket, :midi, MIDI.settings(@instance))}
  end

  def handle_info({:tap, {:clock, mode}}, socket) do
    :ok = MIDI.set_clock(@instance, mode)
    {:noreply, Mob.Socket.assign(socket, :midi, MIDI.settings(@instance))}
  end

  def handle_info({:tap, {:bpm, bpm}}, socket) do
    :ok = MIDI.set_bpm(@instance, bpm)
    {:noreply, Mob.Socket.assign(socket, :midi, MIDI.settings(@instance))}
  end

  def handle_info({:tap, {:allow, node}}, socket) do
    _ = Dist.allow(node)
    {:noreply, socket}
  end

  def handle_info({:tap, {:disconnect, node}}, socket) do
    _ = Dist.disconnect(node)
    {:noreply, socket}
  end

  def handle_info({:io, io}, socket), do: {:noreply, Mob.Socket.assign(socket, :io, io)}
  def handle_info({:dist, dist}, socket), do: {:noreply, Mob.Socket.assign(socket, :dist, dist)}

  def handle_info({:instance, @instance, {:state, view}}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :view, view)}

  def handle_info({:tap, {:buffer, buffer}}, socket) do
    :ok = Instance.set_buffer(@instance, buffer)
    {:noreply, socket}
  end

  def handle_info({:tap, {:cpu, mode}}, socket) do
    :ok = Instance.set_cpu(@instance, mode)
    {:noreply, socket}
  end

  # FMutate.Instance, FMutate.IO or FMutate.Dist restarted: subscribed again, with its current state
  def handle_info(msg, socket) when Subscription.message?(msg) do
    case Subscription.handle(msg) do
      {:subscribed, :instance, view} -> {:noreply, Mob.Socket.assign(socket, :view, view)}
      {:subscribed, key, value} -> {:noreply, Mob.Socket.assign(socket, key, value)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
