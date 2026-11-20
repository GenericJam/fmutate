defmodule FMutate.LibraryScreen do
  @moduledoc """
  The firmware library (HANDOFF §9, board `Flat-Library`): the now-running card (▶ back to the
  instrument), search, tag filter, and a card per firmware with its status, how it runs (Native /
  Emulated), "New" for a native build the player hasn't seen, and one action — Switch, Download, Why?, Run
  anyway — plus Delete for a package or cartridge on the phone and Update for a newer native build. Switching
  is one tap and stays here, with a toast "Your <old> saves and layout are kept" and Undo. Import `.fwsc`
  sits in the footer; stock M-VAVE firmware is bring-your-own (import only).
  """

  use Mob.Screen

  require FMutate.Subscription

  alias FMutate.{Firmware, Instance, Library, Style, Subscription}
  alias FMutate.Library.Catalog

  @instance "a"
  @toast_ms 6_000
  @tag_count 8

  def mount(_params, _session, socket) do
    {:ok, view} = Subscription.subscribe(:instance, Instance.via(@instance), fn -> Instance.subscribe(@instance) end)
    {:ok, :ok} = Subscription.subscribe(:library, Library, &Library.subscribe/0)

    socket =
      Mob.Socket.assign(socket,
        view: view,
        query: "",
        tag: nil,
        why: nil,
        toast: nil,
        # native builds shown as New on this visit (the library has marked them seen)
        fresh: MapSet.new()
      )

    {:ok, load(socket)}
  end

  # the catalogue, quarantine and library state, re-read on every change; a server restarting under
  # it leaves the last state (its resubscription reloads). New native builds stay New for this visit and
  # are seen from now on.
  defp load(socket) do
    firmwares = Firmware.all()
    new = for fw <- firmwares, fw.new, do: fw.id
    if new != [], do: Library.mark_seen(new)

    Mob.Socket.assign(socket,
      firmwares: firmwares,
      fresh: MapSet.union(socket.assigns[:fresh] || MapSet.new(), MapSet.new(new)),
      quarantined: Instance.quarantined(@instance),
      info: Library.info(),
      emu?: Library.emu?()
    )
  catch
    :exit, _ -> socket
  end

  ## Render

  def render(assigns) do
    ctx = %{current: assigns.view.firmware, quarantined: assigns.quarantined, emu?: assigns.emu?}
    all = assigns.firmwares
    current = Enum.find(all, &(&1.id == assigns.view.firmware))

    shown =
      Enum.filter(all, fn fw ->
        (fw.id != assigns.view.firmware or fw.id in assigns.quarantined) and Catalog.matches?(fw, assigns.query) and
          (assigns.tag == nil or assigns.tag in fw.tags)
      end)

    cards = Enum.map(shown, &card(&1, Catalog.status(&1, ctx), assigns))
    chips = Enum.map([nil | top_tags(all)], &chip(&1, assigns.tag))
    placeholder = "Search #{length(all)} firmwares, authors, tags"
    running = running_card(current, assigns.view)
    toast = toast(assigns.toast)
    status_line = status_line(assigns.info)
    empty = cards == []
    # the list's scroll state is kept per id: a new search or tag starts a new list at the top (one
    # list would keep its first visible row in view while rows are filtered in above it)
    list_id = "library:#{assigns.tag}:#{assigns.query}"

    search = {self(), :search}
    import_tap = {self(), :import}
    refresh = {self(), :refresh}

    ~MOB"""
    <Box background="#14121A" padding={0} fill_width={true} fill_height={true}>
      <Column fill_width={true} fill_height={true} background="#14121A">
        <Column padding_left={20} padding_right={20} padding_top={20} gap={12}>
          <Column gap={4}>
            <Row gap={0}>
              <Text text="FM" text_size={15} text_color="#C6F24E" font_weight="bold" />
              <Text text="utate" text_size={15} text_color="#F3EFF8" />
            </Row>
            <Text text="Firmware" text_size={32} text_color="#F3EFF8" font_weight="bold" />
          </Column>
          <TextField value={@query} placeholder={placeholder} on_change={search} background="#221F2B" text_color="#F3EFF8" placeholder_color="#A9A3B8" border_color="#221F2B" corner_radius={14} padding={14} text_size={15} />
          <Scroll axis="horizontal">
            <Row gap={8}>
              {chips}
            </Row>
          </Scroll>
          {running}
        </Column>
        <LazyList id={list_id} weight={1}>
          {cards}
          <Column id="nothing" padding_left={20} padding_right={20} padding_top={10} :if={empty}>
            <Text text="Nothing matches." text_size={13} text_color="#A9A3B8" />
          </Column>
          <Column id="hub" padding_left={20} padding_right={20} padding_top={16} padding_bottom={16} gap={10}>
            <Text text={status_line} text_size={12} text_color="#A9A3B8" />
            <Button text="Check for updates" on_tap={refresh} background="#221F2B" text_color="#F3EFF8" text_size={13} />
            <Text text="Firmware list: The Firmware Hub – https://thefirmwarehub.com (CC-BY-4.0). Card texts belong to their makers. Not affiliated with M-VAVE." text_size={11} text_color="#6B6580" />
          </Column>
        </LazyList>
        {toast}
        <Row padding_left={20} padding_right={20} padding_top={12} padding_bottom={20} gap={10} background="#14121A" align={:center}>
          <Button text="⇪ Import .fwsc" on_tap={import_tap} background="#221F2B" text_color="#F3EFF8" font_weight="bold" text_size={14} fill_width={false} corner_radius={14} />
          <Text text="Stock M-VAVE firmware: bring your own file." text_size={12} text_color="#A9A3B8" weight={1} />
        </Row>
      </Column>
    </Box>
    """
    |> FMutate.Style.native_colors()
  end

  defp top_tags(firmwares) do
    firmwares
    |> Enum.flat_map(& &1.tags)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {t, n} -> {-n, t} end)
    |> Enum.take(@tag_count)
    |> Enum.map(&elem(&1, 0))
  end

  defp chip(tag, selected) do
    on = tag == selected
    tap = {self(), {:tag, tag}}
    label = if tag, do: String.capitalize(tag), else: "All"
    bg = if on, do: Style.color(:paper), else: Style.color(:raised)
    fg = if on, do: Style.color(:ink), else: "#E4DFEE"

    ~MOB"""
    <Button text={label} on_tap={tap} background={bg} text_color={fg} text_size={13} font_weight="bold" fill_width={false} corner_radius={18} padding={10} />
    """
  end

  defp running_card(nil, _view), do: nil

  defp running_card(fw, view) do
    back = {self(), :back}
    meta = "#{fw.author} · v#{fw.version}" <> phase_note(view)

    ~MOB"""
    <Box background="#C6F24E" corner_radius={18} padding={12}>
      <Row gap={12} align={:center}>
        <Column weight={1} gap={2}>
          <Text text="NOW RUNNING" text_size={11} text_color="#14121A" font_weight="bold" />
          <Text text={fw.name} text_size={18} text_color="#14121A" font_weight="bold" max_lines={1} />
          <Text text={meta} text_size={13} text_color="#14121A" max_lines={1} />
        </Column>
        <Button text="▶" on_tap={back} background="#14121A" text_color="#C6F24E" fill_width={false} corner_radius={24} text_size={18} />
      </Row>
    </Box>
    """
  end

  defp phase_note(%{phase: :running}), do: ""
  defp phase_note(%{phase: :safe_mode}), do: " · safe mode"
  defp phase_note(%{phase: phase}), do: " · #{phase}"

  @badges %{
    on_phone: {"On phone", :raised_hi, "#E4DFEE"},
    available: {"Available", :surface, :text_2},
    not_yet: {"Doesn’t run here yet", :surface, :warn},
    quarantined: {"Quarantined", :danger_bg, :danger_text},
    running: {"Running", :fm_tint, :fm}
  }

  defp card(fw, status, assigns) do
    {badge, badge_bg, badge_fg} = @badges[status]
    badge_bg = color(badge_bg)
    badge_fg = color(badge_fg)
    name = fw.name
    meta = meta(fw)
    desc = fw.about || ""
    has_desc = desc != ""
    tags = Enum.map(Enum.take(fw.tags, 3), &tag_chip/1)
    action = action(fw, status, assigns.info.downloads)
    update = update_button(fw, assigns.info.downloads)
    delete = delete_button(fw, status)
    why = if assigns.why == fw.id and status == :not_yet, do: why_text(), else: nil
    repo = fw.repo || ""
    has_repo = repo != ""
    is_new = fw.new or MapSet.member?(assigns.fresh, fw.id)
    {backend, backend_fg} = if fw.backend == :native, do: {"Native", "#C6F24E"}, else: {"Emulated", "#C9C3D6"}
    # iOS runs only the native cartridges linked into the app
    ios_note = fw.backend == :emu and fw.native != nil

    # one LazyList row: the list has no padding or gap of its own, so the row carries them
    ~MOB"""
    <Column id={fw.id} padding_left={20} padding_right={20} padding_top={10}>
      <Box background="#1C1925" corner_radius={18} padding={12}>
        <Column gap={4}>
          <Row gap={8} align={:center}>
            <Text text={name} text_size={16} text_color="#F3EFF8" font_weight="bold" weight={1} max_lines={1} />
            <Box background="#C6F24E" corner_radius={8} padding={6} fill_width={false} :if={is_new}>
              <Text text="New" text_size={11} text_color="#14121A" font_weight="bold" />
            </Box>
            <Box background={badge_bg} corner_radius={8} padding={6} fill_width={false}>
              <Text text={badge} text_size={11} text_color={badge_fg} font_weight="bold" />
            </Box>
          </Row>
          <Row gap={6} align={:center}>
            <Box background="#2A2636" corner_radius={6} padding={4} fill_width={false}>
              <Text text={backend} text_size={11} text_color={backend_fg} font_weight="bold" />
            </Box>
            <Text text={meta} text_size={11} text_color="#A9A3B8" max_lines={1} weight={1} />
          </Row>
          <Text text="Plays emulated on iPhone until the next app update" text_size={12} text_color="#FFB547" :if={ios_note} />
          <Text text={desc} text_size={13} text_color="#D6D0E0" max_lines={2} :if={has_desc} />
          <Text text={repo} text_size={11} text_color="#6B6580" max_lines={1} :if={has_repo} />
          {why}
          <Row gap={6} align={:center}>
            {tags}
            <Spacer />
            {delete}
            {update}
            {action}
          </Row>
        </Column>
      </Box>
    </Column>
    """
  end

  defp color(token) when is_atom(token), do: Style.color(token)
  defp color(hex), do: hex

  defp meta(%{source: :imported} = fw), do: "imported · #{fw.version} · #{size(fw.size)}"

  defp meta(%{backend: :native, native: %{} = n} = fw) do
    commit = if is_binary(n.commit), do: " · " <> String.slice(n.commit, 0, 7), else: ""
    "#{fw.author} · v#{n.version}#{commit} · #{fw.license}"
  end

  defp meta(fw) do
    base = "#{fw.author} · v#{fw.version} · #{fw.license}"
    if fw.source == :hub and fw.size, do: base <> " · " <> size(fw.size), else: base
  end

  defp size(nil), do: "?"
  defp size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp tag_chip(tag) do
    ~MOB"""
    <Box background="#2A2636" corner_radius={6} padding={4} fill_width={false}>
      <Text text={tag} text_size={11} text_color="#C9C3D6" />
    </Box>
    """
  end

  defp why_text do
    ~MOB"""
    <Text text="This build has no emulator engine yet, so it can only run firmwares built in as native cartridges. The package stays on the phone and runs once the emulator ships." text_size={12} text_color="#FFB547" />
    """
  end

  defp action(fw, status, downloads) do
    case {status, downloads[fw.id]} do
      {:available, {got, total}} -> pill("Downloading #{percent(got, total)}", nil, :raised_hi, :text_2)
      {:available, nil} -> pill(download_label(fw), {:download, fw.id}, :raised_hi, :text)
      {:on_phone, _} -> pill("Switch", {:switch, fw.id}, :fm, :ink)
      {:not_yet, _} -> pill("Why?", {:why, fw.id}, :surface, "#E4DFEE")
      {:quarantined, _} -> pill("Run anyway", {:run_anyway, fw.id}, :surface, :danger_text)
      {:running, _} -> nil
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

  defp delete_button(%{backend: :native, source: :hub, cart: c, native: %{bundled: nil}} = fw, status)
       when is_binary(c) and status != :running,
       do: pill("Delete", {:delete, fw.id}, :surface, :muted)

  defp delete_button(_fw, _status), do: nil

  # a label without a tap (download progress) is a plain chip, not a disabled button
  defp pill(label, nil, bg, fg) do
    bg = color(bg)
    fg = color(fg)

    ~MOB"""
    <Box background={bg} corner_radius={20} padding={12} fill_width={false}>
      <Text text={label} text_size={13} text_color={fg} font_weight="bold" />
    </Box>
    """
  end

  defp pill(label, tag, bg, fg) do
    tap = {self(), tag}
    bg = color(bg)
    fg = color(fg)

    ~MOB"""
    <Button text={label} on_tap={tap} background={bg} text_color={fg} text_size={13} font_weight="bold" fill_width={false} corner_radius={20} padding={10} />
    """
  end

  defp toast(nil), do: nil

  defp toast(t) do
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
          <Button text="Undo" on_tap={undo} background="#F3EFF8" text_color="#5B3FD6" font_weight="bold" text_size={13} fill_width={false} :if={has_undo} />
        </Row>
      </Box>
    </Column>
    """
  end

  defp status_line(info) do
    hub =
      cond do
        info.error -> info.error
        info.refreshing -> "Reading the Hub's catalogue…"
        info.updated -> Enum.join(["Hub catalogue of #{info.updated}." | List.wrap(check_note(info))], " ")
        true -> "No Hub catalogue yet: connect to the internet."
      end

    natives =
      cond do
        info.index_error -> info.index_error
        info.index_refreshing -> "Checking for native builds…"
        info.index_generated -> "Native builds of #{String.slice(info.index_generated, 0, 10)}."
        true -> nil
      end

    Enum.join([hub | List.wrap(natives)], " ")
  end

  # "Checked today · next check after 14:05" while a check would be refused (the Hub's once a day)
  defp check_note(info), do: Library.check_note(info.fetched_at, System.os_time(:second))

  ## Events

  def handle_info({:change, :search, value}, socket), do: {:noreply, Mob.Socket.assign(socket, :query, value)}

  def handle_info({:tap, {:tag, tag}}, socket), do: {:noreply, Mob.Socket.assign(socket, :tag, tag)}

  def handle_info({:tap, :back}, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}

  def handle_info({:tap, {:switch, id}}, socket), do: {:noreply, switch(socket, id, true)}

  def handle_info({:tap, :undo}, socket) do
    case socket.assigns.toast do
      %{undo: id} when is_binary(id) -> {:noreply, switch(socket, id, false)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:tap, {:run_anyway, id}}, socket) do
    _ = Instance.run_anyway(@instance, id)
    {:noreply, load(socket)}
  end

  def handle_info({:tap, {:download, id}}, socket) do
    _ = Library.download(id)
    {:noreply, load(socket)}
  end

  def handle_info({:tap, {:delete, id}}, socket) do
    _ = Library.delete(id)
    {:noreply, load(socket)}
  end

  def handle_info({:tap, {:why, id}}, socket) do
    why = if socket.assigns.why == id, do: nil, else: id
    {:noreply, Mob.Socket.assign(socket, :why, why)}
  end

  # the native builds' list is read on every tap; the Hub's catalogue only once a day (Library.refresh/0)
  def handle_info({:tap, :refresh}, socket) do
    Library.refresh()

    case check_note(socket.assigns.info) do
      nil -> {:noreply, socket}
      note -> {:noreply, show_toast(socket, "The Hub is read once a day", note <> ". Checking for native builds.", nil)}
    end
  end

  def handle_info({:tap, :import}, socket), do: {:noreply, Mob.Files.pick(socket, types: ["fwsc"])}

  # Android's picker can't filter on a custom extension and may hand back a name without it, so the
  # package is recognised by its content (Catalog.import_file/3 checks the UFW header)
  def handle_info({:files, :picked, [item | _]}, socket) do
    {:noreply, socket |> import_item(item) |> load()}
  end

  def handle_info({:files, :picked, []}, socket), do: {:noreply, socket}

  def handle_info({:files, :cancelled}, socket), do: {:noreply, socket}

  def handle_info({:toast_expired, toast}, socket) do
    if socket.assigns.toast == toast,
      do: {:noreply, Mob.Socket.assign(socket, :toast, nil)},
      else: {:noreply, socket}
  end

  def handle_info({:library, :changed}, socket), do: {:noreply, load(socket)}

  def handle_info({:instance, @instance, {:state, view}}, socket),
    do: {:noreply, socket |> Mob.Socket.assign(:view, view) |> load()}

  # FMutate.Instance or FMutate.Library restarted: subscribed again, so re-read everything
  def handle_info(msg, socket) when Subscription.message?(msg) do
    case Subscription.handle(msg) do
      {:subscribed, :instance, view} -> {:noreply, socket |> Mob.Socket.assign(:view, view) |> load()}
      {:subscribed, :library, :ok} -> {:noreply, load(socket)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp import_item(socket, item) do
    path = item[:path] || item["path"]
    name = item[:name] || item["name"] || Path.basename(path)

    case Library.import_package(path, name) do
      {:ok, fw} -> show_toast(socket, "Imported #{fw.name}", "It’s on the phone now.", nil)
      {:error, :not_fwsc} -> show_toast(socket, "Not an FM-1 package", "#{name} isn’t a .fwsc update package.", nil)
      {:error, reason} -> show_toast(socket, "Import failed", inspect(reason), nil)
    end
  end

  # switch, then a toast offering to switch back (`undoable`: false for the undo itself)
  defp switch(socket, id, undoable) do
    old = Firmware.get(socket.assigns.view.firmware)
    new = Firmware.get(id)

    case Instance.switch_firmware(@instance, id) do
      :ok ->
        old_name = if old, do: old.name, else: "old firmware"
        undo = if undoable and old, do: old.id

        socket
        |> show_toast("Switching to #{new.name}…", "Your #{old_name} saves and layout are kept.", undo)
        |> load()

      {:error, reason} ->
        show_toast(socket, "Can’t switch to #{new && new.name}", explain(reason), nil)
    end
  end

  defp explain(:quarantined), do: "It crashed twice. Use Run anyway."
  defp explain(:not_installed), do: "It doesn’t run in this build yet."
  defp explain(other), do: inspect(other)

  defp show_toast(socket, title, body, undo) do
    toast = %{title: title, body: body, undo: undo, at: System.unique_integer()}
    Process.send_after(self(), {:toast_expired, toast}, @toast_ms)
    Mob.Socket.assign(socket, :toast, toast)
  end
end
