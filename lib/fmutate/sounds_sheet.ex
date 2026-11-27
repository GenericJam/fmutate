defmodule FMutate.SoundsSheet do
  @moduledoc """
  The Sounds sheet over the instrument (the Opling menu's Sounds): the running synth's saved sounds
  (`FMutate.Sounds`). Save sound… (a name, then a new entry), the list (newest first: name, local date and time,
  version; one made with another version of this synth says so), per entry Load / Export / Delete (asks first),
  Import…, Undo last load, and Reset to original (asks first: every patch and setting back to how the synth came;
  Undo puts them back). A sound or an undo made with another version asks first. Loading, saving, undoing and
  resetting restart the synth for a moment; they run in a task and the sheet says what it is doing meanwhile. The
  list is read in a task too (each file in turn, without its payload) and drawn as a lazy list.

  It works on the instrument screen's socket. Its assign is `sounds` (nil while the sheet is closed and nothing
  runs); it sets the screen's `picking: :sounds` while the file picker is open, and uses the instrument's `toast`
  (`FMutate.Editor`) for a result that arrives after the sheet was closed. Events (`event/2`): taps and changes
  tagged `{:sounds, _}`, `{:alert, :sounds_*}`, `{:files, …}` while picking, `{:mob_share, :error, _}`, and its
  tasks' `{:sounds_done, op, result}` and `{:sounds_listed, firmware_id, entries, undo}`.
  """

  import Mob.Sigil, only: [sigil_MOB: 2]

  require Logger

  alias FMutate.{Firmware, Sounds, Style}

  @doc "Open the sheet for the running synth."
  def open(socket), do: socket |> Mob.Socket.assign(:sounds, %{fresh() | open: true}) |> refresh()

  defp fresh do
    %{
      open: false,
      firmware: nil,
      # nil while the list is being read
      entries: nil,
      undo: false,
      naming: false,
      name: "",
      busy: nil,
      status: nil,
      pending: nil
    }
  end

  # the running synth's list and undo, read again in a task
  defp refresh(socket) do
    id = socket.assigns.view.firmware
    fw = Firmware.get(id)
    instance = socket.assigns.instance
    me = self()

    Task.start(fn ->
      {entries, undo} =
        try do
          backend =
            case Sounds.running(instance) do
              {:ok, %{backend: b}} -> b
              _ -> nil
            end

          {Sounds.list(id), backend != nil and Sounds.undo?(instance, id, backend)}
        catch
          kind, reason ->
            Logger.error("sounds: listing #{id} failed: #{Exception.format(kind, reason)}")
            {[], false}
        end

      send(me, {:sounds_listed, id, entries, undo})
    end)

    put(socket, firmware: %{id: id, name: (fw && fw.name) || id, version: fw && fw.version})
  end

  defp put(socket, changes), do: Mob.Socket.assign(socket, :sounds, Map.merge(socket.assigns.sounds, Map.new(changes)))

  ## Events

  @doc "Handle a message while the sheet is open or its work runs; anything else leaves the socket as it is."
  def event({:dismiss, {:sounds, :close}}, socket) do
    if socket.assigns.sounds.busy,
      do: put(socket, open: false),
      else: Mob.Socket.assign(socket, :sounds, nil)
  end

  def event({:tap, {:sounds, :close}}, socket), do: event({:dismiss, {:sounds, :close}}, socket)

  def event({:sounds_listed, id, entries, undo}, %{assigns: %{sounds: %{firmware: %{id: id}}}} = socket),
    do: put(socket, entries: entries, undo: undo)

  def event({:sounds_listed, _id, _entries, _undo}, socket), do: socket

  def event({:tap, {:sounds, _}}, %{assigns: %{sounds: %{busy: busy}}} = socket) when busy != nil, do: socket
  # (a dialog shows on the UI thread after its tap: an answer arriving while something already runs starts nothing)
  def event({:alert, _}, %{assigns: %{sounds: %{busy: busy}}} = socket) when busy != nil, do: put(socket, pending: nil)
  def event({:submit, {:sounds, :name}}, %{assigns: %{sounds: %{busy: busy}}} = socket) when busy != nil, do: socket

  def event({:tap, {:sounds, :name}}, socket) do
    name = "#{socket.assigns.sounds.firmware.name} #{Sounds.local_time(now())}"
    put(socket, naming: true, name: name, status: nil)
  end

  def event({:tap, {:sounds, :cancel_name}}, socket), do: put(socket, naming: false)

  def event({:change, {:sounds, :name}, name}, socket) when is_binary(name), do: put(socket, name: name)

  def event({:submit, {:sounds, :name}}, socket), do: save(socket)
  def event({:tap, {:sounds, :save}}, socket), do: save(socket)

  def event({:tap, {:sounds, {:load, path}}}, socket) do
    with {:ok, sound} <- Sounds.read(path),
         {:ok, running} <- Sounds.running(socket.assigns.instance) do
      case Sounds.check(sound, running) do
        :ok ->
          load(socket, sound, [])

        {:other_version, made, have} ->
          socket
          |> put(pending: {:load, path})
          |> ask_version("Load “#{sound.name}”?", made, have, "Load anyway", :sounds_load_anyway)

        {:error, text} ->
          refused(socket, text)
      end
    else
      {:error, text} -> refused(socket, text)
    end
  end

  def event({:tap, {:sounds, {:export, path}}}, socket) do
    dir = Path.join(Mob.Storage.dir(:cache), "exports")

    with %{} = sound <- entry(socket, path) || {:error, "It's gone."},
         {:ok, out} <- Sounds.export(sound, dir) do
      Mob.Share.file(socket, out, mime: "application/json", title: sound.name)
    else
      {:error, text} -> refused(socket, text)
    end
  end

  def event({:tap, {:sounds, {:delete, path}}}, socket) do
    name = (entry(socket, path) || %{name: "this sound"}).name

    socket
    |> put(pending: {:delete, path})
    |> Mob.Alert.alert(
      title: "Delete “#{name}”?",
      message: "It can’t be brought back.",
      buttons: [[label: "Delete", style: :destructive, action: :sounds_delete], [label: "Cancel", style: :cancel]]
    )
  end

  def event({:tap, {:sounds, :import}}, socket),
    do: socket |> Mob.Socket.assign(:picking, :sounds) |> Mob.Files.pick(types: ["json"])

  def event({:tap, {:sounds, :undo}}, socket), do: undo(socket, [])

  def event({:tap, {:sounds, :reset}}, socket) do
    synth = socket.assigns.sounds.firmware.name

    socket
    |> put(pending: :reset)
    |> Mob.Alert.alert(
      title: "Reset #{synth} to its original settings?",
      message:
        "Every patch and setting goes back to how #{synth} came. Undo last load puts back what is there now; " <>
          "save it as a sound first to keep it for longer.",
      buttons: [[label: "Reset", style: :destructive, action: :sounds_reset], [label: "Cancel", style: :cancel]]
    )
  end

  def event({:alert, :sounds_delete}, %{assigns: %{sounds: %{pending: {:delete, path}}}} = socket) do
    Sounds.delete(%{path: path})
    socket |> put(pending: nil, status: {:ok, "Deleted."}) |> refresh()
  end

  def event({:alert, :sounds_load_anyway}, %{assigns: %{sounds: %{pending: {:load, path}}}} = socket) do
    socket = put(socket, pending: nil)

    case Sounds.read(path) do
      {:ok, sound} -> load(socket, sound, anyway: true)
      {:error, text} -> refused(socket, text)
    end
  end

  def event({:alert, :sounds_undo_anyway}, %{assigns: %{sounds: %{pending: :undo}}} = socket),
    do: socket |> put(pending: nil) |> undo(anyway: true)

  def event({:alert, :sounds_reset}, %{assigns: %{sounds: %{pending: :reset}}} = socket),
    do: socket |> put(pending: nil) |> run(:reset, "Resetting… the synth restarts for a moment.", &Sounds.reset/1)

  def event({:alert, _}, socket), do: put(socket, pending: nil)

  # Android's picker can't filter on .json: the content says whether it is a sound
  def event({:files, :picked, [item | _]}, %{assigns: %{picking: :sounds}} = socket) do
    socket = Mob.Socket.assign(socket, :picking, nil)
    path = item[:path] || item["path"]

    case Sounds.import(path, socket.assigns.instance) do
      {:ok, sound} -> socket |> put(status: {:ok, "Imported “#{sound.name}”."}) |> refresh()
      {:error, text} -> refused(socket, "Not imported: " <> text)
    end
  end

  def event({:files, _, _}, %{assigns: %{picking: :sounds}} = socket), do: Mob.Socket.assign(socket, :picking, nil)

  def event({:files, :cancelled}, %{assigns: %{picking: :sounds}} = socket),
    do: Mob.Socket.assign(socket, :picking, nil)

  def event({:mob_share, :error, reason}, socket),
    do: refused(socket, "Couldn’t open the share sheet (#{reason}).")

  # an undo made with another version: the player says
  def event({:sounds_done, :undo, {:other_version, made, have}}, socket) do
    socket
    |> put(busy: nil, pending: :undo)
    |> ask_version("Undo the last load?", made, have, "Undo anyway", :sounds_undo_anyway)
  end

  def event({:sounds_done, op, result}, socket) do
    socket = put(socket, busy: nil)

    text =
      case {op, result} do
        {:save, {:ok, sound}} -> {:ok, "Saved “#{sound.name}”."}
        {:load, :ok} -> {:ok, "Loaded. Undo last load puts back what was there."}
        {:undo, :ok} -> {:ok, "Undone. Undo again to redo."}
        {:reset, :ok} -> {:ok, "Back to the original settings. Undo last load puts back what was there."}
        {_, {:other_version, _, _}} -> {:error, "Made with another version: not loaded."}
        {_, {:error, text}} -> {:error, text}
      end

    if socket.assigns.sounds.open do
      socket |> put(status: text, naming: false) |> refresh()
    else
      socket |> Mob.Socket.assign(:sounds, nil) |> toast(elem(text, 1))
    end
  end

  def event(_message, socket), do: socket

  defp entry(socket, path), do: Enum.find(socket.assigns.sounds.entries || [], &(&1.path == path))

  defp ask_version(socket, title, made, have, yes, action) do
    Mob.Alert.alert(socket,
      title: title,
      message: "Made with #{made || "an unknown version"}; you have #{have || "an unknown version"}. #{yes}?",
      buttons: [[label: yes, action: action], [label: "Cancel", style: :cancel]]
    )
  end

  defp save(socket) do
    name = socket.assigns.sounds.name
    run(socket, :save, "Saving… the synth restarts for a moment.", &Sounds.save(&1, name))
  end

  defp load(socket, sound, opts) do
    busy = "Loading “#{sound.name}”… the synth restarts for a moment."
    run(socket, :load, busy, &Sounds.load(&1, sound, opts))
  end

  defp undo(socket, opts),
    do: run(socket, :undo, "Undoing the last load…", &Sounds.undo(&1, opts))

  # the work in a task (it stops and starts the firmware); its answer comes back as {:sounds_done, op, result}
  defp run(socket, op, busy, fun) do
    me = self()
    instance = socket.assigns.instance

    Task.start(fn ->
      result =
        try do
          fun.(instance)
        catch
          kind, reason ->
            Logger.error("sounds: #{op} failed: #{Exception.format(kind, reason)}")
            {:error, "It didn’t work (#{inspect(reason)})."}
        end

      send(me, {:sounds_done, op, result})
    end)

    put(socket, busy: busy, status: nil, pending: nil)
  end

  defp refused(socket, text), do: put(socket, status: {:error, text})

  defp toast(socket, text) do
    {seq, _} = socket.assigns.toast
    Mob.Socket.assign(socket, :toast, {seq + 1, text})
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  ## Rendering

  @doc "The sheet as a list of nodes (empty when it isn't open)."
  def sheets(%{sounds: %{open: true} = s} = assigns) do
    running = assigns.view.phase == :running
    idle = running and s.busy == nil
    synth = s.firmware.name
    dismiss = {self(), {:sounds, :close}}
    bg = Style.argb(:surface)

    status_rows =
      case status(s, running) do
        [] -> []
        lines -> [row_of("status", lines)]
      end

    rows =
      [
        row_of("title", [title(synth)]),
        row_of("caption", [
          text("A sound is everything #{synth} keeps in its memory: every patch and setting. " <>
                 "Loading one restarts the synth for a moment.", 12, :muted),
          # (saving restarts it too: an edit the synth hasn't saved itself, e.g. OberVave's `*`, is gone then)
          text("Save your edits in #{synth} first: what it hasn't saved isn't in its memory.", 12, :muted)
        ])
      ] ++
        status_rows ++
        [row_of("save", save_row(s, idle)), row_of("saved", [section("Saved")])] ++
        entries(s, idle) ++
        [
          row_of("footer", [
            row([
              button("Import…", :import, disabled: not idle),
              button("Undo last load", :undo, disabled: not (idle and s.undo))
            ]),
            row([button("Reset to original", :reset, disabled: not idle)])
          ])
        ]

    [
      ~MOB"""
      <Sheet id="sounds" detents={[:large]} on_dismiss={dismiss} background={bg}>
        <LazyList id="sounds_list" weight={1} background={bg}>
          {rows}
        </LazyList>
      </Sheet>
      """
    ]
  end

  def sheets(_assigns), do: []

  # one LazyList row: the list has no padding or gap of its own, so the row carries them
  defp row_of(id, children) do
    bg = Style.argb(:surface)

    ~MOB"""
    <Column id={id} padding_left={16} padding_right={16} padding_top={6} padding_bottom={6} gap={8} background={bg}
      fill_width={true}>
      {children}
    </Column>
    """
  end

  defp title(synth) do
    color = Style.argb(:text)
    muted = Style.argb(:muted)

    ~MOB"""
    <Row gap={8}>
      <Text text="Sounds" text_size={22} font_weight="bold" text_color={color} weight={1} />
      <Text text={synth} text_size={13} text_color={muted} />
    </Row>
    """
  end

  defp status(%{busy: busy}, _running) when busy != nil, do: [text(busy, 13, :fm, true)]
  defp status(_s, false), do: [text("The synth isn't running.", 13, :warn)]
  defp status(%{status: {:ok, text}}, _running), do: [text(text, 13, :fm)]
  defp status(%{status: {:error, text}}, _running), do: [text(text, 13, :danger_text, true)]
  defp status(_s, _running), do: []

  defp save_row(%{naming: true} = s, idle) do
    change = {self(), {:sounds, :name}}
    fg = Style.argb(:text)
    field_bg = Style.argb(:raised)
    name = s.name

    [
      ~MOB"""
      <TextField value={name} on_change={change} on_submit={change} max_length={60} text_color={fg}
        background={field_bg} fill_width={true} />
      """,
      row([button("Save", :save, disabled: not idle, primary: true), button("Cancel", :cancel_name)])
    ]
  end

  defp save_row(_s, idle), do: [row([button("Save sound…", :name, disabled: not idle, primary: true)])]

  defp entries(%{entries: nil}, _idle), do: [row_of("reading", [text("Reading…", 12, :muted)])]

  defp entries(%{entries: []} = s, _idle),
    do: [row_of("none", [text("No sounds saved for #{s.firmware.name} yet.", 12, :muted)])]

  defp entries(s, idle) do
    have = s.firmware.version

    for sound <- s.entries do
      made = sound.firmware.version
      bg = Style.argb(:raised_hi)
      meta = text("#{Sounds.local_time(sound.saved_at)} · #{made}", 12, :muted)

      other =
        if made != have,
          do: [text("Made with #{made}; this #{sound.firmware.name} is #{have}.", 12, :warn)],
          else: []

      buttons =
        row([
          button("Load", {:load, sound.path}, disabled: not idle),
          button("Export", {:export, sound.path}),
          button("Delete", {:delete, sound.path}, disabled: not idle)
        ])

      children = [text(sound.name, 15, :text, true), meta] ++ other ++ [buttons]

      row_of(sound.path, [
        ~MOB"""
        <Column padding={12} gap={6} background={bg} corner_radius={12}>
          {children}
        </Column>
        """
      ])
    end
  end

  defp section(label), do: text(String.upcase(label), 11, :muted, true)

  defp text(text, size, color, bold \\ false) do
    weight = if bold, do: "bold", else: "regular"
    color = Style.argb(color)

    ~MOB"""
    <Text text={text} text_size={size} font_weight={weight} text_color={color} />
    """
  end

  defp row(children) do
    ~MOB"""
    <Row gap={8} fill_width={true}>
      {children}
    </Row>
    """
  end

  defp button(label, action, opts \\ []) do
    disabled = opts[:disabled] == true

    {bg, fg} =
      cond do
        disabled -> {Style.argb(:raised), Style.argb(:faint)}
        opts[:primary] -> {Style.argb(:selected), Style.argb(:fm)}
        true -> {Style.argb(:raised), Style.argb(:text)}
      end

    %{
      type: :button,
      props: %{
        text: label,
        on_tap: {self(), {:sounds, action}},
        background: bg,
        text_color: fg,
        text_size: 13,
        disabled: disabled,
        fill_width: true,
        weight: 1,
        padding: 8
      },
      children: []
    }
  end
end
