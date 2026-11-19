defmodule FMutate.LibraryUI do
  @moduledoc """
  What the library's cards (`FMutate.LibraryScreen`) and a firmware's synth page (`FMutate.FirmwareScreen`)
  share: a firmware's status badge, how it runs (Native / Emulated), its meta line, its actions — Switch,
  Download, Why?, Run anyway, plus Delete and Update — and what a tap on one does, with the toast "Your <old>
  saves and layout are kept" and Undo after a switch.

  A screen using it has the assigns `view` (the instance's view), `quarantined`, `emu?`, `info`
  (`FMutate.Library.info/0`), `why` and `toast`, a `load/1` that re-reads the library (`tap/3` takes it), and
  passes `{:toast_expired, toast}` to `toast_expired/2`.
  """

  import Mob.Sigil

  alias FMutate.{Firmware, Instance, Library, Style}
  alias FMutate.Library.Catalog

  @instance "a"
  @toast_ms 6_000

  @actions [:switch, :run_anyway, :download, :delete, :why]

  @doc "Whether a tap's tag is one of the actions `tap/3` handles."
  defguard action?(tag)
           when tag == :undo or
                  (is_tuple(tag) and tuple_size(tag) == 2 and elem(tag, 0) in @actions)

  @doc "A firmware's status (`FMutate.Library.Catalog.status/2`) from a screen's assigns."
  @spec status(Firmware.t(), map) :: Catalog.status()
  def status(fw, assigns),
    do:
      Catalog.status(fw, %{
        current: assigns.view.firmware,
        quarantined: assigns.quarantined,
        emu?: assigns.emu?
      })

  @badges %{
    on_phone: {"On phone", :raised_hi, "#E4DFEE"},
    available: {"Available", :surface, :text_2},
    not_yet: {"Doesn’t run here yet", :surface, :warn},
    quarantined: {"Quarantined", :danger_bg, :danger_text},
    running: {"Running", :fm_tint, :fm}
  }

  @doc "The status badge."
  def badge(status) do
    {label, bg, fg} = @badges[status]
    bg = color(bg)
    fg = color(fg)

    ~MOB"""
    <Box background={bg} corner_radius={8} padding={6} fill_width={false}>
      <Text text={label} text_size={11} text_color={fg} font_weight="bold" />
    </Box>
    """
  end

  @doc "How it runs: Native (lime) or Emulated."
  def backend(fw) do
    {label, fg} =
      if fw.backend == :native, do: {"Native", "#C6F24E"}, else: {"Emulated", "#C9C3D6"}

    ~MOB"""
    <Box background="#2A2636" corner_radius={6} padding={4} fill_width={false}>
      <Text text={label} text_size={11} text_color={fg} font_weight="bold" />
    </Box>
    """
  end

  @doc "\"New\" for a native build the player hasn't seen."
  def new_badge do
    ~MOB"""
    <Box background="#C6F24E" corner_radius={8} padding={6} fill_width={false}>
      <Text text="New" text_size={11} text_color="#14121A" font_weight="bold" />
    </Box>
    """
  end

  @doc "Maker, version (a native build's with its short commit), licence, size."
  def meta(%{source: :imported} = fw), do: "imported · #{fw.version} · #{size(fw.size)}"

  def meta(%{backend: :native, native: %{} = n} = fw) do
    commit = if is_binary(n.commit), do: " · " <> String.slice(n.commit, 0, 7), else: ""
    "#{fw.author} · v#{n.version}#{commit} · #{fw.license}"
  end

  def meta(fw) do
    base = "#{fw.author} · v#{fw.version} · #{fw.license}"
    if fw.source == :hub and fw.size, do: base <> " · " <> size(fw.size), else: base
  end

  @doc "A size in MB."
  def size(nil), do: "?"
  def size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  def tag_chip(tag) do
    ~MOB"""
    <Box background="#2A2636" corner_radius={6} padding={4} fill_width={false}>
      <Text text={tag} text_size={11} text_color="#C9C3D6" />
    </Box>
    """
  end

  @doc "iOS runs only the native cartridges linked into the app."
  def ios_note?(fw), do: fw.backend == :emu and fw.native != nil

  @doc "What Why? explains, when it is open for `fw`."
  def why(fw, status, assigns) do
    if assigns.why == fw.id and status == :not_yet do
      ~MOB"""
      <Text
        text="This build has no emulator engine yet, so it can only run firmwares built in as native cartridges. The package stays on the phone and runs once the emulator ships."
        text_size={12}
        text_color="#FFB547"
      />
      """
    end
  end

  @doc "The action pills for a firmware: Delete, Update, then its one action (nils where none)."
  def actions(fw, status, assigns) do
    downloads = assigns.info.downloads
    [delete_button(fw, status), update_button(fw, downloads), action(fw, status, downloads)]
  end

  defp action(fw, status, downloads) do
    case {status, downloads[fw.id]} do
      {:available, {got, total}} ->
        pill("Downloading #{percent(got, total)}", nil, :raised_hi, :text_2)

      {:available, nil} ->
        pill(download_label(fw), {:download, fw.id}, :raised_hi, :text)

      {:on_phone, _} ->
        pill("Switch", {:switch, fw.id}, :fm, :ink)

      {:not_yet, _} ->
        pill("Why?", {:why, fw.id}, :surface, "#E4DFEE")

      {:quarantined, _} ->
        pill("Run anyway", {:run_anyway, fw.id}, :surface, :danger_text)

      {:running, _} ->
        nil
    end
  end

  defp percent(_got, nil), do: "…"
  defp percent(got, total), do: "#{div(got * 100, max(total, 1))}%"

  defp download_label(%{size: size}) when is_integer(size), do: "Download · " <> size(size)
  defp download_label(_fw), do: "Download"

  # a newer native build than the downloaded one: the old one keeps running until this one is in
  defp update_button(fw, downloads) do
    case {Catalog.update?(fw), downloads[fw.id]} do
      {true, {got, total}} -> pill("Updating #{percent(got, total)}", nil, :raised_hi, :text_2)
      {true, nil} -> pill("Update · " <> size(fw.size), {:download, fw.id}, :raised_hi, :text)
      _ -> nil
    end
  end

  defp delete_button(%{source: s, package: p} = fw, status)
       when s in [:hub, :imported] and is_binary(p) and status != :running,
       do: pill("Delete", {:delete, fw.id}, :surface, :muted)

  defp delete_button(
         %{backend: :native, source: :hub, cart: c, native: %{bundled: nil}} = fw,
         status
       )
       when is_binary(c) and status != :running,
       do: pill("Delete", {:delete, fw.id}, :surface, :muted)

  defp delete_button(_fw, _status), do: nil

  @doc "A pill button (`tag` nil: a plain chip, e.g. download progress, not a disabled button)."
  def pill(label, nil, bg, fg) do
    bg = color(bg)
    fg = color(fg)

    ~MOB"""
    <Box background={bg} corner_radius={20} padding={12} fill_width={false}>
      <Text text={label} text_size={13} text_color={fg} font_weight="bold" />
    </Box>
    """
  end

  def pill(label, tag, bg, fg) do
    tap = {self(), tag}
    bg = color(bg)
    fg = color(fg)

    ~MOB"""
    <Button
      text={label}
      on_tap={tap}
      background={bg}
      text_color={fg}
      text_size={13}
      font_weight="bold"
      fill_width={false}
      corner_radius={20}
      padding={10}
    />
    """
  end

  @doc "A token or a hex colour."
  def color(token) when is_atom(token), do: Style.color(token)
  def color(hex), do: hex

  @doc "The toast, or nil."
  def toast(nil), do: nil

  def toast(t) do
    undo = {self(), :undo}
    has_undo = t.undo != nil

    ~MOB"""
    <Column padding_left={12} padding_right={12} padding_top={8} background="#14121A">
      <Box background="#F3EFF8" corner_radius={16} padding={12}>
        <Row gap={12} align={:center}>
          <Column weight={1} gap={2}>
            <Text text={t.title} text_size={13} text_color="#14121A" font_weight="bold" />
            <Text text={t.body} text_size={13} text_color="#14121A" />
          </Column>
          <Button
            text="Undo"
            on_tap={undo}
            background="#F3EFF8"
            text_color="#5B3FD6"
            font_weight="bold"
            text_size={13}
            fill_width={false}
            :if={has_undo}
          />
        </Row>
      </Box>
    </Column>
    """
  end

  ## Events

  @doc "Handle an action's tap (`action?/1`); `load` re-reads the library into the socket."
  def tap({:switch, id}, socket, load), do: switch(socket, id, true, load)

  def tap(:undo, socket, load) do
    case socket.assigns.toast do
      %{undo: id} when is_binary(id) -> switch(socket, id, false, load)
      _ -> socket
    end
  end

  def tap({:run_anyway, id}, socket, load) do
    _ = Instance.run_anyway(@instance, id)
    load.(socket)
  end

  def tap({:download, id}, socket, load) do
    _ = Library.download(id)
    load.(socket)
  end

  def tap({:delete, id}, socket, load) do
    _ = Library.delete(id)
    load.(socket)
  end

  def tap({:why, id}, socket, _load) do
    why = if socket.assigns.why == id, do: nil, else: id
    Mob.Socket.assign(socket, :why, why)
  end

  @doc "A toast's time is up: it goes, unless another has replaced it."
  def toast_expired(toast, socket) do
    if socket.assigns.toast == toast, do: Mob.Socket.assign(socket, :toast, nil), else: socket
  end

  # switch, then a toast offering to switch back (`undoable`: false for the undo itself)
  defp switch(socket, id, undoable, load) do
    old = Firmware.get(socket.assigns.view.firmware)
    new = Firmware.get(id)

    case Instance.switch_firmware(@instance, id) do
      :ok ->
        old_name = if old, do: old.name, else: "old firmware"
        undo = if undoable and old, do: old.id

        socket
        |> show_toast(
          "Switching to #{new.name}…",
          "Your #{old_name} saves and layout are kept.",
          undo
        )
        |> load.()

      {:error, reason} ->
        show_toast(socket, "Can’t switch to #{new && new.name}", explain(reason), nil)
    end
  end

  defp explain(:quarantined), do: "It crashed twice. Use Run anyway."
  defp explain(:not_installed), do: "It doesn’t run in this build yet."
  defp explain(other), do: inspect(other)

  @doc "Show a toast for a few seconds (`undo`: the firmware id Undo switches back to, or nil)."
  def show_toast(socket, title, body, undo) do
    toast = %{title: title, body: body, undo: undo, at: System.unique_integer()}
    Process.send_after(self(), {:toast_expired, toast}, @toast_ms)
    Mob.Socket.assign(socket, :toast, toast)
  end
end
