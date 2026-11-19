defmodule FMutate.FirmwareScreen do
  @moduledoc """
  A firmware's synth page, opened from its library card (`FMutate.LibraryScreen`). HANDOFF has no board for it;
  it follows the library's look (`FMutate.Style` tokens, the card's badges and pills):

    * the Hub's card picture, when there is one (the maker's, through the Hub);
    * name, status, how it runs, version, licence, the maker and a link to the repository, tags;
    * the card's actions, handled as on the card (`FMutate.LibraryUI`): Switch, Download, Update, Delete, Why?,
      Run anyway;
    * the Hub's card text (the maker's), then the README of the firmware's repository at the ref its build or
      package comes from (`FMutate.Library.Description`), as headings, paragraphs and lists, cut at a section
      boundary with "Read the full README" (the browser). The README shows from the phone's copy at once and
      is read again in the background (`Mob.Socket.start_async/3`); offline, the copy stays, with when it was
      read; with neither, the card text is what there is;
    * whose each text and picture is, with a link to their repository, and the Hub's list licence.

  Built-in firmwares read the README at the commit the app's cartridge was built from; an imported package has
  only its file name, and says so.
  """

  use Mob.Screen

  require FMutate.Subscription
  require FMutate.LibraryUI

  alias FMutate.{Firmware, Instance, Library, LibraryUI, Subscription}
  alias FMutate.Library.Description

  @instance "a"

  def mount(%{id: id}, _session, socket) do
    {:ok, view} =
      Subscription.subscribe(:instance, Instance.via(@instance), fn ->
        Instance.subscribe(@instance)
      end)

    {:ok, :ok} = Subscription.subscribe(:library, Library, &Library.subscribe/0)

    socket =
      socket
      |> Mob.Socket.assign(id: id, view: view, why: nil, toast: nil)
      |> load()

    fw = socket.assigns.fw
    source? = fw != nil and Description.source(fw) != nil

    socket =
      Mob.Socket.assign(socket,
        description: fw && Description.cached(fw),
        reading: source?,
        picture: fw && Description.cached_picture(fw)
      )

    socket =
      if source?,
        do: Mob.Socket.start_async(socket, :description, fn -> Description.load(fw) end),
        else: socket

    socket =
      if fw && fw.picture && socket.assigns.picture == nil,
        do: Mob.Socket.start_async(socket, :picture, fn -> Description.picture(fw) end),
        else: socket

    {:ok, socket}
  end

  # the firmware and what its actions need, re-read on every change (a server restarting leaves the last state)
  defp load(socket) do
    Mob.Socket.assign(socket,
      fw: Firmware.get(socket.assigns.id),
      quarantined: Instance.quarantined(@instance),
      info: Library.info(),
      emu?: Library.emu?()
    )
  catch
    :exit, _ -> socket
  end

  ## Render

  def render(%{fw: nil}) do
    back = {self(), :back}

    ~MOB"""
    <Column background="#14121A" fill_width={true} fill_height={true} padding={20} gap={12}>
      <Button
        text="‹ Library"
        on_tap={back}
        background="#221F2B"
        text_color="#F3EFF8"
        text_size={14}
        fill_width={false}
        corner_radius={14}
      />
      <Text text="This firmware isn’t in the library any more." text_size={15} text_color="#A9A3B8" />
    </Column>
    """
    |> FMutate.Style.native_colors()
  end

  def render(assigns) do
    fw = assigns.fw
    status = LibraryUI.status(fw, assigns)
    back = {self(), :back}
    name = fw.name
    meta = LibraryUI.meta(fw)
    badge = LibraryUI.badge(status)
    backend = LibraryUI.backend(fw)
    new_badge = if fw.new, do: LibraryUI.new_badge()
    ios_note = LibraryUI.ios_note?(fw)
    why = LibraryUI.why(fw, status, assigns)
    actions = LibraryUI.actions(fw, status, assigns)
    tags = Enum.map(fw.tags, &LibraryUI.tag_chip/1)
    has_note = is_binary(fw.note)
    note = fw.note || ""
    toast = LibraryUI.toast(assigns.toast)

    ~MOB"""
    <Box background="#14121A" padding={0} fill_width={true} fill_height={true}>
      <Column fill_width={true} fill_height={true} background="#14121A">
        <Row padding_left={20} padding_right={20} padding_top={16} padding_bottom={8}>
          <Button
            text="‹ Library"
            on_tap={back}
            background="#221F2B"
            text_color="#F3EFF8"
            text_size={14}
            font_weight="bold"
            fill_width={false}
            corner_radius={14}
          />
        </Row>
        <Scroll weight={1}>
          <Column padding_left={20} padding_right={20} padding_bottom={24} gap={12}>
            {picture(fw, assigns.picture)}
            <Text text={name} text_size={30} text_color="#F3EFF8" font_weight="bold" />
            <Row gap={6} align={:center}>
              {badge}
              {new_badge}
              {backend}
            </Row>
            <Text text={meta} text_size={12} text_color="#A9A3B8" />
            {maker(fw)}
            <Text
              text="Plays emulated on iPhone until the next app update"
              text_size={12}
              text_color="#FFB547"
              :if={ios_note}
            />
            {why}
            <Wrap spacing={6} run_spacing={6}>
              {tags}
            </Wrap>
            <Row gap={6} align={:center}>
              {actions}
            </Row>
            <Text text={note} text_size={13} text_color="#C9C3D6" :if={has_note} />
            {card_text(fw)}
            {readme(fw, assigns)}
            {licence(fw)}
          </Column>
        </Scroll>
        {toast}
      </Column>
    </Box>
    """
    |> FMutate.Style.native_colors()
  end

  defp picture(_fw, nil), do: nil

  defp picture(fw, path) do
    caption = "Picture: #{fw.author}’s, from their repository through The Firmware Hub"

    ~MOB"""
    <Column gap={4}>
      <Image
        src={path}
        height={200}
        corner_radius={18}
        content_mode="fit"
        placeholder_color="#1C1925"
      />
      <Text text={caption} text_size={11} text_color="#6B6580" />
    </Column>
    """
  end

  # the maker and their repository (a link: the browser)
  defp maker(%{source: :imported}), do: nil

  defp maker(fw) do
    by = "by #{fw.author}"

    case https(fw.repo) do
      nil ->
        ~MOB"""
        <Text text={by} text_size={14} text_color="#F3EFF8" />
        """

      url ->
        open = {self(), {:open_url, url}}
        label = short(url) <> " ↗"

        ~MOB"""
        <Row gap={8} align={:center}>
          <Text text={by} text_size={14} text_color="#F3EFF8" />
          <Button
            text={label}
            on_tap={open}
            background="#221F2B"
            text_color="#8FD8FF"
            text_size={13}
            fill_width={false}
            corner_radius={14}
            padding={8}
          />
        </Row>
        """
    end
  end

  # the short text on its card: the maker's on a Hub firmware (fmhub.json, through the Hub's list)
  defp card_text(%{about: about} = fw) when is_binary(about) and about != "" do
    label =
      if fw.source == :hub, do: "#{fw.author}’s card text on The Firmware Hub", else: "About"

    ~MOB"""
    <Box background="#1C1925" corner_radius={18} padding={14}>
      <Column gap={6}>
        <Text text={label} text_size={11} text_color="#A9A3B8" font_weight="bold" />
        <Text text={about} text_size={15} text_color="#F3EFF8" />
      </Column>
    </Box>
    """
  end

  defp card_text(_fw), do: nil

  defp readme(%{source: :imported}, _assigns) do
    ~MOB"""
    <Text
      text="An imported package carries no description: FMutate knows only its file name."
      text_size={13}
      text_color="#A9A3B8"
    />
    """
  end

  defp readme(fw, assigns) do
    case Description.source(fw) do
      nil ->
        ~MOB"""
        <Text
          text="No GitHub repository is listed for it, so there is no README to show."
          text_size={13}
          text_color="#A9A3B8"
        />
        """

      src ->
        readme_section(fw, src, assigns.description, assigns.reading)
    end
  end

  defp readme_section(fw, src, desc, reading) do
    repo_url = "https://github.com/" <> src.repo
    open_repo = {self(), {:open_url, repo_url}}
    at = if src.ref, do: " at " <> short_ref(src.ref), else: ""
    attribution = "#{fw.author}’s description, from github.com/#{src.repo}#{at}"
    state = readme_state(desc, reading)
    has_state = state != nil
    state = state || ""
    blocks = Enum.map((desc && desc.readme && desc.readme.blocks) || [], &block/1)
    full = full_link(src, desc)

    ~MOB"""
    <Column gap={10} padding_top={8}>
      <Text text="README" text_size={20} text_color="#F3EFF8" font_weight="bold" />
      <Text text={attribution} text_size={12} text_color="#8FD8FF" on_tap={open_repo} />
      <Text text={state} text_size={12} text_color="#FFB547" :if={has_state} />
      {blocks}
      {full}
    </Column>
    """
  end

  defp readme_state(nil, true), do: "Reading the README…"
  defp readme_state(%{status: :fresh}, _reading), do: nil
  defp readme_state(%{status: :cached}, true), do: nil

  defp readme_state(%{status: :cached, fetched_at: t}, false),
    do: "Offline: the README as read on #{date(t)}."

  defp readme_state(%{status: :missing}, _reading),
    do: "Couldn’t read the README (offline?). The card text above is what there is for now."

  defp readme_state(nil, false),
    do: "Couldn’t read the README (offline?). The card text above is what there is for now."

  defp readme_state(_desc, _reading), do: nil

  # "Read the full README" when the page shows only its start, or none of it
  defp full_link(src, desc) do
    if desc == nil or desc.readme == nil or desc.readme.truncated do
      url = Description.page_url(src, desc && desc.file)
      open = {self(), {:open_url, url}}

      ~MOB"""
      <Button
        text="Read the full README ↗"
        on_tap={open}
        background="#221F2B"
        text_color="#8FD8FF"
        text_size={14}
        font_weight="bold"
        fill_width={false}
        corner_radius={14}
      />
      """
    end
  end

  defp block({:heading, level, text}) do
    size = if level <= 2, do: 18, else: 15

    ~MOB"""
    <Text text={text} text_size={size} text_color="#F3EFF8" font_weight="bold" />
    """
  end

  defp block({:paragraph, text}) do
    ~MOB"""
    <Text text={text} text_size={14} text_color="#D6D0E0" />
    """
  end

  defp block({:list, items}) do
    rows = Enum.map(items, &item/1)

    ~MOB"""
    <Column gap={4}>
      {rows}
    </Column>
    """
  end

  defp item(text) do
    ~MOB"""
    <Row gap={8}>
      <Text text="•" text_size={14} text_color="#A9A3B8" />
      <Text text={text} text_size={14} text_color="#D6D0E0" weight={1} />
    </Row>
    """
  end

  defp licence(%{source: :hub} = fw) do
    repo = if https(fw.repo), do: " (#{short(fw.repo)})", else: ""

    text =
      "Firmware list: The Firmware Hub – https://thefirmwarehub.com (CC-BY-4.0). Its card text, picture and README " <>
        "are #{fw.author}’s#{repo}, not under that licence. Not affiliated with M-VAVE."

    ~MOB"""
    <Text text={text} text_size={11} text_color="#6B6580" />
    """
  end

  defp licence(_fw), do: nil

  defp https("https://" <> _ = url), do: url
  defp https(_url), do: nil

  defp short(url), do: url |> String.replace_prefix("https://", "") |> String.trim_trailing("/")

  # a commit as its first 7 characters, a tag as it is
  defp short_ref(ref), do: if(ref =~ ~r/^[0-9a-f]{40}$/, do: String.slice(ref, 0, 7), else: ref)

  defp date(nil), do: "an earlier day"

  defp date(secs),
    do:
      secs
      |> :calendar.system_time_to_local_time(:second)
      |> NaiveDateTime.from_erl!()
      |> Calendar.strftime("%Y-%m-%d")

  ## Events

  def handle_async(:description, {:ok, desc}, socket),
    do: {:noreply, Mob.Socket.assign(socket, description: desc, reading: false)}

  def handle_async(:description, {:exit, _reason}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :reading, false)}

  def handle_async(:picture, {:ok, {:ok, path}}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :picture, path)}

  def handle_async(:picture, _result, socket), do: {:noreply, socket}

  def handle_info({:tap, :back}, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}

  # only the https links the page builds (the repository, the README on GitHub)
  def handle_info({:tap, {:open_url, url}}, socket) do
    if https(url), do: open_url().(url)
    {:noreply, socket}
  end

  def handle_info({:tap, tag}, socket) when LibraryUI.action?(tag),
    do: {:noreply, LibraryUI.tap(tag, socket, &load/1)}

  def handle_info({:toast_expired, toast}, socket),
    do: {:noreply, LibraryUI.toast_expired(toast, socket)}

  def handle_info({:library, :changed}, socket), do: {:noreply, load(socket)}

  def handle_info({:instance, @instance, {:state, view}}, socket),
    do: {:noreply, socket |> Mob.Socket.assign(:view, view) |> load()}

  def handle_info(msg, socket) when Subscription.message?(msg) do
    case Subscription.handle(msg) do
      {:subscribed, :instance, view} ->
        {:noreply, socket |> Mob.Socket.assign(:view, view) |> load()}

      {:subscribed, :library, :ok} ->
        {:noreply, load(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # the browser (`:fmutate_app, :open_url` replaces it where there is no device, in tests)
  defp open_url, do: Application.get_env(:fmutate_app, :open_url, &Mob.Device.open_url/1)
end
