defmodule FMutate.Editor do
  @moduledoc """
  Layout editing on the instrument screen (HANDOFF §5, boards Edit-Drag, Edit-Add, Editor, Editor-Keys,
  Pages): the screen-side half. The native surface (android `fmutate/EditMode.kt`) draws edit mode and
  proposes edits as events; this module applies them with `FMutate.LayoutEdit`, saves the result
  (`FMutate.Layouts.save/3`) and hands the surface the new layout. It also renders the sheets: binding
  sheet, keyboard strip settings, page grid, layout settings, presets.

  It works on the screen's socket. Assigns it owns: `layout` (decoded), `layout_json`, `firmware`,
  `page` (page id shown), `editing`, `sheet`, `toast` (`{seq, text}`), `bend` (firmware takes pitch bend),
  `add_menu` (the open "Add here" menu, see `add_menu_json/1`), `draft` (half-typed MIDI numbers etc.),
  `learning` (`{control, sub, gesture}` while "Learn from MIDI" waits for a hardware control, else nil).

  MIDI learn: the binding sheet's "Learn from MIDI" arms `FMutate.MIDI.learn/2`; the screen hands the result
  to `learned/2`, which stores the input on the control (`FMutate.LayoutEdit.set_midi_in/4`, taking it from
  any other control). Closing the sheet or leaving edit mode stops learning.

  Events from the surface (`{:instrument, event, payload}`, coordinates in cells of the layout's grid):

      edit                         enter edit mode (long-press on empty space; menu → Edit layout)
      edit_done                    leave it
      page {id}                    the surface switched page
      pages                        long-press on the creature: page grid
      edit_move {id, col, row}
      edit_resize {id, col, row, w, h}
      edit_to_page {id, dir}       dragged onto a side edge (dir -1 / 1)
      edit_cell {page, col, row}   tap on an empty cell: open "Add here" for it
      edit_add_close               the "Add here" menu was dismissed
      edit_add {type, page, col, row}
      edit_add_page
      edit_open {id, sub, len}     tap on a selected control: its sheet (len: keyboard length in dp)
      use_classic                  the layout doesn't fit this phone: show the classic one
  """

  import Mob.Sigil, only: [sigil_MOB: 2]

  alias FMutate.{Firmware, Inputs, LayoutEdit, Layouts, MIDI, Motion, Style}
  alias FMutate.MIDI.Learn

  @events ~w(edit edit_done page pages edit_move edit_resize edit_to_page edit_cell edit_add_close edit_add
             edit_add_page edit_open use_classic)

  @doc "The surface events this module handles."
  def events, do: @events

  @doc "Assign the current layout of `firmware` (on mount, and whenever the firmware changes)."
  def load(socket, instance, firmware) do
    layout = Layouts.current(instance, firmware)

    Mob.Socket.assign(socket,
      instance: instance,
      firmware: firmware,
      layout: layout,
      layout_json: Layouts.encode(layout),
      page: hd(layout["pages"])["id"],
      sheet: nil,
      learning: nil,
      bend: cap?(firmware, :pitch_bend),
      toast: Map.get(socket.assigns, :toast, {0, ""}),
      add_menu: nil,
      # the phone's sensors (FMutate.Motion.sensors/0), asked once, when "Add here" or a motion sheet needs them
      sensors: Map.get(socket.assigns, :sensors),
      draft: %{midi_type: "note", channel: 1, number: 60, tab: :firmware, on: nil, jump: false}
    )
  end

  @doc "The firmware may have changed: switching firmware switches layout (HANDOFF §5)."
  def firmware(socket, firmware) do
    if socket.assigns[:firmware] == firmware,
      do: socket,
      else: socket |> load(socket.assigns.instance, firmware) |> Mob.Socket.assign(:editing, false)
  end

  @doc """
  The current layout was saved by another process (I/O cleared learned MIDI controls): take it, unless it
  is for another firmware or the same as the one shown.
  """
  def saved_elsewhere(socket, firmware, layout) do
    if firmware != socket.assigns.firmware or layout == socket.assigns.layout,
      do: socket,
      else: Mob.Socket.assign(socket, layout: layout, layout_json: Layouts.encode(layout))
  end

  @doc "What `FMutate.MIDI.learn/2` heard: `{:ok, midi_in}` (stored on the control being learned) or `:timeout`."
  def learned(socket, result) do
    case {socket.assigns[:learning], result} do
      {nil, _} ->
        socket

      {{id, sub, _on}, {:ok, midi_in}} ->
        holders = LayoutEdit.midi_holders(socket.assigns.layout, id, sub, midi_in)
        socket = socket |> Mob.Socket.assign(:learning, nil) |> commit(LayoutEdit.set_midi_in(socket.assigns.layout, id, sub, midi_in))

        case holders do
          [] -> socket
          list -> toast(socket, "Taken from " <> Enum.map_join(list, ", ", fn {c, s, _} -> holder_name(c, s) end))
        end

      {_, :timeout} ->
        socket |> Mob.Socket.assign(:learning, nil) |> toast("No MIDI heard · learning stopped")
    end
  end

  defp holder_name(%{"type" => "pad_grid"} = c, sub), do: control_title(c, sub)
  defp holder_name(c, _sub), do: control_title(c, nil)

  # closing a sheet, leaving edit mode, another control's sheet: learning stops
  defp stop_learning(socket) do
    if socket.assigns[:learning], do: MIDI.cancel_learn(socket.assigns.instance)
    Mob.Socket.assign(socket, :learning, nil)
  end

  ## Surface events

  @doc "Handle a surface event (see the module doc)."
  def event("edit", _p, socket), do: Mob.Socket.assign(socket, editing: true)
  def event("edit_done", _p, socket), do: socket |> stop_learning() |> Mob.Socket.assign(editing: false, sheet: nil, add_menu: nil)

  def event("edit_cell", %{"page" => page, "col" => col, "row" => row}, socket) do
    layout = socket.assigns.layout
    {w, h} = LayoutEdit.room(layout, page, col, row)
    socket = with_sensors(socket)

    menu =
      if w > 0 do
        items = LayoutEdit.add_menu(layout, page, col, row) |> Enum.map(&motion_item(&1, socket.assigns.sensors))
        %{page: page, col: col, row: row, room: [w, h], items: items}
      end

    Mob.Socket.assign(socket, :add_menu, menu)
  end

  def event("edit_add_close", _p, socket), do: Mob.Socket.assign(socket, :add_menu, nil)
  def event("page", %{"id" => id}, socket), do: Mob.Socket.assign(socket, :page, id)
  def event("pages", _p, socket), do: Mob.Socket.assign(socket, :sheet, :pages)

  def event("use_classic", _p, socket) do
    layout = Layouts.classic() |> Map.put("firmware", %{"id" => socket.assigns.firmware})
    Mob.Socket.assign(socket, layout: layout, layout_json: Layouts.encode(layout), page: hd(layout["pages"])["id"])
  end

  def event("edit_move", %{"id" => id, "col" => col, "row" => row}, socket),
    do: commit(socket, LayoutEdit.move(socket.assigns.layout, id, col, row))

  def event("edit_resize", %{"id" => id} = p, socket),
    do: commit(socket, LayoutEdit.resize(socket.assigns.layout, id, Map.take(p, ~w(col row w h))))

  def event("edit_to_page", %{"id" => id, "dir" => dir}, socket) do
    case LayoutEdit.to_page(socket.assigns.layout, id, dir) do
      {:ok, layout, page} -> socket |> commit({:ok, layout}) |> Mob.Socket.assign(:page, page)
      error -> commit(socket, error)
    end
  end

  def event("edit_add", %{"type" => type, "page" => page, "col" => col, "row" => row}, socket) do
    case LayoutEdit.add(socket.assigns.layout, page, type, col, row) do
      {:ok, layout, _id} -> socket |> commit({:ok, layout}) |> Mob.Socket.assign(:add_menu, nil)
      error -> commit(socket, error)
    end
  end

  def event("edit_add_page", _p, socket) do
    {:ok, layout, page} = LayoutEdit.add_page(socket.assigns.layout)
    socket |> commit({:ok, layout}) |> Mob.Socket.assign(:page, page)
  end

  def event("edit_open", %{"id" => id} = p, socket) do
    case LayoutEdit.find(socket.assigns.layout, id) do
      {_, c} ->
        sub = if c["type"] == "pad_grid", do: p["sub"] || 0
        len = p["len"] || 0
        draft = %{socket.assigns.draft | tab: :firmware, on: LayoutEdit.default_on(c)}
        socket = if c["type"] == "motion", do: with_sensors(socket), else: socket
        Mob.Socket.assign(stop_learning(socket), sheet: {:control, id, sub, len}, draft: draft)

      nil ->
        socket
    end
  end

  def event(_event, _payload, socket), do: socket

  # a phone without an accelerometer can't tilt or shake: the motion control is listed, greyed, with why
  defp motion_item(%{type: "motion"} = item, sensors) do
    if Motion.addable?(sensors), do: item, else: Map.merge(item, %{fits: false, reason: "no motion sensor"})
  end

  defp motion_item(item, _sensors), do: item

  defp with_sensors(socket) do
    if socket.assigns[:sensors], do: socket, else: Mob.Socket.assign(socket, :sensors, Motion.sensors())
  end

  # apply an edit: save it, or say why not
  defp commit(socket, {:ok, layout}) do
    case Layouts.save(socket.assigns.instance, socket.assigns.firmware, layout) do
      :ok ->
        page = if Enum.any?(layout["pages"], &(&1["id"] == socket.assigns.page)), do: socket.assigns.page, else: hd(layout["pages"])["id"]
        Mob.Socket.assign(socket, layout: layout, layout_json: Layouts.encode(layout), page: page)

      {:error, [msg | _]} ->
        toast(socket, "Not saved: " <> msg)
    end
  end

  defp commit(socket, {:error, msg}), do: toast(socket, msg)

  defp toast(socket, text) do
    {seq, _} = socket.assigns.toast
    Mob.Socket.assign(socket, :toast, {seq + 1, text})
  end

  ## Sheet events: {:tap | :dismiss, {:editor, action}} and {:change | :submit, {:editor, action}, value}

  @doc "Handle a sheet event."
  def ui(:dismiss, _tag, _value, socket), do: socket |> stop_learning() |> Mob.Socket.assign(:sheet, nil)
  def ui(_kind, {:editor, :close}, _value, socket), do: socket |> stop_learning() |> Mob.Socket.assign(:sheet, nil)

  def ui(:tap, {:editor, {:go, page}}, _v, socket), do: Mob.Socket.assign(socket, page: page, sheet: nil)
  def ui(:tap, {:editor, :sheet_pages}, _v, socket), do: Mob.Socket.assign(socket, :sheet, :pages)
  def ui(:tap, {:editor, :settings}, _v, socket), do: Mob.Socket.assign(socket, :sheet, :settings)
  def ui(:tap, {:editor, {:presets, mode}}, _v, socket), do: Mob.Socket.assign(socket, :sheet, {:presets, mode})

  def ui(:tap, {:editor, :new_page}, _v, socket) do
    {:ok, layout, page} = LayoutEdit.add_page(socket.assigns.layout)
    socket |> commit({:ok, layout}) |> Mob.Socket.assign(page: page, sheet: nil)
  end

  def ui(:tap, {:editor, {:preset_page, id}}, _v, socket) do
    case Layouts.preset(id) do
      nil ->
        socket

      p ->
        {:ok, layout, page, dropped} = LayoutEdit.add_page_from_preset(socket.assigns.layout, p.data)
        socket = socket |> commit({:ok, layout}) |> Mob.Socket.assign(page: page, sheet: nil)
        if dropped > 0, do: toast(socket, "#{dropped} control(s) didn't fit and were left out"), else: socket
    end
  end

  def ui(:tap, {:editor, {:preset_layout, id}}, _v, socket) do
    case Layouts.from_preset(id, socket.assigns.firmware) do
      nil -> socket
      layout -> socket |> commit({:ok, layout}) |> Mob.Socket.assign(page: hd(layout["pages"])["id"], sheet: nil)
    end
  end

  def ui(:tap, {:editor, :reset_classic}, _v, socket) do
    layout = Layouts.reset(socket.assigns.instance, socket.assigns.firmware)

    socket
    |> Mob.Socket.assign(layout: layout, layout_json: Layouts.encode(layout), page: hd(layout["pages"])["id"], sheet: nil)
    |> toast("Back to the classic layout")
  end

  def ui(kind, {:editor, :layout_name}, name, socket) when kind in [:change, :submit] and is_binary(name),
    do: commit(socket, LayoutEdit.rename(socket.assigns.layout, name))

  def ui(kind, {:editor, :page_name}, name, socket) when kind in [:change, :submit] and is_binary(name),
    do: commit(socket, LayoutEdit.rename_page(socket.assigns.layout, socket.assigns.page, name))

  def ui(:tap, {:editor, {:frame, frame}}, _v, socket),
    do: commit(socket, LayoutEdit.set_frame(socket.assigns.layout, frame))

  def ui(:tap, {:editor, {:switcher, look}}, _v, socket),
    do: commit(socket, LayoutEdit.set_switcher(socket.assigns.layout, look))

  def ui(:tap, {:editor, {:move_page, dir}}, _v, socket),
    do: commit(socket, LayoutEdit.move_page(socket.assigns.layout, socket.assigns.page, dir))

  def ui(:tap, {:editor, :delete_page}, _v, socket),
    do: commit(socket, LayoutEdit.delete_page(socket.assigns.layout, socket.assigns.page))

  # control sheet
  def ui(:tap, {:editor, {:tab, tab}}, _v, socket), do: draft(socket, tab: tab)
  def ui(:tap, {:editor, {:on, on}}, _v, socket), do: draft(socket, on: on)
  def ui(:tap, {:editor, {:midi_type, t}}, _v, socket), do: draft(socket, midi_type: t)
  def ui(:tap, {:editor, {:channel, d}}, _v, socket), do: draft(socket, channel: clamp(socket.assigns.draft.channel + d, 1, 16))
  def ui(:tap, {:editor, {:number, d}}, _v, socket), do: draft(socket, number: clamp(socket.assigns.draft.number + d, 0, 127))
  def ui(:change, {:editor, :jump}, v, socket), do: draft(socket, jump: v == true)

  def ui(:tap, {:editor, {:toggle_target, to}}, _v, socket), do: with_control(socket, &toggle_target(&1, &2, &3, to))
  def ui(:tap, {:editor, {:remove_binding, i}}, _v, socket), do: with_control(socket, &remove_binding(&1, &2, &3, i))
  def ui(:tap, {:editor, :bind_midi}, _v, socket), do: with_control(socket, &bind_midi/3)
  def ui(:tap, {:editor, {:mode, mode}}, _v, socket), do: with_control(socket, &set_mode(&1, &2, &3, mode))

  # MIDI learn: the gesture the sheet shows (press, value, x or y)
  def ui(:tap, {:editor, {:learn, on}}, _v, socket) do
    {:control, id, sub, _} = socket.assigns.sheet

    case MIDI.learn(socket.assigns.instance, on) do
      :ok -> Mob.Socket.assign(socket, :learning, {id, sub, on})
      _ -> toast(socket, "MIDI isn't ready")
    end
  end

  def ui(:tap, {:editor, :learn_cancel}, _v, socket), do: stop_learning(socket)

  def ui(:tap, {:editor, {:learn_clear, on}}, _v, socket),
    do: with_control(socket, fn l, c, sub -> LayoutEdit.clear_midi_in(l, c["id"], sub, on) end)

  def ui(:tap, {:editor, {:learn_any, on}}, _v, socket),
    do: with_midi_in(socket, on, &Map.delete(&1, "device"))

  def ui(:tap, {:editor, {:learn_mode, on, mode}}, _v, socket),
    do: with_midi_in(socket, on, &if(mode == "absolute", do: Map.delete(&1, "mode"), else: Map.put(&1, "mode", mode)))

  def ui(kind, {:editor, :label}, text, socket) when kind in [:change, :submit] and is_binary(text) do
    with_control(socket, fn layout, c, sub ->
      text = String.slice(text, 0, if(sub, do: 8, else: 16))

      if sub do
        pads = get_in(c, ["pad_grid", "pads"]) |> List.update_at(sub, &Map.put(&1, "label", text))
        LayoutEdit.put(layout, c["id"], %{"pad_grid" => Map.put(c["pad_grid"], "pads", pads)})
      else
        LayoutEdit.put(layout, c["id"], %{"label" => text})
      end
    end)
  end

  def ui(:tap, {:editor, :delete_control}, _v, socket) do
    {:control, id, _, _} = socket.assigns.sheet

    case LayoutEdit.delete(socket.assigns.layout, id) do
      {:ok, _} = ok -> socket |> commit(ok) |> Mob.Socket.assign(:sheet, nil)
      error -> commit(socket, error)
    end
  end

  # keyboard strip
  def ui(:tap, {:editor, {:kb_range, octaves}}, _v, socket),
    do: with_control(socket, fn l, c, _ -> put_kb(l, c, range(c, octaves)) end)

  def ui(:tap, {:editor, {:kb_from, d}}, _v, socket),
    do: with_control(socket, fn l, c, _ -> put_kb(l, c, custom(c, :from, d)) end)

  def ui(:tap, {:editor, {:kb_to, d}}, _v, socket),
    do: with_control(socket, fn l, c, _ -> put_kb(l, c, custom(c, :to, d)) end)

  def ui(:change, {:editor, :kb_arrows}, v, socket),
    do: with_control(socket, fn l, c, _ -> put_kb(l, c, %{"octave_arrows" => v == true}) end)

  def ui(:change, {:editor, :kb_wobble}, v, socket),
    do: with_control(socket, fn l, c, _ -> put_kb(l, c, %{"glide" => if(v == true, do: "wobble", else: "glissando")}) end)

  def ui(:tap, {:editor, {:kb_bend, n}}, _v, socket),
    do: with_control(socket, fn l, c, _ -> put_kb(l, c, %{"bend_range" => n}) end)

  # velocity: "fixed" (firmware key presses) or "position" (MIDI notes, velocity from where the key is struck)
  def ui(:tap, {:editor, {:kb_velocity, source}}, _v, socket),
    do: with_control(socket, fn l, c, _ -> put_kb(l, c, %{"velocity" => Map.put(velocity(c), "source", source)}) end)

  def ui(:tap, {:editor, {:kb_vel_min, n}}, _v, socket),
    do: with_control(socket, fn l, c, _ -> put_kb(l, c, %{"velocity" => Map.put(velocity(c), "min", n)}) end)

  def ui(:change, {:editor, :kb_swell}, v, socket),
    do: with_control(socket, fn l, c, _ -> put_kb(l, c, %{"velocity" => Map.put(velocity(c), "swell", v == true)}) end)

  def ui(:change, {:editor, :kb_pressure}, v, socket),
    do: with_control(socket, fn l, c, _ -> put_kb(l, c, %{"velocity" => Map.put(velocity(c), "pressure", v == true)}) end)

  def ui(:change, {:editor, :kb_colors}, v, socket),
    do: with_control(socket, fn l, c, _ -> put_kb(l, c, %{"pitch_colors" => v == true}) end)

  def ui(:change, {:editor, :kb_vertical}, v, socket),
    do: with_control(socket, fn l, c, _ -> put_kb(l, c, %{"orientation" => if(v == true, do: "vertical", else: "horizontal")}) end)

  # other control settings
  # 0: fill the cells (no `scale`); 1..4: pixel-exact, up to that multiple
  def ui(:tap, {:editor, {:screen_scale, 0}}, _v, socket),
    do: with_control(socket, fn l, c, _ -> LayoutEdit.put(l, c["id"], %{"screen" => %{}}) end)

  def ui(:tap, {:editor, {:screen_scale, n}}, _v, socket),
    do: with_control(socket, fn l, c, _ -> LayoutEdit.put(l, c["id"], %{"screen" => %{"scale" => n}}) end)

  def ui(:tap, {:editor, {:switcher_look, look}}, _v, socket),
    do: with_control(socket, fn l, c, _ -> LayoutEdit.put(l, c["id"], %{"page_switcher" => %{"look" => look}}) end)

  def ui(:tap, {:editor, {:slider_orientation, o}}, _v, socket),
    do: with_control(socket, fn l, c, _ -> LayoutEdit.put(l, c["id"], %{"slider" => %{"orientation" => o}}) end)

  def ui(:tap, {:editor, {:strum_key, k}}, _v, socket) do
    with_control(socket, fn l, c, _ ->
      keys = get_in(c, ["strum", "keys"]) || []
      keys = if k in keys, do: List.delete(keys, k), else: Enum.sort([k | keys])
      LayoutEdit.put(l, c["id"], %{"strum" => %{"keys" => keys}})
    end)
  end

  # motion controls: engage, range, on_release, shake (FMutate.Motion.choices/1)
  def ui(:tap, {:editor, {:motion, key, value}}, _v, socket) do
    with_control(socket, fn l, c, _ ->
      case Motion.put_setting(c, key, value) do
        {:ok, m} -> LayoutEdit.put(l, c["id"], %{"motion" => m})
        :error -> {:error, "Not a choice for that setting"}
      end
    end)
  end

  def ui(_kind, _tag, _value, socket), do: socket

  defp draft(socket, kv), do: Mob.Socket.assign(socket, :draft, Map.merge(socket.assigns.draft, Map.new(kv)))

  defp with_control(socket, fun) do
    with {:control, id, sub, _len} <- socket.assigns.sheet,
         {_, c} <- LayoutEdit.find(socket.assigns.layout, id) do
      commit(socket, fun.(socket.assigns.layout, c, sub))
    else
      _ -> socket
    end
  end

  # change the learned input of gesture `on` of the sheet's control
  defp with_midi_in(socket, on, fun) do
    with_control(socket, fn l, c, sub ->
      case Enum.find(LayoutEdit.midi_in(l, c["id"], sub), &(&1["on"] == on)) do
        nil -> {:error, "Nothing learned"}
        m -> LayoutEdit.set_midi_in(l, c["id"], sub, fun.(m))
      end
    end)
  end

  defp current_on(socket, c), do: socket.assigns.draft.on || LayoutEdit.default_on(c)

  defp toggle_target(layout, c, sub, to) do
    on = current_draft_on(c)
    bindings = LayoutEdit.bindings(layout, c["id"], sub)

    bindings =
      if Enum.any?(bindings, &(&1["to"] == to and on_of(&1) == on)),
        do: Enum.reject(bindings, &(&1["to"] == to and on_of(&1) == on)),
        else: bindings ++ [binding(on, to)]

    LayoutEdit.set_bindings(layout, c["id"], sub, bindings)
  end

  # the gesture chosen in the open sheet (stashed by ui/4 before calling in)
  defp current_draft_on(c), do: Process.get({__MODULE__, :on}) || LayoutEdit.default_on(c)

  defp binding("press", to), do: %{"to" => to}
  defp binding(on, to), do: %{"on" => on, "to" => to}

  defp on_of(b), do: b["on"] || "press"

  defp remove_binding(layout, c, sub, i),
    do: LayoutEdit.set_bindings(layout, c["id"], sub, List.delete_at(LayoutEdit.bindings(layout, c["id"], sub), i))

  defp bind_midi(layout, c, sub) do
    d = Process.get({__MODULE__, :draft})
    type = midi_type(kind(c, current_draft_on(c)), c, d)
    midi = if type == "pitch_bend", do: %{"type" => type, "channel" => d.channel}, else: %{"type" => type, "channel" => d.channel, "number" => d.number}
    midi = if type == "cc" and c["type"] == "slider" and d.jump, do: Map.put(midi, "jump", true), else: midi
    toggle_target(layout, c, sub, %{"midi" => midi})
  end

  # Momentary / Toggle: the press bindings, or for a motion control those of the gesture shown (shake, near)
  defp set_mode(layout, c, sub, mode) do
    press_on = if c["type"] == "motion", do: current_draft_on(c), else: "press"

    bindings =
      for b <- LayoutEdit.bindings(layout, c["id"], sub) do
        if on_of(b) == press_on, do: (if mode == "toggle", do: Map.put(b, "mode", "toggle"), else: Map.delete(b, "mode")), else: b
      end

    LayoutEdit.set_bindings(layout, c["id"], sub, bindings)
  end

  defp put_kb(layout, c, fields), do: LayoutEdit.put(layout, c["id"], %{"keyboard" => Map.merge(c["keyboard"] || %{}, fields)})

  defp kb_range(c), do: {get_in(c, ["keyboard", "from_key"]) || 0, get_in(c, ["keyboard", "to_key"]) || 26}
  defp velocity(c), do: get_in(c, ["keyboard", "velocity"]) || %{}

  # all of the FM-1's 27 keys (F to G: 2¼ octaves, so a third octave can't exist)
  defp range(_c, :all), do: %{"from_key" => 0, "to_key" => 26}

  # an octave range starting where the strip starts now, shifted down if it would run past key 26
  defp range(c, octaves) do
    {from, _} = kb_range(c)
    n = 12 * octaves
    from = min(from, 26 - n)
    %{"from_key" => from, "to_key" => from + n}
  end

  defp custom(c, which, d) do
    {from, to} = kb_range(c)

    case which do
      :from -> %{"from_key" => clamp(from + d, 0, to - 4)}
      :to -> %{"to_key" => clamp(to + d, from + 4, 26)}
    end
  end

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  @doc false
  # ui/4 entry from the screen: make the sheet's draft visible to the binding helpers above
  def dispatch(kind, tag, value, socket) do
    Process.put({__MODULE__, :draft}, socket.assigns.draft)

    case socket.assigns[:sheet] do
      {:control, id, _, _} ->
        case LayoutEdit.find(socket.assigns.layout, id) do
          {_, c} -> Process.put({__MODULE__, :on}, current_on(socket, c))
          nil -> :ok
        end

      _ ->
        :ok
    end

    ui(kind, tag, value, socket)
  after
    Process.delete({__MODULE__, :on})
    Process.delete({__MODULE__, :draft})
  end

  ## Rendering

  @doc "The open \"Add here\" menu as JSON text for the surface (`\"\"` when closed)."
  def add_menu_json(assigns) do
    case assigns[:add_menu] do
      nil -> ""
      menu -> JSON.encode!(menu)
    end
  end

  @doc "The sheet to draw over the instrument, as a list of nodes (empty when none is open)."
  def sheets(assigns) do
    case assigns[:sheet] do
      nil -> []
      :pages -> [pages_sheet(assigns)]
      :settings -> [settings_sheet(assigns)]
      {:presets, mode} -> [presets_sheet(assigns, mode)]
      {:control, id, sub, len} -> control_sheet(assigns, id, sub, len)
    end
  end

  # Mob takes raw colours as 0xAARRGGBB integers (FMutate.Style has "#RRGGBB")
  defp c(name) do
    "#" <> hex = Style.color(name)
    0xFF000000 + String.to_integer(hex, 16)
  end

  defp sheet(id, children) do
    dismiss = {self(), {:editor, :close}}

    ~MOB"""
    <Sheet id={id} detents={[:large]} on_dismiss={dismiss} background={c(:surface)}>
      <Scroll>
        <Column padding={16} gap={12} background={c(:surface)}>
          {children}
        </Column>
      </Scroll>
    </Sheet>
    """
  end

  defp title(text, aside \\ "") do
    ~MOB"""
    <Row gap={8}>
      <Text text={text} text_size={22} font_weight="bold" text_color={c(:text)} weight={1} />
      <Text text={aside} text_size={11} text_color={c(:muted)} />
    </Row>
    """
  end

  defp section(text), do: text(String.upcase(text), 11, :muted, true)
  defp caption(text, color \\ :muted), do: text(text, 12, color, false)

  defp text(text, size, color, bold) do
    weight = if bold, do: "bold", else: "regular"
    color = c(color)

    ~MOB"""
    <Text text={text} text_size={size} font_weight={weight} text_color={color} />
    """
  end

  defp wrap(children, spacing) do
    ~MOB"""
    <Wrap spacing={spacing} run_spacing={spacing} fill_width={true}>
      {children}
    </Wrap>
    """
  end

  defp text_field(value, action, max) do
    change = {self(), {:editor, action}}
    fg = c(:text)
    bg = c(:raised)

    ~MOB"""
    <TextField value={value} on_change={change} max_length={max} text_color={fg} background={bg} />
    """
  end

  # `weight:` shares a row (default 1); `weight: :none` for a button stacked in a column, where a weight would
  # take the scroll's unbounded height
  defp button(text, action, opts) do
    tap = {self(), {:editor, action}}
    {bg, fg} = if opts[:on], do: {c(:selected), c(:fm)}, else: {opts[:bg] || c(:raised), opts[:fg] || c(:text)}
    disabled = opts[:disabled] == true
    fg = if disabled and !opts[:on], do: c(:faint), else: fg

    props = %{
      text: text,
      on_tap: tap,
      background: bg,
      text_color: fg,
      text_size: 13,
      disabled: disabled,
      fill_width: Keyword.get(opts, :fill, true),
      padding: 8
    }

    props = if opts[:weight] == :none, do: props, else: Map.put(props, :weight, opts[:weight] || 1)
    %{type: :button, props: props, children: []}
  end

  # a segmented control: equal buttons, the current one selected; values in `disabled` are greyed out
  defp segmented(options, current, disabled \\ []) do
    buttons = for {label, action, value} <- options, do: button(label, action, on: value == current, disabled: value in disabled)

    ~MOB"""
    <Row gap={4} padding={4} background={c(:bg)}>
      {buttons}
    </Row>
    """
  end

  defp chip(text, action, opts \\ []) do
    tap = {self(), {:editor, action}}
    bg = if opts[:on], do: c(:fm), else: c(:raised_hi)
    fg = if opts[:on], do: c(:ink), else: c(:text)

    ~MOB"""
    <Button text={text} on_tap={tap} background={bg} text_color={fg} text_size={12} fill_width={false} padding={6} />
    """
  end

  defp toggle(label, hint, action, value, opts \\ []) do
    change = {self(), {:editor, action}}
    disabled = opts[:disabled] == true

    ~MOB"""
    <Column gap={2}>
      <Toggle label={label} value={value} on_change={change} color={c(:fm)} disabled={disabled} />
      <Text text={hint} text_size={12} text_color={c(if disabled, do: :faint, else: :muted)} />
    </Column>
    """
  end

  defp stepper(label, value, minus, plus) do
    ~MOB"""
    <Row gap={4} background={c(:raised)} padding={4} weight={1}>
      <Text text={label} text_size={13} text_color={c(:muted)} />
      {button("−", minus, fill: false, weight: 1)}
      <Text text={value} text_size={14} font_weight="bold" text_color={c(:text)} />
      {button("+", plus, fill: false, weight: 1)}
    </Row>
    """
  end

  ## Page grid (Pages.dc.html, middle column)

  defp pages_sheet(assigns) do
    layout = assigns.layout
    n = length(layout["pages"])
    thumbs = for p <- layout["pages"], do: thumb(layout, p, p["id"] == assigns.page)
    new_page = {self(), {:editor, :new_page}}

    children = [
      title("#{layout["name"]} · #{n} page#{if n == 1, do: "", else: "s"}"),
      ~MOB"""
      <Wrap spacing={12} run_spacing={12} fill_width={true}>
        {thumbs}
        <Column gap={6} fill_width={false}>
          <Button text="+" on_tap={new_page} background={c(:bg_deep)} text_color={c(:text_2)} text_size={24} fill_width={false} padding={30} />
          <Text text="New page" text_size={12} text_color={c(:muted)} />
        </Column>
      </Wrap>
      """,
      ~MOB"""
      <Row gap={8}>
        {button("From a preset…", {:presets, :page}, bg: c(:raised_hi))}
        {button("Layout settings", :settings, bg: c(:raised_hi))}
        {button("Close", :close, bg: c(:raised_hi))}
      </Row>
      """
    ]

    sheet("pages", children)
  end

  # a page thumbnail: its controls as blocks (dock included), the current page ringed lime
  defp thumb(layout, page, current) do
    %{"cols" => cols, "rows" => rows} = layout["grid"]
    {tw, th} = if layout["frame"] == "portrait", do: {84, 160}, else: {160, 84}
    cw = (tw - 8) / cols
    ch = (th - 8) / rows
    tap = {self(), {:editor, {:go, page["id"]}}}

    blocks =
      for c <- LayoutEdit.controls(layout, page["id"]) do
        at = c["at"]

        Mob.Canvas.rect(4 + at["col"] * cw + 1, 4 + at["row"] * ch + 1, at["w"] * cw - 2, at["h"] * ch - 2,
          color: block_color(c["type"]), fill: true, radius: 3)
      end

    ring = if current, do: c(:fm), else: c(:line_soft)
    ops = [Mob.Canvas.rect(0, 0, tw, th, color: c(:bg_deep), fill: true, radius: 10) | blocks] ++
      [Mob.Canvas.rect(1, 1, tw - 2, th - 2, color: ring, width: if(current, do: 3, else: 1), radius: 10)]

    ~MOB"""
    <Column gap={6} fill_width={false}>
      <Canvas width={tw} height={th} draw={ops} on_tap={tap} />
      <Text text={page["name"]} text_size={12} font_weight="bold" text_color={c(if current, do: :text, else: :text_2)} />
    </Column>
    """
  end

  defp block_color("screen"), do: "#000000"
  defp block_color(t) when t in ["keyboard", "key"], do: c(:key_white)
  defp block_color(t) when t in ["slider", "xy_pad", "pad_grid", "strum"], do: c(:slider_fill)
  defp block_color("menu"), do: c(:fm)
  defp block_color(_), do: c(:line_soft)

  ## Layout settings (Pages.dc.html, right column)

  defp settings_sheet(assigns) do
    layout = assigns.layout
    page = LayoutEdit.page(layout, assigns.page)
    fw = firmware_name(assigns.firmware)

    children = [
      title("Layout settings", "for #{fw}"),
      section("Name"),
      text_field(layout["name"], :layout_name, 40),
      section("Frame"),
      segmented([{"Portrait", {:frame, "portrait"}, "portrait"}, {"Landscape", {:frame, "landscape"}, "landscape"}], layout["frame"]),
      caption("Turning a layout mirrors it over the diagonal: a bottom keyboard becomes a side keyboard."),
      section("Switcher look"),
      segmented(
        [{"Names", {:switcher, "names"}, "names"}, {"Dots", {:switcher, "dots"}, "dots"}, {"Hidden", {:switcher, "hidden"}, "hidden"}],
        layout["switcher"] || "names"
      ),
      caption("Long-press the creature for the page grid, so a hidden switcher never traps you."),
      section("This page"),
      text_field(page["name"], :page_name, 12),
      ~MOB"""
      <Row gap={8}>
        {button("‹ Move earlier", {:move_page, -1}, bg: c(:raised_hi))}
        {button("Move later ›", {:move_page, 1}, bg: c(:raised_hi))}
        {button("Delete page", :delete_page, bg: c(:danger_bg), fg: c(:danger_text), disabled: length(layout["pages"]) <= 1)}
      </Row>
      """,
      section("Start again"),
      ~MOB"""
      <Row gap={8}>
        {button("New layout from a preset…", {:presets, :layout}, bg: c(:raised_hi))}
        {button("Reset to classic", :reset_classic, bg: c(:raised_hi))}
        {button("Pages", :sheet_pages, bg: c(:raised_hi))}
      </Row>
      """
    ]

    sheet("settings", children)
  end

  ## Presets

  defp presets_sheet(assigns, mode) do
    {heading, action} =
      case mode do
        :page -> {"New page from a preset", :preset_page}
        :layout -> {"New layout from a preset", :preset_layout}
      end

    rows =
      for p <- Layouts.presets() do
        made_for = if p.firmware == "any", do: "any firmware", else: firmware_name(p.firmware)
        mine = p.firmware in ["any", assigns.firmware]
        label = "#{p.name} · for #{made_for} · #{p.frame}"
        button(label, {action, p.id}, bg: if(mine, do: c(:raised_hi), else: c(:raised)), weight: :none)
      end

    hint =
      case mode do
        :page -> "Copies the preset's first page (and its dock) into this layout. Bindings come along as they are."
        :layout -> "Replaces this layout. Presets made for another firmware keep their bindings; check them."
      end

    sheet("presets-#{mode}", [title(heading), caption(hint) | rows] ++ [button("Close", :close, bg: c(:raised_hi), weight: :none)])
  end

  ## Control sheet: bindings (Editor.dc.html sheet), keyboard strip (Editor-Keys.dc.html)

  defp control_sheet(assigns, id, sub, len) do
    case LayoutEdit.find(assigns.layout, id) do
      nil -> []
      {_, %{"type" => "keyboard"} = c} -> [keyboard_sheet(assigns, c, len)]
      {_, c} -> [binding_sheet(assigns, c, sub)]
    end
  end

  defp control_title(%{"type" => "pad_grid"} = c, sub) do
    pad = get_in(c, ["pad_grid", "pads"]) |> Enum.at(sub || 0, %{})
    "Pad · #{pad["label"] || sub}"
  end

  defp control_title(c, _sub) do
    name = LayoutEdit.type_name(c["type"])
    if (c["label"] || "") == "", do: name, else: "#{name} · #{c["label"]}"
  end

  defp binding_sheet(assigns, c, sub) do
    layout = assigns.layout
    d = assigns.draft
    on = d.on || LayoutEdit.default_on(c)
    bindings = LayoutEdit.bindings(layout, c["id"], sub)
    kind = kind(c, on)

    label =
      if sub,
        do: get_in(c, ["pad_grid", "pads"]) |> Enum.at(sub, %{}) |> Map.get("label", ""),
        else: c["label"] || ""

    body =
      case kind do
        :none -> other_settings(c)
        :strum -> strum_settings(c)
        _ -> binding_editor(assigns, c, kind, on, bindings, d) ++ midi_in_section(assigns, c, sub, kind, on) ++ motion_settings(assigns, c)
      end

    children =
      [title(control_title(c, sub), if(kind in [:press, :value, :xy], do: "drives", else: ""))] ++
        body ++
        if c["type"] in ["menu", "screen"] do
          []
        else
          [section("Label"), text_field(label, :label, if(sub, do: 8, else: 16))]
        end ++
        [
          ~MOB"""
          <Row gap={8}>
            {button("Delete control", :delete_control, bg: c(:danger_bg), fg: c(:danger_text), disabled: c["type"] == "menu")}
            {button("Done", :close, bg: c(:fm), fg: c(:ink))}
          </Row>
          """
        ] ++
        if(c["type"] == "menu", do: [caption("The creature can be moved, never deleted.")], else: [])

    sheet("control-#{c["id"]}-#{sub}", children)
  end

  ## MIDI in (MIDI learn): a hardware control drives this control's gesture

  defp midi_in_section(assigns, c, sub, kind, on) do
    gesture =
      case kind do
        :press -> "press"
        :value -> "value"
        :xy -> on
        _ -> nil
      end

    if gesture in LayoutEdit.gestures(c, sub) do
      current = Enum.find(LayoutEdit.midi_in(assigns.layout, c["id"], sub), &(&1["on"] == gesture))
      heading = if kind == :xy, do: "MIDI in · #{String.upcase(gesture)} axis", else: "MIDI in"
      [section(heading) | midi_in_body(assigns[:learning] == {c["id"], sub, gesture}, current, gesture)]
    else
      []
    end
  end

  defp midi_in_body(true, _current, _gesture) do
    [
      caption("Move a knob, fader, pad or key on your MIDI controller…", :fm),
      button("Cancel", :learn_cancel, bg: c(:raised_hi), weight: :none)
    ]
  end

  defp midi_in_body(false, nil, gesture) do
    [
      caption("A knob, fader, pad or key of a MIDI controller can drive this control: Learn, then move it."),
      button("Learn from MIDI", {:learn, gesture}, bg: c(:raised_hi), weight: :none)
    ]
  end

  defp midi_in_body(false, m, gesture) do
    any =
      if m["device"],
        do: [button("From any device", {:learn_any, gesture}, bg: c(:raised_hi), weight: :none)],
        else: [caption("From any device: Learn again to take it from one only.", :faint)]

    modes =
      if m["type"] == "cc" and gesture != "press" do
        current = m["mode"] || "absolute"

        [
          segmented(for({mode, name} <- Learn.modes(), do: {name, {:learn_mode, gesture, mode}, mode}), current),
          caption(
            "Absolute: a knob or fader (encoders get #{round(FMutate.MIDI.Controls.clicks_per_sweep(%{}))} clicks per sweep). " <>
              "The others are endless encoders' codings: 64 ± n, two's complement (1 up, 127 down), sign bit (1 up, 65 down).",
            :faint
          )
        ]
      else
        []
      end

    [
      ~MOB"""
      <Row gap={8}>
        {text("MIDI in: " <> Learn.describe(m), 13, :text, false)}
        {button("Clear", {:learn_clear, gesture}, bg: c(:raised_hi), weight: :none)}
      </Row>
      """
    ] ++ modes ++ any ++ [button("Learn again", {:learn, gesture}, bg: c(:raised_hi), weight: :none)]
  end

  # what a control's bindings drive: discrete presses, a value, two axes, or nothing
  defp kind(%{"type" => t}) when t in ["button", "key", "pad_grid", "label"], do: :press
  defp kind(%{"type" => t}) when t in ["knob", "slider"], do: :value
  defp kind(%{"type" => "xy_pad"}), do: :xy
  defp kind(%{"type" => "strum"}), do: :strum
  defp kind(_), do: :none

  # a motion control's bindings drive values (tilt, twist) or presses (shake, near), by the gesture shown
  defp kind(%{"type" => "motion"}, on), do: Motion.kind(on)
  defp kind(c, _on), do: kind(c)

  # the MIDI message a binding sends: presses a note or a CC, values a CC, motion axes a CC or pitch bend
  defp midi_type(:press, _c, d), do: if(d.midi_type in ["note", "cc"], do: d.midi_type, else: "note")
  defp midi_type(_value, %{"type" => "motion"}, %{midi_type: "pitch_bend"}), do: "pitch_bend"
  defp midi_type(_value, _c, _d), do: "cc"

  defp motion_gestures(assigns, on) do
    avail = Motion.availability(assigns.sensors || [])
    missing = for {g, {:missing, _}} <- avail, do: g
    options = for g <- Motion.gestures(), do: {Motion.name(g), {:on, g}, g}
    reasons = for g <- Motion.gestures(), {:missing, why} <- [avail[g]], do: "#{Motion.name(g)}: #{why}."
    [segmented(options, on, missing)] ++ if(reasons == [], do: [], else: [caption(Enum.join(reasons, " "), :faint)])
  end

  defp motion_settings(assigns, %{"type" => "motion"} = c) do
    avail = Motion.availability(assigns.sensors || [])
    accel = match?({:ok, _}, avail["x"])
    have = for({_g, {:ok, name}} <- avail, do: name) |> Enum.uniq()
    opt = fn key, label, value -> {label, {:motion, key, value}, value} end

    [
      section("Engage"),
      segmented([opt.("engage", "Hold", "hold"), opt.("engage", "Latch", "latch")], Motion.setting(c, "engage")),
      caption(
        "Hold: moves only while a finger is on the tile, from how the phone was held when the finger landed, so " <>
          "picking the phone up never moves anything. Latch: a tap turns it on (lime) from how the phone is held then; another tap, off."
      ),
      section("Range"),
      segmented(for(r <- Motion.choices("range"), do: opt.("range", "#{r}°", r)), Motion.setting(c, "range")),
      caption("Degrees of tilt (or twist) that sweep a value's whole range; pitch bend reaches either end in half of it."),
      section("On release"),
      segmented([opt.("on_release", "Stay", "stay"), opt.("on_release", "Spring back", "spring_back")], Motion.setting(c, "on_release")),
      caption("Spring back: when it lets go, values return to where they were when it engaged (encoders get their clicks back)."),
      section("Shake"),
      segmented(
        for(s <- Motion.choices("shake"), do: opt.("shake", String.capitalize(s), s)),
        Motion.setting(c, "shake"),
        if(accel, do: [], else: Motion.choices("shake"))
      ),
      caption("How hard a jolt counts as a shake: gentle 0.6 g, firm 1.2 g, hard 2 g beyond gravity."),
      caption(if(have == [], do: "This phone reports no motion sensors.", else: "This phone: " <> Enum.join(have, ", ") <> "."), :faint)
    ]
  end

  defp motion_settings(_assigns, _c), do: []

  defp binding_editor(assigns, c, kind, on, bindings, d) do
    gestures =
      cond do
        c["type"] == "motion" -> motion_gestures(assigns, on)
        kind == :press -> [segmented([{"On press", {:on, "press"}, "press"}, {"On long-press", {:on, "long_press"}, "long_press"}], on)]
        kind == :xy -> [segmented([{"X axis", {:on, "x"}, "x"}, {"Y axis", {:on, "y"}, "y"}], on)]
        true -> []
      end

    tabs =
      segmented(
        [{"Firmware input", {:tab, :firmware}, :firmware}, {"MIDI note / CC", {:tab, :midi}, :midi}] ++
          if(kind == :press, do: [{"Go to page", {:tab, :page}, :page}], else: []),
        d.tab
      )

    bound = MapSet.new(for b <- bindings, on_of(b) == on, do: b["to"])

    tab_body =
      case d.tab do
        :firmware -> firmware_inputs(kind, bound)
        :midi -> midi_inputs(assigns, kind, c, d)
        :page -> page_targets(assigns.layout, bound)
      end

    chips =
      for {b, i} <- Enum.with_index(bindings) do
        chip("#{describe(b["to"])} · #{gesture_name(c, on_of(b))}#{if b["mode"] == "toggle", do: " · toggle", else: ""}  ×", {:remove_binding, i})
      end

    chips_node =
      if chips == [],
        do: caption("Not bound yet: tap an input above."),
        else: wrap(chips, 8)

    shared =
      if kind == :value and Enum.any?(bindings, &absolute?(&1["to"])),
        do: [caption("Bound to a value another control may also drive: the last one moved wins, the other greys out and picks up the value on its next touch.")],
        else: []

    mode =
      if kind == :press do
        press_on = if c["type"] == "motion", do: on, else: "press"
        toggle_on = Enum.any?(bindings, &(on_of(&1) == press_on and &1["mode"] == "toggle"))
        [segmented([{"Momentary", {:mode, "momentary"}, false}, {"Toggle", {:mode, "toggle"}, true}], toggle_on)]
      else
        []
      end

    [tabs | gestures] ++ tab_body ++ [section("Drives"), chips_node] ++ shared ++ mode
  end

  defp absolute?(%{"pot" => _}), do: true
  defp absolute?(%{"midi" => %{"type" => "cc"}}), do: true
  defp absolute?(_), do: false

  # the FM-1's inputs, tap to bind or unbind; for value controls only what takes a value
  defp firmware_inputs(kind, bound) do
    press = kind == :press

    keys =
      for k <- 0..26 do
        to = %{"key" => k}
        chip(LayoutEdit.key_name(k), {:toggle_target, to}, on: to in bound)
      end

    encoders =
      for e <- Inputs.encoders() do
        to = %{"encoder" => Atom.to_string(e)}
        chip(encoder_name(e) <> if(press, do: " +1", else: ""), {:toggle_target, to}, on: to in bound)
      end

    pot = %{"pot" => "master"}

    buttons =
      for b <- Inputs.buttons() do
        to = %{"button" => Atom.to_string(b)}
        chip(button_name(b), {:toggle_target, to}, on: to in bound)
      end

    enc_section = [section("Encoders"), wrap(encoders, 6)]

    if press do
      [
        section("Keys"),
        wrap(keys, 4),
        section("Buttons"),
        wrap(buttons, 6)
      ] ++ enc_section ++ [caption("Tap to bind; tap again to unbind. Several bindings are sent together.")]
    else
      enc_section ++
        [
          section("Pot"),
          wrap([chip("MASTER", {:toggle_target, pot}, on: pot in bound)], 6),
          caption("Encoders get clicks for distance moved; the pot gets a value.")
        ]
    end
  end

  defp gesture_name(%{"type" => "motion"}, on), do: String.downcase(Motion.name(on))
  defp gesture_name(_c, on), do: String.replace(on, "_", "-")

  defp midi_inputs(assigns, kind, c, d) do
    motion_axis = c["type"] == "motion" and kind == :value

    types =
      cond do
        kind == :press -> [{"Note", {:midi_type, "note"}, "note"}, {"CC", {:midi_type, "cc"}, "cc"}]
        motion_axis -> [{"CC", {:midi_type, "cc"}, "cc"}, {"Pitch bend", {:midi_type, "pitch_bend"}, "pitch_bend"}]
        true -> [{"CC", {:midi_type, "cc"}, "cc"}]
      end

    type = midi_type(kind, c, d)
    number = if type == "note", do: "#{d.number} · #{note_name(d.number)}", else: "CC #{d.number}"

    if type == "pitch_bend" do
      no_bend = if assigns.bend, do: [], else: [caption("Greyed out: #{firmware_name(assigns.firmware)} ignores pitch bend.", :faint)]

      [
        segmented(types, type, if(assigns.bend, do: [], else: ["pitch_bend"])),
        ~MOB"""
        <Row gap={8}>
          {stepper("Ch", Integer.to_string(d.channel), {:channel, -1}, {:channel, 1})}
        </Row>
        """,
        caption("Centred where the phone is when it engages; assumes the firmware's own bend range (±2 semitones on OberVave and ShineOn).")
      ] ++ no_bend ++ [button("Bind pitch bend", :bind_midi, bg: c(:raised_hi), weight: :none, disabled: not assigns.bend)]
    else
      midi_number_inputs(c, d, types, type, number, if(motion_axis and not assigns.bend, do: ["pitch_bend"], else: []))
    end
  end

  defp midi_number_inputs(c, d, types, type, number, disabled) do
    jump =
      if type == "cc" and c["type"] == "slider",
        do: [toggle("Jump to touch position", "The slider's value follows the finger (MIDI CC only).", :jump, d.jump)],
        else: []

    [
      segmented(types, type, disabled),
      ~MOB"""
      <Row gap={8}>
        {stepper("Ch", Integer.to_string(d.channel), {:channel, -1}, {:channel, 1})}
        {stepper("", number, {:number, -1}, {:number, 1})}
        {button("−12", {:number, -12}, bg: c(:raised_hi), weight: 0.4)}
        {button("+12", {:number, 12}, bg: c(:raised_hi), weight: 0.4)}
      </Row>
      """
    ] ++ jump ++ [button(if(type == "note", do: "Bind note", else: "Bind CC"), :bind_midi, bg: c(:raised_hi), weight: :none)]
  end

  defp page_targets(layout, bound) do
    targets = [{"Previous page", "prev"}, {"Next page", "next"}] ++ for(p <- layout["pages"], do: {p["name"], p["id"]})
    chips = for {name, ref} <- targets, to = %{"page" => ref}, do: chip("go to: " <> name, {:toggle_target, to}, on: to in bound)
    bend = %{"action" => "bend"}

    [
      wrap(chips, 6),
      caption("Any button, pad or key can switch pages. Held notes keep sounding."),
      wrap([chip("bend keys", {:toggle_target, bend}, on: bend in bound)], 6),
      caption("Keyboard strips bend instead of glissando while this is held (or on, as a toggle).")
    ]
  end

  defp strum_settings(c) do
    keys = get_in(c, ["strum", "keys"]) || []
    chips = for k <- 0..26, do: chip(LayoutEdit.key_name(k), {:strum_key, k}, on: k in keys)

    [
      section("Strings → keys (low string at the bottom)"),
      wrap(chips, 4),
      caption("#{length(keys)} strings. Every finger plays; sliding across strings plays each one.")
    ]
  end

  defp other_settings(%{"type" => "screen"} = c) do
    scale = get_in(c, ["screen", "scale"]) || 0
    opts = [{"Fill", {:screen_scale, 0}, 0} | for(n <- 1..4, do: {"#{n}×", {:screen_scale, n}, n})]

    [
      section("Size"),
      segmented(opts, scale),
      caption("Fill: as big as the cells allow, sharp-scaled. 1×–4×: whole device-pixel multiples only, the largest that fits up to that.")
    ]
  end

  defp other_settings(%{"type" => "page_switcher"} = c) do
    look = get_in(c, ["page_switcher", "look"]) || "names"
    [section("Look"), segmented([{"Names", {:switcher_look, "names"}, "names"}, {"Dots", {:switcher_look, "dots"}, "dots"}], look)]
  end

  defp other_settings(%{"type" => "menu"}), do: [caption("Tap: menu. Long-press: page grid.")]
  defp other_settings(_), do: []

  defp keyboard_sheet(assigns, c, len) do
    kb = c["keyboard"] || %{}
    {from, to} = kb_range(c)
    arrows = Map.get(kb, "octave_arrows", true)
    wobble = kb["glide"] == "wobble"
    bend = kb["bend_range"] || 0.5
    vertical = kb["orientation"] == "vertical"
    colors = kb["pitch_colors"] == true
    whites = whites(from, to)
    width = key_width(len, whites, arrows, vertical and colors)
    n = to - from

    # 1 and 2 octaves, or all 27 keys (n = semitones from the lowest key to the highest)
    ranges =
      for {preset, span, name} <- [{1, 12, "1 oct"}, {2, 24, "2 oct"}, {:all, 26, "All 27"}] do
        key_w = key_width(len, whites(0, span), arrows, vertical and colors)
        {preset, "#{name} · #{key_w} pt", n == span, key_w < 40}
      end

    range_buttons =
      for {preset, text, on, warn} <- ranges do
        button(text, {:kb_range, preset}, on: on, fg: if(warn, do: c(:warn), else: c(:text_2)))
      end

    custom_on = n not in [12, 24, 26]
    # the from–to steppers below are the custom range; this segment only shows when it is in use
    custom = button("Custom", :close, on: custom_on, disabled: true)
    status_color = if width < 40, do: :warn, else: :fm
    comfort = if width < 40, do: "tight: under 40 pt", else: "comfortable on this phone"
    bend_buttons =
      for {r, name} <- [{0.5, "¼ tone"}, {1, "1 semitone"}, {2, "2 semitones"}],
          do: button("±" <> name, {:kb_bend, r}, on: bend == r, disabled: not assigns.bend)

    vel = velocity(c)
    vel_source = vel["source"] || "fixed"
    vel_min = vel["min"] || 40
    soft_buttons = for v <- [1, 20, 40, 64, 90], do: button("#{v}", {:kb_vel_min, v}, on: vel_min == v, disabled: vel_source != "position")
    swell = vel["swell"] == true
    pressure = vel["pressure"] == true
    pressure_ok = vel_source == "position" and cap?(assigns.firmware, :note_pressure)

    children = [
      title("Keyboard strip"),
      text("#{n + 1} keys, #{whites} white, #{width} pt each · #{comfort}", 13, status_color, true),
      section("Keys on screen"),
      ~MOB"""
      <Row gap={4} padding={4} background={c(:bg)}>
        {range_buttons}
        {custom}
      </Row>
      """,
      ~MOB"""
      <Row gap={8}>
        {stepper("From", LayoutEdit.key_name(from), {:kb_from, -1}, {:kb_from, 1})}
        {stepper("to", LayoutEdit.key_name(to), {:kb_to, -1}, {:kb_to, 1})}
      </Row>
      """,
      toggle("Octave arrows", "Slide the strip along the FM-1’s 27 keys. Past either end they press the firmware’s OCT− / OCT+.", :kb_arrows, arrows),
      toggle("Bend keys", "Hold a key and slide sideways to bend it. Sliding no longer plays the next key. A BEND toggle on the instrument does the same for every strip." <>
        if(assigns.bend, do: "", else: " Greyed out: #{firmware_name(assigns.firmware)} ignores pitch bend."), :kb_wobble, wobble and assigns.bend, disabled: not assigns.bend),
      section("Bend · half a key width of slide = the full bend · assumes the firmware's bend range is ±2"),
      ~MOB"""
      <Row gap={4} padding={4} background={c(:bg)}>
        {bend_buttons}
      </Row>
      """,
      section("Velocity"),
      segmented([{"Fixed", {:kb_velocity, "fixed"}, "fixed"}, {"Strike position", {:kb_velocity, "position"}, "position"}], vel_source),
      caption(
        "Fixed: the firmware’s own key presses, every note alike (as the FM-1). Strike position: the front edge of a key " <>
          "plays loudest, the back softest; the strip sends MIDI notes, with its own octave (OCT− / OCT+ move it too). " <>
          "While a firmware button is held, keys are firmware key presses again."
      ),
      section("Softest (back edge) · loudest is 127"),
      ~MOB"""
      <Row gap={4} padding={4} background={c(:bg)}>
        {soft_buttons}
      </Row>
      """,
      toggle("Note level follows the finger", "Strike position only: while a key is held, its own note is full at the key's front edge and silent at its back edge, other notes untouched." <>
        if(cap?(assigns.firmware, :note_pressure), do: "", else: " Greyed out: #{firmware_name(assigns.firmware)} doesn't take per-note pressure."),
        :kb_pressure, pressure and pressure_ok, disabled: not pressure_ok),
      toggle("Swell (all notes)", "Strike position only: slide a held key toward the front to get louder, back to get softer. A note's own velocity is fixed once it starts, so this moves the firmware's master volume (CC7): every sounding note swells together.",
        :kb_swell, swell and vel_source == "position" and not pressure, disabled: vel_source != "position" or pressure),
      toggle("Vertical", "A side keyboard: low notes at the bottom.", :kb_vertical, vertical),
      toggle("Pitch colours", "Key caps carry the 88-key colour; a vertical strip gets the colour rail to scroll it.", :kb_colors, colors),
      ~MOB"""
      <Row gap={8}>
        {button("Delete control", :delete_control, bg: c(:danger_bg), fg: c(:danger_text))}
        {button("Done", :close, bg: c(:fm), fg: c(:ink))}
      </Row>
      """
    ]

    sheet("keys-#{c["id"]}", children)
  end

  defp whites(from, to), do: Enum.count(from..to, &(not black?(&1)))
  defp black?(k), do: rem(Inputs.key_note(k), 12) in [1, 3, 6, 8, 10]

  # the white-key width the native view will draw (InstrumentView.kt keyboardKeys: 36 pt arrows each end;
  # a vertical colour strip gives its arrows' place to the rail)
  @arrow_pt 36
  defp key_width(len, whites, arrows, rail) when whites > 0 and len > 0 do
    a = if arrows and not rail, do: 2 * @arrow_pt, else: 0
    round((len - a) / whites)
  end

  defp key_width(_len, _whites, _arrows, _rail), do: 0

  ## Names

  defp describe(%{"key" => k}), do: "key #{LayoutEdit.key_name(k)}"
  defp describe(%{"encoder" => e} = t), do: encoder_name(e) <> if(t["invert"], do: " −", else: "")
  defp describe(%{"pot" => _}), do: "MASTER"
  defp describe(%{"button" => b}), do: button_name(b)
  defp describe(%{"midi" => %{"type" => "note"} = m}), do: "note #{note_name(m["number"] || 0)} · ch#{m["channel"] || 1}"
  defp describe(%{"midi" => %{"type" => "cc"} = m}) do
    values = if Map.has_key?(m, "on") or Map.has_key?(m, "off"), do: " · #{m["on"] || 127}/#{m["off"] || 0}", else: ""
    "CC#{m["number"] || 0} · ch#{m["channel"] || 1}" <> values <> if(m["jump"], do: " · jump", else: "")
  end

  defp describe(%{"midi" => %{"type" => "pitch_bend"} = m}), do: "pitch bend · ch#{m["channel"] || 1}"
  defp describe(%{"midi" => m}), do: "MIDI #{m["type"]}"
  defp describe(%{"page" => "next"}), do: "go to: next"
  defp describe(%{"page" => "prev"}), do: "go to: previous"
  defp describe(%{"page" => p}), do: "go to: #{p}"
  defp describe(%{"action" => "bend"}), do: "bend keys"
  defp describe(other), do: inspect(other)

  defp encoder_name(e) when e in [:algorithm, "algorithm"], do: "ALGO"
  defp encoder_name(e), do: e |> to_string() |> String.upcase()

  defp button_name(b) when b in [:oct_down, "oct_down"], do: "OCT−"
  defp button_name(b) when b in [:oct_up, "oct_up"], do: "OCT+"
  defp button_name(b), do: b |> to_string() |> String.upcase()

  defp note_name(n), do: Enum.at(~w(C C# D D# E F F# G G# A A# B), rem(n, 12)) <> Integer.to_string(div(n, 12) - 1)

  defp firmware_name(nil), do: "this firmware"

  defp firmware_name(id) do
    case Firmware.get(id) do
      %{name: name} -> name
      nil -> id
    end
  end

  defp cap?(firmware_id, cap) do
    case firmware_id && Firmware.get(firmware_id) do
      %{caps: caps} -> Map.get(caps, cap, false)
      _ -> false
    end
  end
end
