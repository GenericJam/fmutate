defmodule FMutate.PairScreen do
  @moduledoc """
  Pair an app (protocol.md §1.1, menu → Pair an app): the QR code and the same pairing as a typed code, for a
  sibling app (Humdinger, Magpie) on this phone or another phone on the same Wi-Fi.

  The code is single use, expires after 5 minutes and dies after 5 wrong tries; the screen counts down and
  offers New code. An app that proves the code is put to the player on a sheet with Don't allow / Allow. Its
  name is only a claim (any app can send any name), so the sheet says so: "An app on this phone says it is
  Humdinger" / "An app on another phone says it is Humdinger". A second app asking while the sheet shows is
  refused at once, so Allow answers the app the sheet names. Allow pairs it (`FMutate.Pairing`,
  `FMutate.Dist`): it connects and shows up in I/O, where Disconnect unpairs it.

  Copy code and Copy link (the link to 127.0.0.1, for an app on this phone) put the secret on the clipboard,
  which other apps can read. On Android 9 and older any app in the background can watch the clipboard, so
  there is no Copy at all (`FMutate.Pairing.copy_safe?/0`): the player types the code in the other app. The
  screen takes a copied secret off again (clipboard emptied, unless the player copied something else since)
  once the secret is used, expired, dead or replaced, and when the screen closes.

  A new Wi-Fi address restarts pairing with a new secret (`{:pairing, :restarted}`): a request on the sheet
  is gone with the old one, so the sheet closes.

  Pairing runs only while this screen is open (`FMutate.Pairing.open/1`, closed when the screen goes).
  """

  use Mob.Screen

  alias FMutate.{Pairing, Style}

  @tick_ms 1_000
  # QR: the largest whole module size that fits, and the quiet zone (4 modules, ISO 18004)
  @qr_target 232
  @quiet 4

  # `session` `:clipboard`: `Mob.Clipboard` (the default) or a module with its `put/2` and `get/1`, for tests
  def mount(_params, session, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    clipboard = Map.get(session, :clipboard, Mob.Clipboard)

    {:ok,
     socket
     |> Mob.Socket.assign(request: nil, note: nil, clipboard: clipboard, copied: nil)
     |> open()}
  end

  defp open(socket) do
    case Pairing.open(self()) do
      {:ok, info} -> Mob.Socket.assign(socket, info: info, error: nil, qr: qr(info.link))
      {:error, reason} -> Mob.Socket.assign(socket, info: nil, error: reason, qr: nil)
    end
  catch
    :exit, reason -> Mob.Socket.assign(socket, info: nil, error: {:unavailable, reason}, qr: nil)
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
          <Text text="Pair an app" text_size={24} text_color={0xFFF3EFF8} font_weight="bold" />
        </Row>
        {body(assigns)}
        {note(assigns)}
        {how(assigns)}
        {sheet(assigns)}
      </Column>
    </Scroll>
    """
  end

  defp body(%{error: reason}) when reason != nil do
    retry = {self(), :retry}
    message = error_text(reason)

    card([
      ~MOB(<Text text="Pairing can't start" text_size={17} text_color={0xFFFFB4A3} font_weight="bold" />),
      ~MOB(<Text text={message} text_size={13} text_color={0xFFC9C3D6} />),
      ~MOB(<Button
  text="Try again"
  on_tap={retry}
  background={0xFF2A2636}
  text_color={0xFFF3EFF8}
  text_size={13}
  corner_radius={10}
/>)
    ])
  end

  defp body(%{info: %{status: :open} = info, qr: qr}) do
    renew = {self(), :renew}

    [
      ~MOB"""
      <Column gap={12}>
        <Row>
          <Spacer />
          {qr_canvas(qr)}
          <Spacer />
        </Row>
        <Text
          text={info.code}
          text_size={30}
          text_color={0xFFF3EFF8}
          font="monospace"
          font_weight="bold"
          text_align="center"
        />
        <Text
          text={countdown(info)}
          text_size={12}
          text_color={0xFFA9A3B8}
          font="monospace"
          text_align="center"
        />
      </Column>
      """,
      copy_buttons(info),
      ~MOB"""
      <Button
        text="New code"
        on_tap={renew}
        background={0xFF2A2636}
        text_color={0xFFF3EFF8}
        text_size={13}
        corner_radius={10}
        padding={8}
      />
      """
    ]
    |> Enum.reject(&is_nil/1)
    |> card()
  end

  # expired, used or dead: no QR, only New code
  defp body(%{info: %{status: status}}) do
    renew = {self(), :renew}
    title = dead_title(status)
    text = dead_text(status)

    card([
      ~MOB(<Text text={title} text_size={17} text_color={0xFFF3EFF8} font_weight="bold" />),
      ~MOB(<Text text={text} text_size={13} text_color={0xFFC9C3D6} />),
      ~MOB(<Button
  text="New code"
  on_tap={renew}
  background={0xFFC6F24E}
  text_color={0xFF14121A}
  text_size={14}
  corner_radius={10}
/>)
    ])
  end

  # not where other apps can watch the clipboard (Android 9): the code is typed instead
  defp copy_buttons(%{copy_safe: false}), do: nil

  defp copy_buttons(_info) do
    copy_code = {self(), :copy_code}
    copy_link = {self(), :copy_link}

    ~MOB"""
    <Row gap={8}>
      <Button
        text="Copy code"
        on_tap={copy_code}
        background={0xFF2A2636}
        text_color={0xFFF3EFF8}
        text_size={13}
        corner_radius={10}
        padding={8}
        weight={1}
      />
      <Button
        text="Copy link"
        on_tap={copy_link}
        background={0xFF2A2636}
        text_color={0xFFF3EFF8}
        text_size={13}
        corner_radius={10}
        padding={8}
        weight={1}
      />
    </Row>
    """
  end

  defp card(children) do
    ~MOB"""
    <Column
      background={0xFF1C1925}
      corner_radius={16}
      padding_left={14}
      padding_right={14}
      padding_top={14}
      padding_bottom={14}
      gap={12}
    >
      {children}
    </Column>
    """
  end

  defp note(%{note: nil}), do: nil

  defp note(%{note: {kind, text}}) do
    color = if kind == :ok, do: Style.argb(:fm), else: Style.argb(:warn)
    ~MOB(<Text text={text} text_size={13} text_color={color} font_weight="medium" />)
  end

  defp how(%{info: nil}), do: nil

  defp how(%{info: info}) do
    reach =
      if info.wifi,
        do: "Apps on this phone, or on another phone on this Wi-Fi (#{info.host}).",
        else: "No Wi-Fi: only apps on this phone can pair."

    same_phone =
      if info.copy_safe,
        do: "On this phone, Copy link and paste it there.",
        else: "On this phone, type the code in the other app."

    steps =
      "In the other app (Humdinger, Magpie): Pair with FMutate, then scan this code or type it. #{same_phone}"

    ~MOB"""
    <Column gap={4}>
      <Text text={steps} text_size={12} text_color={0xFFA9A3B8} />
      <Text text={reach} text_size={12} text_color={0xFFA9A3B8} />
      <Text
        text="An app you allow gets full control of FMutate (Erlang distribution: it could run code here). Disconnect it in I/O."
        text_size={12}
        text_color={0xFFA9A3B8}
      />
    </Column>
    """
  end

  ## The Allow sheet

  defp sheet(%{request: nil}), do: nil

  defp sheet(%{request: {_ref, request}}) do
    dismiss = {self(), :request}
    deny = {self(), {:decide, :deny}}
    allow = {self(), {:decide, :allow}}

    ~MOB"""
    <Sheet id="pair_request" detents={[:content]} on_dismiss={dismiss} background={0xFF1C1925}>
      <Column padding={20} gap={12}>
        <Text
          text={request_title(request)}
          text_size={18}
          text_color={0xFFF3EFF8}
          font_weight="bold"
        />
        <Text
          text={request_origin(request)}
          text_size={12}
          text_color={0xFFA98BFF}
          font="monospace"
        />
        {replaces(request)}
        <Text
          text="It can play keys and read the screen, and gets full control of FMutate (Erlang distribution: it could run code here)."
          text_size={13}
          text_color={0xFFC9C3D6}
        />
        <Row gap={8}>
          <Button
            text="Don't allow"
            on_tap={deny}
            background={0xFF2A2636}
            text_color={0xFFF3EFF8}
            text_size={14}
            corner_radius={10}
            weight={1}
          />
          <Button
            text="Allow"
            on_tap={allow}
            background={0xFFC6F24E}
            text_color={0xFF14121A}
            text_size={14}
            corner_radius={10}
            weight={1}
          />
        </Row>
      </Column>
    </Sheet>
    """
  end

  defp replaces(%{replaces: %{app_name: name, device_name: device}}) do
    text = "Replaces #{name}#{on(device)}, paired before under the same name."
    ~MOB(<Text text={text} text_size={12} text_color={0xFFFFB547} />)
  end

  defp replaces(_request), do: nil

  ## Events

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, refresh(socket)}
  end

  def handle_info({:tap, :back}, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}

  def handle_info({:tap, :retry}, socket), do: {:noreply, open(socket)}

  def handle_info({:tap, :renew}, socket) do
    _ = Pairing.renew()
    {:noreply, socket |> Mob.Socket.assign(:note, nil) |> refresh()}
  end

  # (no Copy where it isn't safe: a stale tap copies nothing)
  def handle_info({:tap, :copy_code}, %{assigns: %{info: %{copy_safe: true} = info}} = socket),
    do: {:noreply, socket |> copy(info.code) |> Mob.Socket.assign(:note, {:ok, "Code copied."})}

  # the link to 127.0.0.1: the app it is pasted in runs on this phone
  def handle_info({:tap, :copy_link}, %{assigns: %{info: %{copy_safe: true} = info}} = socket) do
    note = {:ok, "Link copied: paste it in the other app."}
    {:noreply, socket |> copy(info.local_link) |> Mob.Socket.assign(:note, note)}
  end

  def handle_info({:tap, {:decide, decision}}, %{assigns: %{request: {ref, request}}} = socket) do
    _ = Pairing.decide(ref, decision)

    note =
      if decision == :allow,
        do: {:ok, "#{request.app_name} is paired. It connects now; Disconnect it in I/O."},
        else: {:warn, "#{request.app_name} wasn't allowed."}

    {:noreply, socket |> Mob.Socket.assign(request: nil, note: note) |> refresh()}
  end

  # the sheet swiped away: the same as Don't allow, so the app isn't left waiting
  def handle_info({:dismiss, :request}, %{assigns: %{request: {ref, request}}} = socket) do
    _ = Pairing.decide(ref, :deny)

    {:noreply,
     Mob.Socket.assign(socket, request: nil, note: {:warn, "#{request.app_name} wasn't allowed."})}
  end

  # one request at a time: Allow answers the app the sheet names, so another one asking meanwhile is refused
  def handle_info({:pairing, {:request, ref, _request}}, %{assigns: %{request: {_, _}}} = socket) do
    _ = Pairing.decide(ref, :deny)
    {:noreply, socket}
  end

  def handle_info({:pairing, {:request, ref, request}}, socket),
    do: {:noreply, socket |> Mob.Socket.assign(:request, {ref, request}) |> refresh()}

  def handle_info({:pairing, {:withdrawn, ref}}, %{assigns: %{request: {ref, request}}} = socket),
    do:
      {:noreply,
       Mob.Socket.assign(socket,
         request: nil,
         note: {:warn, "#{request.app_name} stopped asking."}
       )}

  def handle_info({:pairing, {:secret, _status}}, socket), do: {:noreply, refresh(socket)}

  # a new address, a new endpoint: the request on the sheet went with the old one
  def handle_info({:pairing, :restarted}, %{assigns: %{request: {_ref, request}}} = socket) do
    note = {:warn, "#{request.app_name} stopped asking."}
    {:noreply, socket |> Mob.Socket.assign(request: nil, note: note) |> refresh()}
  end

  def handle_info({:pairing, :restarted}, socket), do: {:noreply, refresh(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  def terminate(_reason, socket), do: forget_copied(socket)

  # the code, its status and the countdown; a new link (New code) redraws the QR
  defp refresh(%{assigns: %{error: nil}} = socket) do
    case Pairing.info() do
      nil ->
        socket |> forget_copied() |> open()

      info ->
        qr = if info.link == socket.assigns.info.link, do: socket.assigns.qr, else: qr(info.link)
        socket |> Mob.Socket.assign(info: info, qr: qr) |> forget_spent()
    end
  catch
    :exit, _ -> socket
  end

  defp refresh(socket), do: socket

  ## The clipboard

  defp copy(socket, secret) do
    socket.assigns.clipboard.put(socket, secret)
    Mob.Socket.assign(socket, :copied, secret)
  end

  # the copied secret no longer pairs: used, expired, too many tries, or replaced (New code, a new address)
  defp forget_spent(%{assigns: %{copied: copied, info: info}} = socket) do
    if copied != nil and (info.status != :open or copied not in [info.code, info.local_link]),
      do: forget_copied(socket),
      else: socket
  end

  # empties the clipboard if it still holds what this screen copied (not what the player copied since)
  defp forget_copied(%{assigns: %{copied: nil}} = socket), do: socket

  defp forget_copied(%{assigns: %{copied: copied, clipboard: clipboard}} = socket) do
    if clipboard.get(socket) == {:clipboard, :ok, copied}, do: clipboard.put(socket, "")
    Mob.Socket.assign(socket, :copied, nil)
  end

  ## Text

  defp countdown(%{expires_in: ms, attempts_left: left}) do
    s = div(ms + 999, 1000)

    time =
      "expires in #{div(s, 60)}:#{s |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"

    if left < 5,
      do: "#{time} · #{left} #{if left == 1, do: "try", else: "tries"} left",
      else: time
  end

  defp dead_title(:expired), do: "This code has expired"
  defp dead_title(:used), do: "This code was used"
  defp dead_title(:invalid), do: "Too many wrong codes"

  defp dead_text(:expired), do: "Codes last 5 minutes. Make a new one to pair an app."
  defp dead_text(:used), do: "Each code pairs one app. Make a new one to pair another."

  defp dead_text(:invalid),
    do: "Someone typed a wrong code 5 times, so this code no longer works."

  defp error_text({:unavailable, _}),
    do: "The pairing service isn't running. Try again in a moment."

  defp error_text({:certificate, _}), do: "FMutate's pairing certificate can't be read."
  defp error_text(reason), do: "Couldn't open the pairing port (#{inspect(reason)})."

  defp request_title(%{remote_ip: {127, _, _, _}, app_name: name}),
    do: "An app on this phone says it is #{name}"

  defp request_title(%{app_name: name}), do: "An app on another phone says it is #{name}"

  defp request_origin(%{remote_ip: {127, _, _, _}, device_name: device}),
    do: "this phone" <> on(device)

  defp request_origin(%{remote_ip: ip, device_name: device}),
    do: "Wi-Fi #{ip |> :inet.ntoa() |> List.to_string()}" <> on(device)

  defp on(device) when is_binary(device) and device != "", do: " · on #{device}"
  defp on(_device), do: ""

  ## QR code

  # The link as dark modules on a light square (the quiet zone included). Each dark module is drawn as part of
  # its horizontal run and of its vertical run: at a fractional pixel scale, rects that only touch leave
  # antialiased seams between rows (or columns), which the other direction's rects cover.
  defp qr(link) do
    %EQRCode.Matrix{matrix: rows} = EQRCode.encode(link, :m)
    rows = rows |> Tuple.to_list() |> Enum.map(&Tuple.to_list/1)
    n = length(rows)
    module = max(div(@qr_target, n + 2 * @quiet), 3)
    size = (n + 2 * @quiet) * module
    ink = Style.color(:ink)
    at = fn i -> (i + @quiet) * module end

    across =
      for {row, y} <- Enum.with_index(rows), {x, len} <- runs(row),
          do: Mob.Canvas.rect(at.(x), at.(y), len * module, module, color: ink, fill: true)

    down =
      for {column, x} <- rows |> Enum.zip_with(& &1) |> Enum.with_index(), {y, len} <- runs(column),
          do: Mob.Canvas.rect(at.(x), at.(y), module, len * module, color: ink, fill: true)

    background = Mob.Canvas.rect(0, 0, size, size, color: Style.color(:paper), fill: true)
    %{size: size, ops: [background | across ++ down]}
  end

  defp runs(cells) do
    {runs, open} =
      cells
      |> Enum.with_index()
      |> Enum.reduce({[], nil}, fn
        {1, x}, {acc, nil} -> {acc, {x, 1}}
        {1, _x}, {acc, {start, len}} -> {acc, {start, len + 1}}
        {_, _x}, {acc, nil} -> {acc, nil}
        {_, _x}, {acc, run} -> {[run | acc], nil}
      end)

    Enum.reverse(if open, do: [open | runs], else: runs)
  end

  defp qr_canvas(%{size: size, ops: ops}),
    do: ~MOB(<Canvas id="pair_qr" width={size} height={size} draw={ops} />)
end
