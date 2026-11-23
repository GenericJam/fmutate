defmodule FMutate.LayoutsSheet do
  @moduledoc """
  The Layouts sheet (Opling menu › Layouts), over the instrument: the layout library (`FMutate.Layouts.library/0`)
  and the running synth's layout.

  From the top: Undo / Redo of the last change to the layout (the same slot as the edit pill's button),
  "Original layout (classic FM-1)", "Save current layout" under a name (always a new entry), then the saved
  layouts, newest first (name, the synth each was saved from, local date and time), each with Load (it becomes
  this synth's layout, undoable), Export (the share sheet with its `.json`) and Delete (asks first), and
  Import… (a `.json` picked with `Mob.Files.pick/2`, validated, added to the library without loading it).

  It works on the instrument screen's socket. Assign: `layouts`, nil while closed, else `%{entries, name,
  confirm}` (the saved layouts, the name being typed, the entry whose Delete is being confirmed); `picking:
  :layouts` while its file picker is open. Events: `{:tap | :dismiss, {:layouts, action}}`, `{:change |
  :submit, {:layouts, :name}, text}`; the picker's `{:files, …}` go to `picked/2`. Loading, Original layout and
  Undo change the layout through `FMutate.Editor`, which owns it.
  """

  import Mob.Sigil, only: [sigil_MOB: 2]

  alias FMutate.{Editor, Firmware, Layouts, Style}

  @doc "Open the sheet."
  def open(socket) do
    name = get_in(socket.assigns, [:layout, "name"]) || ""
    socket |> Mob.Socket.assign(:layouts, %{entries: [], name: name, confirm: nil}) |> reload()
  end

  defp reload(socket), do: update(socket, entries: Layouts.library())

  defp update(socket, kv), do: Mob.Socket.assign(socket, :layouts, Map.merge(socket.assigns.layouts, Map.new(kv)))

  defp close(socket), do: Mob.Socket.assign(socket, :layouts, nil)

  @doc "Handle a sheet event (see the module doc)."
  def event(kind, tag, value \\ nil, socket)

  def event(:dismiss, _tag, _v, socket), do: close(socket)
  def event(:tap, {:layouts, :close}, _v, socket), do: close(socket)

  def event(kind, {:layouts, :name}, name, socket) when kind in [:change, :submit] and is_binary(name),
    do: update(socket, name: name)

  def event(:tap, {:layouts, :save}, _v, socket) do
    case Layouts.save_to_library(socket.assigns.layout, socket.assigns.layouts.name) do
      {:ok, entry} -> socket |> reload() |> toast("Saved “#{entry.name}”")
      {:error, [msg | _]} -> toast(socket, "Not saved: " <> msg)
    end
  end

  def event(:tap, {:layouts, :undo}, _v, socket), do: Editor.undo(socket)
  def event(:tap, {:layouts, :original}, _v, socket), do: socket |> close() |> Editor.original()

  def event(:tap, {:layouts, {:load, file}}, _v, socket) do
    %{instance: instance, firmware: firmware} = socket.assigns

    case Layouts.load_saved(instance, firmware, file) do
      {:ok, layout} -> socket |> close() |> Editor.changed(layout, "“#{layout["name"]}” loaded · Undo in Layouts or the edit bar")
      {:error, [msg | _]} -> toast(socket, "Not loaded: " <> msg)
    end
  end

  def event(:tap, {:layouts, {:export, file}}, _v, socket) do
    case Layouts.export_saved(file, Path.join(Mob.Storage.dir(:cache), "exports")) do
      {:ok, path} -> Mob.Share.file(socket, path, mime: "application/json", title: entry_name(socket, file))
      {:error, [msg | _]} -> toast(socket, "Not exported: " <> msg)
    end
  end

  def event(:tap, {:layouts, {:delete, file}}, _v, socket), do: update(socket, confirm: file)
  def event(:tap, {:layouts, :keep}, _v, socket), do: update(socket, confirm: nil)

  def event(:tap, {:layouts, {:delete_now, file}}, _v, socket) do
    _ = Layouts.delete_saved(file)
    socket |> update(confirm: nil) |> reload()
  end

  def event(:tap, {:layouts, :import}, _v, socket),
    do: socket |> Mob.Socket.assign(:picking, :layouts) |> Mob.Files.pick(types: ["json"])

  def event(_kind, _tag, _v, socket), do: socket

  @doc """
  The file picker's answer (`{:files, :picked, items}` or `{:files, :cancelled}`). Android's picker can't filter
  by extension, so the file is recognised by its content (`FMutate.Layouts.import_file/1`).
  """
  def picked(socket, {:files, :picked, [item | _]}) do
    socket = Mob.Socket.assign(socket, :picking, nil)
    path = item[:path] || item["path"]
    name = item[:name] || item["name"] || Path.basename(path)

    case Layouts.import_file(path) do
      {:ok, entry} -> if(socket.assigns.layouts, do: reload(socket), else: socket) |> toast("Imported “#{entry.name}”")
      {:error, [msg | _]} -> toast(socket, "#{name} wasn't imported: #{msg}")
    end
  end

  def picked(socket, _cancelled), do: Mob.Socket.assign(socket, :picking, nil)

  defp entry_name(socket, file) do
    case Enum.find(socket.assigns.layouts.entries, &(&1.file == file)) do
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> "Layout"
    end
  end

  # over the sheet (the instrument's own toast is drawn under it)
  defp toast(socket, text), do: Mob.Alert.toast(socket, text, duration: :long)

  ## Rendering

  @doc "The sheet as a list of nodes (empty while closed)."
  def sheets(%{layouts: %{} = state} = assigns), do: [sheet(assigns, state)]
  def sheets(_assigns), do: []

  defp sheet(assigns, state) do
    dismiss = {self(), {:layouts, :close}}
    name_change = {self(), {:layouts, :name}}
    synth = firmware_name(assigns.firmware)

    # Undo / Redo of the last change to this synth's layout (the edit pill's button), beside Original layout
    undo =
      case assigns[:undo] do
        :undo -> [button("Undo last change", :undo)]
        :redo -> [button("Redo", :undo)]
        nil -> []
      end

    entries =
      case state.entries do
        [] -> [caption("Nothing saved yet.")]
        list -> Enum.map(list, &entry(&1, state.confirm))
      end

    children =
      [
        title("Layouts", "on #{synth}"),
        caption(
          "Saved layouts work on any synth: Load puts one on #{synth}. Its MIDI note and CC bindings and learned " <>
            "MIDI controls come along as they are; check them on another synth."
        ),
        row(undo ++ [button("Original layout (classic FM-1)", :original)]),
        section("Save current layout"),
        ~MOB"""
        <Row gap={8}>
          <TextField value={state.name} on_change={name_change} max_length={40} text_color={c(:text)} background={c(:raised)} weight={2} />
          {button("Save", :save, bg: c(:fm), fg: c(:ink))}
        </Row>
        """,
        section("Saved")
      ] ++
        entries ++
        [row([button("Import…", :import), button("Close", :close)])]

    ~MOB"""
    <Sheet id="layouts" detents={[:large]} on_dismiss={dismiss} background={c(:surface)}>
      <Scroll>
        <Column padding={16} gap={12} background={c(:surface)}>
          {children}
        </Column>
      </Scroll>
    </Sheet>
    """
  end

  defp entry(e, confirm) do
    from = "from #{if e.firmware == "any", do: "any synth", else: firmware_name(e.firmware)} · #{local_time(e.saved_at)}"

    actions =
      if confirm == e.file,
        do: [
          button("Delete “#{e.name}”", {:delete_now, e.file}, bg: c(:danger_bg), fg: c(:danger_text)),
          button("Keep it", :keep)
        ],
        else: [
          button("Load", {:load, e.file}),
          button("Export", {:export, e.file}),
          button("Delete", {:delete, e.file}, fg: c(:danger_text))
        ]

    ~MOB"""
    <Column gap={6} background={c(:raised)} padding={10}>
      <Text text={e.name} text_size={15} font_weight="bold" text_color={c(:text)} />
      <Text text={from} text_size={12} text_color={c(:muted)} />
      {row(actions)}
    </Column>
    """
  end

  @doc false
  # an ISO 8601 UTC time as the player's local "2026-11-22 18:04"
  def local_time(iso) do
    case DateTime.from_iso8601(to_string(iso)) do
      {:ok, at, _} ->
        at
        |> DateTime.to_unix()
        |> :calendar.system_time_to_local_time(:second)
        |> NaiveDateTime.from_erl!()
        |> Calendar.strftime("%Y-%m-%d %H:%M")

      _ ->
        "unknown time"
    end
  end

  defp firmware_name(nil), do: "this synth"

  defp firmware_name(id) do
    case Firmware.get(id) do
      %{name: name} -> name
      nil -> id
    end
  end

  defp c(name), do: Style.argb(name)

  defp title(text, aside) do
    ~MOB"""
    <Row gap={8}>
      <Text text={text} text_size={22} font_weight="bold" text_color={c(:text)} weight={1} />
      <Text text={aside} text_size={11} text_color={c(:muted)} />
    </Row>
    """
  end

  defp section(text) do
    text = String.upcase(text)

    ~MOB"""
    <Text text={text} text_size={11} font_weight="bold" text_color={c(:muted)} />
    """
  end

  defp caption(text) do
    ~MOB"""
    <Text text={text} text_size={12} text_color={c(:muted)} />
    """
  end

  defp row(buttons) do
    ~MOB"""
    <Row gap={8}>
      {buttons}
    </Row>
    """
  end

  defp button(text, action, opts \\ []) do
    tap = {self(), {:layouts, action}}
    bg = opts[:bg] || c(:raised_hi)
    fg = opts[:fg] || c(:text)

    ~MOB"""
    <Button text={text} on_tap={tap} background={bg} text_color={fg} text_size={13} fill_width={true} padding={8} weight={1} />
    """
  end
end
