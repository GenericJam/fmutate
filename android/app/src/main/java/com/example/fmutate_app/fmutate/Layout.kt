package com.example.fmutate_app.fmutate

import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.roundToInt

/*
 * The layout model (priv/layout.schema.json, "fmutate.layout/1") and the grid (HANDOFF §5, FMutate.Style.grid_for/2).
 * Pure: no Android types, so it is unit-testable on the JVM.
 */

sealed class Target {
    data class Key(val n: Int) : Target()
    data class Encoder(val id: String, val ptPerClick: Float, val invert: Boolean) : Target()
    object Pot : Target()
    data class Button(val id: String) : Target()
    data class Midi(val type: String, val channel: Int, val number: Int, val jump: Boolean, val on: Int = 127, val off: Int = 0) : Target()
    data class Page(val ref: String) : Target()
    /** App actions on the surface itself (no firmware input): "bend" switches the keyboard strips to bending. */
    data class Action(val id: String) : Target()

    /** Absolute targets share one value between every control bound to them (HANDOFF §6 rule 7). */
    val absoluteKey: String?
        get() = when (this) {
            is Pot -> "pot:master"
            is Midi -> if (type == "cc") "cc:$channel:$number" else null
            else -> null
        }
}

data class Binding(val on: String, val to: Target, val mode: String)

data class Cell(val col: Int, val row: Int, val w: Int, val h: Int) {
    fun overlaps(o: Cell) = col < o.col + o.w && o.col < col + w && row < o.row + o.h && o.row < row + h
}

data class Pad(val label: String, val color: String, val bindings: List<Binding>)

data class Control(
    val id: String,
    val type: String,
    val at: Cell,
    val label: String,
    val color: String,
    val bindings: List<Binding>,
    // keyboard
    val fromKey: Int = 0,
    val toKey: Int = 26,
    val octaveArrows: Boolean = true,
    val vertical: Boolean = false,
    val wobble: Boolean = false,
    val bendRange: Float = 0.5f,          // semitones at half a key width of slide
    val pitchColors: Boolean = false,
    // velocity "position": the strip plays MIDI notes, velocity from where the key is struck (velMin..velMax);
    // "fixed" (default): firmware key presses, the firmware's own fixed velocity
    val strikeVelocity: Boolean = false,
    val velMin: Int = 40,
    val velMax: Int = 127,
    val velSwell: Boolean = false,        // position, opt-in: front/back on a held key sets CC7 (every sounding note)
    // pad_grid
    val padCols: Int = 1,
    val padRows: Int = 1,
    val pads: List<Pad> = emptyList(),
    // slider, xy_pad, strum, screen, page_switcher
    val sliderVertical: Boolean = true,
    val springBack: Boolean = false,
    val strings: List<Int> = emptyList(),
    val screenScale: Int = 0,
    val switcherDots: Boolean = false,
) {
    fun binding(on: String): Binding? = bindings.firstOrNull { it.on == on }
}

data class Page(val id: String, val name: String, val controls: List<Control>)

