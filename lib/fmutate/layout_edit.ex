defmodule FMutate.LayoutEdit do
  @moduledoc """
  Editing a layout in place (HANDOFF §5): pure functions over a decoded layout (`fmutate.layout/1`, string
  keys), so the rules are tested here and the instrument view only proposes edits.

  Rules every edit keeps (`check/1` states them for a whole layout):

    * positions are whole cells of the layout's own grid (`grid.cols` × `grid.rows`) and stay inside it;
    * nothing overlaps: page controls not each other nor the dock (the dock is on every page);
    * no control is smaller than its minimum (`min_size/1`), resizing included;
    * exactly one `menu` (the creature), in the dock, 1×1: movable, never deleted or resized.

  Edits return `{:ok, layout}` or `{:error, message}`; the message is for the player (a toast).
  """

  alias FMutate.Inputs

  @type layout :: map()
  @type cell :: %{required(String.t()) => non_neg_integer()}
  @type result :: {:ok, layout} | {:error, String.t()}

  # what "Add here" offers, in the board's order (Edit-Add.dc.html), with the size a new one gets
  @addable [
    {"button", "Button", {1, 1}},
    {"knob", "Knob", {1, 1}},
    {"slider", "Slider", {1, 2}},
    {"xy_pad", "XY pad", {2, 2}},
    {"pad_grid", "Pad grid", {2, 2}},
    {"strum", "Strum strip", {1, 3}},
    {"keyboard", "Keyboard strip", {4, 2}},
    {"screen", "Firmware screen", {3, 3}},
    {"key", "Key", {1, 1}},
    {"label", "Label", {1, 1}},
    {"page_switcher", "Page switcher", {2, 1}}
  ]

  @doc "The control types \"Add here\" offers: `{type, name, default_size}`."
  def addable, do: @addable

  @doc """
  Minimum size in cells `{w, h}` (HANDOFF §5). Sliders, keyboards and strum strips are measured along
  their own orientation: a horizontal slider needs 2×1, a vertical keyboard 2×4. The firmware screen needs
  2×2, the smallest span that holds its 240 px at 1× on a 3× phone (§7).
  """
  def min_size(%{"type" => "slider"} = c), do: if(vertical_slider?(c), do: {1, 2}, else: {2, 1})
  def min_size(%{"type" => "keyboard"} = c), do: if(vertical_keyboard?(c), do: {2, 4}, else: {4, 2})
  def min_size(%{"type" => type}), do: min_size(type)
  def min_size(type) when type in ["xy_pad", "pad_grid", "screen"], do: {2, 2}
  def min_size("strum"), do: {1, 3}
  def min_size("keyboard"), do: {4, 2}
  def min_size("slider"), do: {1, 2}
  def min_size("page_switcher"), do: {2, 1}
  def min_size(_), do: {1, 1}

  defp vertical_slider?(c), do: get_in(c, ["slider", "orientation"]) != "horizontal"
  defp vertical_keyboard?(c), do: get_in(c, ["keyboard", "orientation"]) == "vertical"

  ## Reading

  @doc "The page with this id (or the first page)."
  def page(layout, page_id), do: Enum.find(layout["pages"], &(&1["id"] == page_id)) || hd(layout["pages"])

  @doc "Index of a page id (0 if unknown)."
  def page_index(layout, page_id), do: Enum.find_index(layout["pages"], &(&1["id"] == page_id)) || 0

  @doc "Every control drawn on a page: the dock's, then the page's."
  def controls(layout, page_id), do: dock(layout) ++ (page(layout, page_id)["controls"] || [])

  @doc "`{:dock | {:page, page_id}, control}` for a control id, or nil."
  def find(layout, id) do
    case Enum.find(dock(layout), &(&1["id"] == id)) do
      nil ->
        Enum.find_value(layout["pages"], fn p ->
          c = Enum.find(p["controls"] || [], &(&1["id"] == id))
          c && {{:page, p["id"]}, c}
        end)

      c ->
        {:dock, c}
    end
  end

  defp dock(layout), do: layout["dock"] || []

  @doc "A cell map from integers."
  def cell(col, row, w, h), do: %{"col" => col, "row" => row, "w" => w, "h" => h}

  defp overlaps?(a, b) do
    a["col"] < b["col"] + b["w"] and b["col"] < a["col"] + a["w"] and
      a["row"] < b["row"] + b["h"] and b["row"] < a["row"] + a["h"]
  end

  defp inside?(layout, c) do
    %{"cols" => cols, "rows" => rows} = layout["grid"]
    c["col"] >= 0 and c["row"] >= 0 and c["w"] >= 1 and c["h"] >= 1 and c["col"] + c["w"] <= cols and
      c["row"] + c["h"] <= rows
  end

  # the cells a control may not take: everything on its page plus the dock, or, for a dock control,
  # everything on every page
  defp others(layout, {:page, page_id}, id),
    do: for(c <- controls(layout, page_id), c["id"] != id, do: c)

  defp others(layout, :dock, id) do
    page_controls = Enum.flat_map(layout["pages"], &(&1["controls"] || []))
    for c <- dock(layout) ++ page_controls, c["id"] != id, do: c
  end

  @doc "Whether `cell` is free for control `id` (nil for a new control) at `where` (`:dock` or `{:page, id}`)."
  def free?(layout, where, id, cell) do
    inside?(layout, cell) and not Enum.any?(others(layout, where, id), &overlaps?(&1["at"], cell))
  end

  @doc """
  The free run through an empty cell: `{wide, tall}` = free cells in its row and in its column, counted
  through the cell. `{0, 0}` if the cell is taken.
  """
  def room(layout, page_id, col, row) do
    free = fn c, r -> free?(layout, {:page, page_id}, nil, cell(c, r, 1, 1)) end

    if free.(col, row) do
      %{"cols" => cols, "rows" => rows} = layout["grid"]
      left = Enum.take_while((col - 1)..0//-1, &free.(&1, row)) |> length()
      right = Enum.take_while((col + 1)..(cols - 1)//1, &free.(&1, row)) |> length()
      up = Enum.take_while((row - 1)..0//-1, &free.(col, &1)) |> length()
      down = Enum.take_while((row + 1)..(rows - 1)//1, &free.(col, &1)) |> length()
      {left + 1 + right, up + 1 + down}
    else
      {0, 0}
    end
  end

  @doc """
  Where a `w`×`h` control can go so that it covers the empty cell `(col, row)`: the cell itself as its
  top-left corner if possible, else the nearest shift up/left. nil if it can't.
  """
  def spot(layout, page_id, col, row, w, h) do
    candidates = for dy <- 0..(h - 1), dx <- 0..(w - 1), do: cell(col - dx, row - dy, w, h)
    Enum.find(candidates, &free?(layout, {:page, page_id}, nil, &1))
  end

  @doc """
  What "Add here" shows for an empty cell: `[%{type, name, fits, size}]`, where `size` is the minimum
  (`"2×2"`). Types that don't fit are listed too, with `fits: false`.
  """
  def add_menu(layout, page_id, col, row) do
    for {type, name, _} <- @addable do
      {w, h} = min_size(type)
      %{type: type, name: name, fits: spot(layout, page_id, col, row, w, h) != nil, size: "#{w}×#{h}"}
    end
  end

  ## Edits

  @doc "Move a control to a new top-left cell, keeping its size."
  @spec move(layout, String.t(), integer, integer) :: result
  def move(layout, id, col, row) do
    with {:ok, where, c} <- fetch(layout, id) do
      at = %{c["at"] | "col" => col, "row" => row}
      place(layout, where, c, at, "Overlaps another control")
    end
  end

  @doc "Resize (and possibly move) a control to `cell`; never below its minimum, the menu never."
  @spec resize(layout, String.t(), map) :: result
  def resize(layout, id, %{"col" => _, "row" => _, "w" => w, "h" => h} = at) do
    with {:ok, where, c} <- fetch(layout, id) do
      {mw, mh} = min_size(c)

      cond do
        c["type"] == "menu" -> {:error, "The creature stays 1×1"}
        w < mw or h < mh -> {:error, "#{type_name(c["type"])} needs at least #{mw}×#{mh}"}
        true -> place(layout, where, c, Map.take(at, ~w(col row w h)), "Overlaps another control")
      end
    end
  end

  defp place(layout, where, c, at, overlap_msg) do
    cond do
      not inside?(layout, at) -> {:error, "Off the grid"}
      not free?(layout, where, c["id"], at) -> {:error, overlap_msg}
      true -> {:ok, update(layout, c["id"], &Map.put(&1, "at", at))}
    end
  end

  @doc """
  Move a page control to the next (`1`) or previous (`-1`) page, creating that page when there is none
  (HANDOFF §5: drag onto the side edge). It keeps its cell if that is free there, else takes the first
  free spot of its size. Returns `{:ok, layout, page_id}` with the page it landed on.
  """
  def to_page(layout, id, dir) when dir in [-1, 1] do
    with {:ok, where, c} <- fetch(layout, id) do
      case where do
        :dock ->
          {:error, "Pinned to the dock: it is on every page"}

        {:page, from} ->
          i = page_index(layout, from) + dir
          {layout, target} = target_page(layout, i)
          layout = remove(layout, id)
          at = c["at"]
          where = {:page, target}

          spot =
            if free?(layout, where, nil, at),
              do: at,
              else: first_free(layout, target, at["w"], at["h"])

          case spot do
            nil -> {:error, "No room for it on that page"}
            spot -> {:ok, insert(layout, target, Map.put(c, "at", spot)), target}
          end
      end
    end
  end

  defp target_page(layout, i) when i < 0 do
    {layout, page} = new_page(layout, nil)
    {%{layout | "pages" => [page | layout["pages"]]}, page["id"]}
  end

  defp target_page(layout, i) do
    case Enum.at(layout["pages"], i) do
      nil ->
        {layout, page} = new_page(layout, nil)
        {%{layout | "pages" => layout["pages"] ++ [page]}, page["id"]}

      page ->
        {layout, page["id"]}
    end
  end

  defp first_free(layout, page_id, w, h) do
    %{"cols" => cols, "rows" => rows} = layout["grid"]

    Enum.find_value(0..(rows - h)//1, fn r ->
      Enum.find_value(0..(cols - w)//1, fn col ->
        at = cell(col, r, w, h)
        if free?(layout, {:page, page_id}, nil, at), do: at
      end)
    end)
  end

  @doc """
  Add a control of `type` covering the empty cell `(col, row)` of a page, at its default size if that
  fits, else at its minimum. Returns `{:ok, layout, control_id}`.
  """
  def add(layout, page_id, type, col, row) do
    case List.keyfind(@addable, type, 0) do
      nil ->
        {:error, "Unknown control type"}

      {_, name, {dw, dh}} ->
        {mw, mh} = min_size(type)
        at = spot(layout, page_id, col, row, dw, dh) || spot(layout, page_id, col, row, mw, mh)

        if at do
          id = new_id(layout, type)
          control = Map.merge(%{"id" => id, "type" => type, "at" => at}, defaults(type, name, at))
          {:ok, insert(layout, page(layout, page_id)["id"], control), id}
        else
          {:error, "#{name} needs #{mw}×#{mh} here"}
        end
    end
  end

  # What a new control starts with. Bindings stay empty unless the control is meaningless without one
  # (keys, pads, strings): the binding sheet is one tap away.
  defp defaults("keyboard", _name, %{"w" => w, "h" => h}) do
    vertical = h > w
    kb = %{"from_key" => 7, "to_key" => 19, "octave_arrows" => true, "glide" => "glissando"}
    %{"keyboard" => if(vertical, do: Map.put(kb, "orientation", "vertical"), else: kb)}
  end

  defp defaults("key", _name, _at), do: %{"label" => "C4", "bindings" => [%{"to" => %{"key" => 7}}]}

  defp defaults("pad_grid", _name, _at) do
    pads = for k <- [0, 2, 4, 5], do: %{"label" => key_name(k), "bindings" => [%{"to" => %{"key" => k}}]}
    %{"pad_grid" => %{"cols" => 2, "rows" => 2, "pads" => pads}}
  end

  defp defaults("strum", _name, _at), do: %{"strum" => %{"keys" => [7, 11, 14, 19, 23, 26]}}
  defp defaults("screen", _name, _at), do: %{"screen" => %{}}

  defp defaults("slider", name, %{"w" => w, "h" => h}),
    do: %{"label" => name, "slider" => %{"orientation" => if(w > h, do: "horizontal", else: "vertical")}}

  defp defaults("page_switcher", _name, _at), do: %{"page_switcher" => %{"look" => "names"}}
  defp defaults(type, name, _at) when type in ["button", "knob", "xy_pad", "label"], do: %{"label" => label16(name)}

  defp label16(s), do: String.slice(s, 0, 16)

  defp new_id(layout, type) do
    taken = all_ids(layout)
    Stream.iterate(1, &(&1 + 1)) |> Enum.find_value(fn n -> "#{type}_#{n}" not in taken && "#{type}_#{n}" end)
  end

  defp all_ids(layout) do
    MapSet.new(dock(layout) ++ Enum.flat_map(layout["pages"], &(&1["controls"] || [])), & &1["id"])
  end

  @doc "Delete a control. The creature (menu) can't be deleted."
  @spec delete(layout, String.t()) :: result
  def delete(layout, id) do
    with {:ok, _where, c} <- fetch(layout, id) do
      if c["type"] == "menu", do: {:error, "The creature can't be deleted"}, else: {:ok, remove(layout, id)}
    end
  end

  @doc "Replace a control's fields (label, bindings, keyboard settings…); `at`, `id` and `type` are kept."
  @spec put(layout, String.t(), map) :: result
  def put(layout, id, fields) do
    with {:ok, _where, c} <- fetch(layout, id) do
      fields = Map.drop(fields, ["id", "type", "at"])
      updated = Map.merge(c, fields)
      {mw, mh} = min_size(updated)

      if updated["at"]["w"] < mw or updated["at"]["h"] < mh,
        do: {:error, "Too small for that: needs #{mw}×#{mh}"},
        else: {:ok, update(layout, id, fn _ -> updated end)}
    end
  end

  ## Bindings

  @doc """
  The binding list of a control, or of pad `sub` of a pad grid.
  """
  def bindings(layout, id, sub \\ nil) do
    case find(layout, id) do
      {_, %{"type" => "pad_grid"} = c} when is_integer(sub) ->
        get_in(c, ["pad_grid", "pads"]) |> Enum.at(sub, %{}) |> Map.get("bindings", [])

      {_, c} ->
        c["bindings"] || []

      nil ->
        []
    end
  end

  @doc "Set the binding list of a control (or of pad `sub`)."
  @spec set_bindings(layout, String.t(), integer | nil, [map]) :: result
  def set_bindings(layout, id, sub, bindings) do
    with {:ok, _where, c} <- fetch(layout, id) do
      cond do
        c["type"] == "menu" ->
          {:error, "The creature opens the menu"}

        c["type"] == "pad_grid" and is_integer(sub) ->
          pads = get_in(c, ["pad_grid", "pads"]) || []

          if sub < length(pads) do
            pads = List.update_at(pads, sub, &Map.put(&1, "bindings", bindings))
            {:ok, update(layout, id, &put_in(&1, ["pad_grid", "pads"], pads))}
          else
            {:error, "No such pad"}
          end

        true ->
          {:ok, update(layout, id, &Map.put(&1, "bindings", bindings))}
      end
    end
  end

  @doc "The gesture a new binding of this control listens to (`press`, `value`, `x`)."
  def default_on(%{"type" => type}) when type in ["knob", "slider"], do: "value"
  def default_on(%{"type" => "xy_pad"}), do: "x"
  def default_on(_), do: "press"

  ## Pages

  @doc "Append an empty page; returns `{:ok, layout, page_id}`."
  def add_page(layout, name \\ nil) do
    {layout, page} = new_page(layout, name)
    {:ok, %{layout | "pages" => layout["pages"] ++ [page]}, page["id"]}
  end

  defp new_page(layout, name) do
    ids = MapSet.new(layout["pages"], & &1["id"])
    n = Enum.find(Stream.iterate(length(layout["pages"]) + 1, &(&1 + 1)), &("page-#{&1}" not in ids))
    {layout, %{"id" => "page-#{n}", "name" => name || "Page #{n}", "controls" => []}}
  end

  @doc """
  A new page made from a preset's first page (and its dock, minus the creature), fitted to this layout's
  grid. A control whose cell is taken (by this layout's dock, say) goes to the first free spot of its size,
  else gives up a row or column at a time down to its minimum; what still doesn't fit is left out and
  counted. `{:ok, layout, page_id, dropped}`.
  """
  def add_page_from_preset(layout, preset) do
    src = hd(preset["pages"])
    {layout, page} = new_page(layout, String.slice(src["name"] || "Preset", 0, 12))
    sx = layout["grid"]["cols"] / preset["grid"]["cols"]
    sy = layout["grid"]["rows"] / preset["grid"]["rows"]
    incoming = for c <- (preset["dock"] || []) ++ src["controls"], c["type"] != "menu", do: c
    layout = %{layout | "pages" => layout["pages"] ++ [page]}

    {layout, dropped} =
      Enum.reduce(incoming, {layout, 0}, fn c, {acc, dropped} ->
        id = if c["id"] in all_ids(acc), do: new_id(acc, c["type"]), else: c["id"]

        case fit_in(acc, page["id"], c, scale(c["at"], sx, sy)) do
          nil -> {acc, dropped + 1}
          at -> {insert(acc, page["id"], %{c | "id" => id, "at" => at}), dropped}
        end
      end)

    {:ok, layout, page["id"], dropped}
  end

  defp fit_in(layout, page_id, c, at) do
    {mw, mh} = min_size(c)

    cond do
      at["w"] < mw or at["h"] < mh ->
        nil

      free?(layout, {:page, page_id}, nil, at) ->
        at

      true ->
        sizes = for w <- at["w"]..mw//-1, h <- at["h"]..mh//-1, do: {w, h}

        sizes
        |> Enum.sort_by(fn {w, h} -> -w * h end)
        |> Enum.find_value(fn {w, h} -> first_free(layout, page_id, w, h) end)
    end
  end

  defp scale(at, sx, sy) do
    col = round(at["col"] * sx)
    row = round(at["row"] * sy)
    w = max(1, round((at["col"] + at["w"]) * sx) - col)
    h = max(1, round((at["row"] + at["h"]) * sy) - row)
    cell(col, row, w, h)
  end

  @doc "Rename a page (12 characters at most)."
  def rename_page(layout, page_id, name) do
    name = name |> String.trim() |> String.slice(0, 12)

    if name == "",
      do: {:error, "A page needs a name"},
      else: {:ok, update_page(layout, page_id, &Map.put(&1, "name", name))}
  end

  @doc "Delete a page (never the last one)."
  def delete_page(layout, page_id) do
    if length(layout["pages"]) <= 1,
      do: {:error, "A layout keeps at least one page"},
      else: {:ok, %{layout | "pages" => Enum.reject(layout["pages"], &(&1["id"] == page_id))}}
  end

  @doc "Move a page one place earlier (`-1`) or later (`1`)."
  def move_page(layout, page_id, dir) do
    i = page_index(layout, page_id)
    j = i + dir
    pages = layout["pages"]

    if j < 0 or j >= length(pages) do
      {:ok, layout}
    else
      a = Enum.at(pages, i)
      b = Enum.at(pages, j)
      {:ok, %{layout | "pages" => pages |> List.replace_at(i, b) |> List.replace_at(j, a)}}
    end
  end

  ## Layout settings

  @doc "Rename the layout (40 characters at most)."
  def rename(layout, name) do
    name = name |> String.trim() |> String.slice(0, 40)
    if name == "", do: {:error, "A layout needs a name"}, else: {:ok, %{layout | "name" => name}}
  end

  @doc """
  Turn the layout to the other frame. The grid turns with it (14×6 landscape ↔ 6×14 portrait) and every
  control is mirrored over the diagonal, so nothing overlaps and positions stay recognisable: a keyboard
  along the bottom becomes a side keyboard. Keyboards and sliders change orientation to match.
  """
  def set_frame(layout, frame) when frame in ["portrait", "landscape"] do
    if layout["frame"] == frame do
      {:ok, layout}
    else
      turn = fn c -> c |> Map.update!("at", &transpose/1) |> turn_orientation() end

      turned = %{
        layout
        | "frame" => frame,
          "grid" => %{"cols" => layout["grid"]["rows"], "rows" => layout["grid"]["cols"]},
          "dock" => Enum.map(dock(layout), turn),
          "pages" => Enum.map(layout["pages"], fn p -> Map.update(p, "controls", [], &Enum.map(&1, turn)) end)
      }

      case semantic_errors(turned) do
        [] -> {:ok, turned}
        [msg | _] -> {:error, "Can't turn this layout: " <> msg}
      end
    end
  end

  defp transpose(at), do: cell(at["row"], at["col"], at["h"], at["w"])

  defp turn_orientation(%{"type" => "keyboard"} = c) do
    kb = c["keyboard"] || %{}
    o = if kb["orientation"] == "vertical", do: "horizontal", else: "vertical"
    Map.put(c, "keyboard", Map.put(kb, "orientation", o))
  end

  defp turn_orientation(%{"type" => "slider"} = c) do
    sl = c["slider"] || %{}
    o = if sl["orientation"] == "horizontal", do: "vertical", else: "horizontal"
    Map.put(c, "slider", Map.put(sl, "orientation", o))
  end

  defp turn_orientation(c), do: c

  @doc """
  Page switcher look (Pages.dc.html): `names` or `dots` restyle the layout's page switchers, and give it one in
  the dock next to the creature if it has none (and there is room on every page); `hidden` takes the dock's
  switcher away (the page grid, on a long-press of the creature, still reaches every page).
  """
  def set_switcher(layout, look) when look in ["names", "dots", "hidden"] do
    layout = Map.put(layout, "switcher", look)
    all = dock(layout) ++ Enum.flat_map(layout["pages"], &(&1["controls"] || []))
    switchers = for c <- all, c["type"] == "page_switcher", do: c["id"]

    cond do
      look == "hidden" ->
        {:ok, Map.put(layout, "dock", Enum.reject(dock(layout), &(&1["type"] == "page_switcher")))}

      switchers != [] ->
        {:ok, Enum.reduce(switchers, layout, fn id, l -> update(l, id, &Map.put(&1, "page_switcher", %{"look" => look})) end)}

      true ->
        case switcher_spot(layout) do
          nil ->
            {:error, "No room in the dock for a page switcher: add one to a page instead"}

          at ->
            sw = %{"id" => new_id(layout, "page_switcher"), "type" => "page_switcher", "at" => at, "page_switcher" => %{"look" => look}}
            {:ok, Map.update(layout, "dock", [sw], &(&1 ++ [sw]))}
        end
    end
  end

  # beside the creature, as wide as fits (2..4 cells), else any free 2×1 run that is free on every page
  defp switcher_spot(layout) do
    %{"at" => m} = Enum.find(dock(layout), &(&1["type"] == "menu"))
    beside = for w <- 4..2//-1, col <- [m["col"] + 1, m["col"] - w], do: cell(col, m["row"], w, 1)
    %{"cols" => cols, "rows" => rows} = layout["grid"]
    anywhere = for r <- 0..(rows - 1), col <- 0..(cols - 2), do: cell(col, r, 2, 1)
    Enum.find(beside ++ anywhere, &free?(layout, :dock, nil, &1))
  end

  ## Checking a whole layout

  @doc """
  The rules of the module doc for a whole layout: `[]` when it keeps them, else a message per problem.
  """
  def semantic_errors(layout) do
    menus = Enum.filter(dock(layout), &(&1["type"] == "menu"))
    page_menus = Enum.flat_map(layout["pages"], fn p -> Enum.filter(p["controls"] || [], &(&1["type"] == "menu")) end)

    ids = Enum.map(dock(layout) ++ Enum.flat_map(layout["pages"], &(&1["controls"] || [])), & &1["id"])

    menu_errors =
      cond do
        page_menus != [] -> ["the creature must be in the dock"]
        length(menus) != 1 -> ["a layout has exactly one creature"]
        hd(menus)["at"]["w"] != 1 or hd(menus)["at"]["h"] != 1 -> ["the creature is 1×1"]
        true -> []
      end

    dup_errors = for {id, n} <- Enum.frequencies(ids), n > 1, do: "control id #{id} is used twice"

    page_errors =
      Enum.flat_map(layout["pages"], fn p ->
        all = dock(layout) ++ (p["controls"] || [])

        size =
          for c <- all, {mw, mh} = min_size(c), c["at"]["w"] < mw or c["at"]["h"] < mh,
              do: "#{c["id"]} is smaller than #{mw}×#{mh}"

        outside = for c <- all, not inside?(layout, c["at"]), do: "#{c["id"]} is off the grid"

        overlap =
          for {a, i} <- Enum.with_index(all), b <- Enum.drop(all, i + 1), overlaps?(a["at"], b["at"]),
              do: "#{a["id"]} overlaps #{b["id"]} on #{p["name"]}"

        size ++ outside ++ overlap
      end)

    Enum.uniq(menu_errors ++ dup_errors ++ page_errors)
  end

  ## Helpers

  defp fetch(layout, id) do
    case find(layout, id) do
      nil -> {:error, "That control is gone"}
      {where, c} -> {:ok, where, c}
    end
  end

  defp update(layout, id, fun) do
    upd = fn list -> Enum.map(list, fn c -> if c["id"] == id, do: fun.(c), else: c end) end

    layout
    |> Map.put("dock", upd.(dock(layout)))
    |> Map.update!("pages", fn pages -> Enum.map(pages, &Map.update(&1, "controls", [], upd)) end)
  end

  defp update_page(layout, page_id, fun),
    do: Map.update!(layout, "pages", &Enum.map(&1, fn p -> if p["id"] == page_id, do: fun.(p), else: p end))

  defp remove(layout, id) do
    rm = &Enum.reject(&1, fn c -> c["id"] == id end)

    layout
    |> Map.put("dock", rm.(dock(layout)))
    |> Map.update!("pages", fn pages -> Enum.map(pages, &Map.update(&1, "controls", [], rm)) end)
  end

  defp insert(layout, page_id, control),
    do: update_page(layout, page_id, &Map.update(&1, "controls", [control], fn cs -> cs ++ [control] end))

  @doc "A player-facing name for a control type."
  def type_name(type) do
    case List.keyfind(@addable, type, 0) do
      {_, name, _} -> name
      nil -> if type == "menu", do: "Creature", else: type
    end
  end

  @doc "Note name of a firmware key (key 0 = F3)."
  def key_name(k) do
    n = Inputs.key_note(k)
    Enum.at(~w(C C# D D# E F F# G G# A A# B), rem(n, 12)) <> Integer.to_string(div(n, 12) - 1)
  end
end
