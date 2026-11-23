defmodule FMutate.SoundsSheet do
  @moduledoc """
  The Sounds sheet over the instrument (the Opling menu's Sounds): the running synth's saved sounds
  (`FMutate.Sounds`). Save sound… (a name, then a new entry), the list (newest first: name, local date and time,
  version; one made with another version of this synth says so), per entry Load / Export / Delete (asks first),
  Import…, and Undo last load. Loading, saving and undoing restart the synth for a moment; they run in a task and
  the sheet says what it is doing meanwhile.

  It works on the instrument screen's socket. Its assign is `sounds` (nil while the sheet is closed and nothing
  runs); it sets the screen's `picking: :sounds` while the file picker is open, and uses the instrument's `toast`
  (`FMutate.Editor`) for a result that arrives after the sheet was closed. Events (`event/2`): taps and changes
  tagged `{:sounds, _}`, `{:alert, :sounds_*}`, `{:files, …}` while picking, `{:mob_share, :error, _}`,
  `{:sounds_done, op, result}` from its task.
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
      backend: nil,
      entries: [],
      undo: false,
      naming: false,
      name: "",
      busy: nil,
      status: nil,
      pending: nil
    }
  end

  # the running synth's list and undo, read again
  defp refresh(socket) do
    s = socket.assigns.sounds
    fw = Firmware.get(socket.assigns.view.firmware)
    backend = fw && Map.get(Firmware.runnable(fw.id) || %{}, :backend)

    {entries, undo} =
      if fw && backend do
        entries = Enum.map(Sounds.list(fw.id), &Map.delete(&1, :bytes))
        {entries, Sounds.undo?(socket.assigns.instance, fw.id, backend)}
      else
        {[], false}
      end

    Mob.Socket.assign(socket, :sounds, %{s | firmware: fw, backend: backend, entries: entries, undo: undo})
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

  def event({:tap, {:sounds, _}}, %{assigns: %{sounds: %{busy: busy}}} = socket) when busy != nil, do: socket

  def event({:tap, {:sounds, :name}}, socket) do
    s = socket.assigns.sounds
    name = "#{(s.firmware && s.firmware.name) || "Sound"} #{Sounds.local_time(now())}"
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
          load(socket, sound)

        {:other_version, made, have} ->
          socket
          |> put(pending: {:load, path})
          |> Mob.Alert.alert(
            title: "Load “#{sound.name}”?",
            message: "Made with #{made}; you have #{have}. Load anyway?",
            buttons: [[label: "Load anyway", action: :sounds_load_anyway], [label: "Cancel", style: :cancel]]
          )

        {:error, text} ->
          refused(socket, text)
      end
    else
      {:error, text} -> refused(socket, text)
    end
  end

  def event({:tap, {:sounds, {:export, path}}}, socket) do
    dir = Path.join(Mob.Storage.dir(:cache), "exports")

    with {:ok, sound} <- Sounds.read(path),
         {:ok, out} <- Sounds.export(sound, dir) do
      Mob.Share.file(socket, out, mime: "application/json", title: sound.name)
    else
      {:error, text} -> refused(socket, text)
    end
  end

  def event({:tap, {:sounds, {:delete, path}}}, socket) do
    name = Enum.find_value(socket.assigns.sounds.entries, "this sound", &(&1.path == path && &1.name))

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

  def event({:tap, {:sounds, :undo}}, socket),
    do: run(socket, :undo, "Undoing the last load…", fn instance -> Sounds.undo(instance) end)

  def event({:alert, :sounds_delete}, %{assigns: %{sounds: %{pending: {:delete, path}}}} = socket) do
    case Enum.find(socket.assigns.sounds.entries, &(&1.path == path)) do
      nil -> socket
      sound -> Sounds.delete(sound)
    end

    socket |> put(pending: nil, status: {:ok, "Deleted."}) |> refresh()
  end

  def event({:alert, :sounds_load_anyway}, %{assigns: %{sounds: %{pending: {:load, path}}}} = socket) do
    socket = put(socket, pending: nil)

    with {:ok, sound} <- Sounds.read(path),
         {:ok, running} <- Sounds.running(socket.assigns.instance),
         # (the player said yes to the other version; everything else is checked again)
         :ok <- anyway(Sounds.check(sound, running)) do
      load(socket, sound)
    else
      {:error, text} -> refused(socket, text)
    end
  end

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

  def event({:sounds_done, op, result}, socket) do
    socket = put(socket, busy: nil)

    text =
      case {op, result} do
        {:save, {:ok, sound}} -> {:ok, "Saved “#{sound.name}”."}
        {:load, :ok} -> {:ok, "Loaded. Undo last load puts back what was there."}
        {:undo, :ok} -> {:ok, "Undone. Undo again to redo."}
        {_, {:error, text}} -> {:error, text}
      end

    if socket.assigns.sounds.open do
      socket |> put(status: text, naming: false) |> refresh()
    else
      socket |> Mob.Socket.assign(:sounds, nil) |> toast(elem(text, 1))
    end
  end

  def event(_message, socket), do: socket

  defp anyway({:other_version, _made, _have}), do: :ok
  defp anyway(answer), do: answer

  defp save(socket) do
    name = socket.assigns.sounds.name
    run(socket, :save, "Saving… the synth restarts for a moment.", &Sounds.save(&1, name))
  end

  defp load(socket, sound),
    do: run(socket, :load, "Loading “#{sound.name}”… the synth restarts for a moment.", &Sounds.load(&1, sound))

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

    put(socket, busy: busy, status: nil)
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
    synth = (s.firmware && s.firmware.name) || assigns.view.firmware
    dismiss = {self(), {:sounds, :close}}
    bg = Style.argb(:surface)

    children =
      [
        title(synth),
        text("A sound is everything #{synth} keeps in its memory: every patch and setting. " <>
               "Loading one restarts the synth for a moment.", 12, :muted),
        # (saving restarts it too: an edit the synth hasn't saved itself, e.g. OberVave's `*`, is gone then)
        text("Save your edits in #{synth} first: what it hasn't saved isn't in its memory.", 12, :muted)
      ] ++
        status(s, running) ++
        save_row(s, idle) ++
        [section("Saved")] ++
        entries(s, idle) ++
        [
          row([
            button("Import…", :import, disabled: not idle),
            button("Undo last load", :undo, disabled: not (idle and s.undo))
          ])
        ]

    [
      ~MOB"""
      <Sheet id="sounds" detents={[:large]} on_dismiss={dismiss} background={bg}>
        <Scroll>
          <Column padding={16} gap={12} background={bg}>
            {children}
          </Column>
        </Scroll>
      </Sheet>
      """
    ]
  end

  def sheets(_assigns), do: []

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

  defp entries(%{entries: []} = s, _idle),
    do: [text("No sounds saved for #{(s.firmware && s.firmware.name) || "this synth"} yet.", 12, :muted)]

  defp entries(s, idle) do
    have = s.firmware && s.firmware.version

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

      ~MOB"""
      <Column padding={12} gap={6} background={bg} corner_radius={12}>
        {children}
      </Column>
      """
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