data class Layout(
    val id: String,
    val name: String,
    val landscape: Boolean,
    val gridCols: Int,
    val gridRows: Int,
    val switcher: String,
    val dock: List<Control>,
    val pages: List<Page>,
) {
    companion object {
        fun parse(json: String): Layout = fromJson(JSONObject(json))

        fun fromJson(o: JSONObject): Layout {
            val grid = o.getJSONObject("grid")
            val dock = controls(o.optJSONArray("dock"))
            val pages = o.getJSONArray("pages").objects().map { p ->
                Page(p.getString("id"), p.optString("name", p.getString("id")), controls(p.optJSONArray("controls")))
            }
            return Layout(
                id = o.getString("id"),
                name = o.optString("name", o.getString("id")),
                landscape = o.optString("frame", "landscape") == "landscape",
                gridCols = grid.getInt("cols"),
                gridRows = grid.getInt("rows"),
                switcher = o.optString("switcher", "names"),
                dock = withMenu(dock, pages, grid.getInt("cols"), grid.getInt("rows")),
                pages = pages,
            )
        }

        // Every layout has exactly one menu (the creature) in the dock; add it at the first free cell if missing.
        private fun withMenu(dock: List<Control>, pages: List<Page>, cols: Int, rows: Int): List<Control> {
            if (dock.any { it.type == "menu" } || pages.any { p -> p.controls.any { it.type == "menu" } }) return dock
            val taken = dock.map { it.at } + pages.flatMap { p -> p.controls.map { it.at } }
            for (r in 0 until rows) for (c in 0 until cols) {
                val cell = Cell(c, r, 1, 1)
                if (taken.none { it.overlaps(cell) }) return dock + Control("menu", "menu", cell, "", "default", emptyList())
            }
            return dock
        }

        private fun controls(a: JSONArray?): List<Control> = a?.objects()?.map(::control) ?: emptyList()

        private fun control(o: JSONObject): Control {
            val at = o.getJSONObject("at")
            val kb = o.optJSONObject("keyboard")
            val pg = o.optJSONObject("pad_grid")
            val sl = o.optJSONObject("slider")
            val xy = o.optJSONObject("xy_pad")
            val st = o.optJSONObject("strum")
            val sc = o.optJSONObject("screen")
            val ps = o.optJSONObject("page_switcher")
            return Control(
                id = o.getString("id"),
                type = o.getString("type"),
                at = Cell(at.getInt("col"), at.getInt("row"), at.getInt("w"), at.getInt("h")),
                label = o.optString("label", ""),
                color = o.optString("color", "default"),
                bindings = bindings(o.optJSONArray("bindings")),
                fromKey = kb?.optInt("from_key", 0) ?: 0,
                toKey = kb?.optInt("to_key", 26) ?: 26,
                octaveArrows = kb?.optBoolean("octave_arrows", true) ?: true,
                vertical = kb?.optString("orientation", "horizontal") == "vertical",
                wobble = kb?.optString("glide", "glissando") == "wobble",
                bendRange = kb?.optDouble("bend_range", 0.5)?.toFloat() ?: 0.5f,
                pitchColors = kb?.optBoolean("pitch_colors", false) ?: false,
                strikeVelocity = kb?.optJSONObject("velocity")?.optString("source", "fixed") == "position",
                velMin = kb?.optJSONObject("velocity")?.optInt("min", 40) ?: 40,
                velMax = kb?.optJSONObject("velocity")?.optInt("max", 127) ?: 127,
                velSwell = kb?.optJSONObject("velocity")?.optBoolean("swell", false) ?: false,
                padCols = pg?.optInt("cols", 1) ?: 1,
                padRows = pg?.optInt("rows", 1) ?: 1,
                pads = pg?.optJSONArray("pads")?.objects()?.map {
                    Pad(it.optString("label", ""), it.optString("color", "default"), bindings(it.optJSONArray("bindings")))
                } ?: emptyList(),
                sliderVertical = sl?.optString("orientation", "vertical") != "horizontal",
                springBack = xy?.optString("on_release", "stay") == "spring_back",
                strings = st?.optJSONArray("keys")?.let { a -> (0 until a.length()).map { a.getInt(it) } } ?: emptyList(),
                screenScale = sc?.optInt("scale", 0) ?: 0,
                switcherDots = ps?.optString("look", "names") == "dots",
            )
        }

        private fun bindings(a: JSONArray?): List<Binding> = a?.objects()?.mapNotNull { b ->
            target(b.getJSONObject("to"))?.let { Binding(b.optString("on", "press"), it, b.optString("mode", "momentary")) }
        } ?: emptyList()

        private fun target(t: JSONObject): Target? = when {
            t.has("key") -> Target.Key(t.getInt("key"))
            t.has("encoder") -> Target.Encoder(
                t.getString("encoder"), t.optDouble("pt_per_click", 6.0).toFloat(), t.optBoolean("invert", false),
            )
            t.has("pot") -> Target.Pot
            t.has("button") -> Target.Button(t.getString("button"))
            t.has("midi") -> t.getJSONObject("midi").let {
                Target.Midi(
                    it.getString("type"), it.optInt("channel", 1), it.optInt("number", 0), it.optBoolean("jump", false),
                    it.optInt("on", 127), it.optInt("off", 0),
                )
            }
            t.has("page") -> Target.Page(t.getString("page"))
            t.has("action") -> Target.Action(t.getString("action"))
            else -> null
        }

        private fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }
    }
}

/** The device grid (HANDOFF §5): all values in dp. */
data class Grid(val cols: Int, val rows: Int, val cellW: Float, val cellH: Float, val gap: Float, val left: Float, val top: Float) {
    data class Rect(val x: Float, val y: Float, val w: Float, val h: Float) {
        fun contains(px: Float, py: Float) = px >= x && px < x + w && py >= y && py < y + h
        val cx get() = x + w / 2
        val cy get() = y + h / 2
    }

    fun rect(c: Cell): Rect = Rect(
        left + c.col * (cellW + gap),
        top + c.row * (cellH + gap),
        c.w * cellW + (c.w - 1) * gap,
        c.h * cellH + (c.h - 1) * gap,
    )

    companion object {
        const val GUTTER = 28f
        const val INSET = 12f
        const val MIN_CELL = 48f
        const val GAP = 8f

        /** FMutate.Style.grid_for/2 on the area left after the side gutters and the top/bottom inset. */
        fun forScreen(wDp: Float, hDp: Float): Grid {
            val uw = wDp - 2 * GUTTER
            val uh = hDp - 2 * INSET
            val cols = max(1, floor((uw + GAP) / (MIN_CELL + GAP)).toInt())
            val rows = max(1, floor((uh + GAP) / (MIN_CELL + GAP)).toInt())
            return Grid(cols, rows, (uw - (cols - 1) * GAP) / cols, (uh - (rows - 1) * GAP) / rows, GAP, GUTTER, INSET)
        }
    }
}

/**
 * Minimum sizes in cells (HANDOFF §5; FMutate.LayoutEdit.min_size/1 is the same rule). Sliders and keyboard
 * strips are measured along their own orientation; the firmware screen needs 2×2 (240 px at 1× on a 3× phone).
 */
fun minSize(c: Control): Pair<Int, Int> = when (c.type) {
    "slider" -> if (c.sliderVertical) 1 to 2 else 2 to 1
    "keyboard" -> if (c.vertical) 2 to 4 else 4 to 2
    else -> minSize(c.type)
}

fun minSize(type: String): Pair<Int, Int> = when (type) {
    "slider" -> 1 to 2
    "xy_pad", "pad_grid", "screen" -> 2 to 2
    "strum" -> 1 to 3
    "keyboard" -> 4 to 2
    "page_switcher" -> 2 to 1
    else -> 1 to 1
}

/**
 * A layout's cells moved onto the device grid: positions scale with cols/rows and round. Returns the moved
 * cell per control id and whether everything still fits (no control below its minimum size, no overlap).
 */
data class Placement(val cells: Map<String, Cell>, val fits: Boolean)

fun place(layout: Layout, page: Page, grid: Grid): Placement {
    val sx = grid.cols.toFloat() / layout.gridCols
    val sy = grid.rows.toFloat() / layout.gridRows
    val all = layout.dock + page.controls
    val cells = all.associate { c ->
        if (layout.gridCols == grid.cols && layout.gridRows == grid.rows) c.id to c.at
        else {
            val col = (c.at.col * sx).roundToInt()
            val row = (c.at.row * sy).roundToInt()
            val w = max(1, ((c.at.col + c.at.w) * sx).roundToInt() - col)
            val h = max(1, ((c.at.row + c.at.h) * sy).roundToInt() - row)
            c.id to Cell(col, row, w, h)
        }
    }
    val inside = cells.values.all { it.col >= 0 && it.row >= 0 && it.col + it.w <= grid.cols && it.row + it.h <= grid.rows }
    val bigEnough = all.all { c -> val m = minSize(c); cells[c.id]!!.let { it.w >= m.first && it.h >= m.second } }
    val list = cells.values.toList()
    val noOverlap = list.indices.all { i -> (i + 1 until list.size).none { j -> list[i].overlaps(list[j]) } }
    return Placement(cells, inside && bigEnough && noOverlap)
}

/**
 * How a layout goes onto this screen (HANDOFF §5; reflow is an open question there, this is the tech decision):
 *  1. the device grid equals the authoring grid: as authored;
 *  2. otherwise keep the authoring grid and resize its cells to the screen, if every cell stays >= SQUEEZE_MIN dp
 *     (a 14-column layout on an 800 dp phone gets ~46 dp cells: still playable, nothing moves);
 *  3. otherwise move the cells onto the device grid (place/3) and report whether it still fits.
 */
data class Fitted(val grid: Grid, val placement: Placement)

const val SQUEEZE_MIN = 40f

fun fit(layout: Layout, page: Page, wDp: Float, hDp: Float): Fitted {
    val device = Grid.forScreen(wDp, hDp)
    if (device.cols != layout.gridCols || device.rows != layout.gridRows) {
        val uw = wDp - 2 * Grid.GUTTER
        val uh = hDp - 2 * Grid.INSET
        val cw = (uw - (layout.gridCols - 1) * Grid.GAP) / layout.gridCols
        val ch = (uh - (layout.gridRows - 1) * Grid.GAP) / layout.gridRows
        if (cw >= SQUEEZE_MIN && ch >= SQUEEZE_MIN) {
            val squeezed = Grid(layout.gridCols, layout.gridRows, cw, ch, Grid.GAP, Grid.GUTTER, Grid.INSET)
            return Fitted(squeezed, place(layout, page, squeezed))
        }
    }
    return Fitted(device, place(layout, page, device))
}
