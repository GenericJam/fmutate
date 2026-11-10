package com.example.fmutate_app.fmutate

import android.graphics.Paint
import android.graphics.Typeface
import android.view.HapticFeedbackConstants
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/*
 * Edit in place, home-screen style (HANDOFF §5; boards Edit-Drag, Edit-Add). While the instrument is in edit
 * mode its controls send nothing; this draws the grid, the pill (page name, ‹ ›, + Page, Done), the selection
 * (lime ring, corner handles, size badge), drags (dashed ghost at the origin, lime or red footprint, edge-hold
 * to move a control to the next page) and the "Add here" menu, and proposes every edit to Elixir:
 *
 *   send("edit_move", {id, col, row}) | send("edit_resize", {id, col, row, w, h}) | send("edit_to_page", {id, dir})
 *   send("edit_cell", {page, col, row}) | send("edit_add", {type, page, col, row}) | send("edit_add_close")
 *   send("edit_add_page") | send("edit_open", {id, sub, len}) | send("edit_done") | send("page", {id})
 *
 * Elixir (FMutate.Editor, FMutate.LayoutEdit) owns the rules and the layout: it saves the edit and sends the new
 * layout back as the view's prop. Until then a dropped control is drawn where it was dropped (`pending`).
 * Coordinates are cells of the layout's own grid: edit mode always shows that grid, fitted to the screen.
 */

private object E {
    val bgDeep = Color(0xFF0E0D12)
    val cell = Color(0xFF16141D)
    val cellLine = Color(0xFF24212E)
    val fm = Color(0xFFC6F24E)
    val danger = Color(0xFFFF9A7A)
    val raisedHi = Color(0xFF2A2636)
    val faint = Color(0xFF6B6580)
    val text = Color(0xFFF3EFF8)
    val paper = Color(0xFFF3EFF8)
    val paper2 = Color(0xFFE2DCEB)
    val ink = Color(0xFF14121A)
    val ink2 = Color(0xFF5E5870)
    val disabled = Color(0xFF8F89A3)
    val needs = Color(0xFFB4472F)
}

private const val SLOP_DP = 8f
private const val HANDLE_DP = 22f
const val EDGE_HOLD_MS = 500L

/** Grid maths for edit mode. Pure, so it is unit-testable on the JVM. */
object EditGrid {
    /** Edit mode always shows the layout's own grid, its cells sized to fill this screen. */
    fun authoring(layout: Layout, wDp: Float, hDp: Float): Grid {
        val uw = wDp - 2 * Grid.GUTTER
        val uh = hDp - 2 * Grid.INSET
        val cw = (uw - (layout.gridCols - 1) * Grid.GAP) / layout.gridCols
        val ch = (uh - (layout.gridRows - 1) * Grid.GAP) / layout.gridRows
        return Grid(layout.gridCols, layout.gridRows, cw, ch, Grid.GAP, Grid.GUTTER, Grid.INSET)
    }

    /** The cell under a point, or null outside the grid (gaps count as the cell before them). */
    fun cellAt(g: Grid, x: Float, y: Float): Pair<Int, Int>? {
        val col = floor((x - g.left) / (g.cellW + g.gap)).toInt()
        val row = floor((y - g.top) / (g.cellH + g.gap)).toInt()
        return if (x >= g.left && y >= g.top && col in 0 until g.cols && row in 0 until g.rows) col to row else null
    }

    /** Where a w×h control lands with its top-left corner at (x, y): the nearest cell, kept on the grid. */
    fun snap(g: Grid, x: Float, y: Float, w: Int, h: Int): Cell {
        val col = ((x - g.left) / (g.cellW + g.gap)).roundToInt().coerceIn(0, max(0, g.cols - w))
        val row = ((y - g.top) / (g.cellH + g.gap)).roundToInt().coerceIn(0, max(0, g.rows - h))
        return Cell(col, row, w, h)
    }

    /**
     * Resize from a corner (0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right) towards the cell
     * (col, row): the opposite corner stays put, whole cells only, never below `min`, never off the grid.
     */
    fun resize(g: Grid, from: Cell, corner: Int, col: Int, row: Int, min: Pair<Int, Int>): Cell {
        val c = col.coerceIn(0, g.cols - 1)
        val r = row.coerceIn(0, g.rows - 1)
        var left = from.col
        var top = from.row
        var right = from.col + from.w - 1
        var bottom = from.row + from.h - 1
        if (corner == 0 || corner == 2) left = min(c, right - min.first + 1) else right = max(c, left + min.first - 1)
        if (corner == 0 || corner == 1) top = min(r, bottom - min.second + 1) else bottom = max(r, top + min.second - 1)
        left = left.coerceAtLeast(0)
        top = top.coerceAtLeast(0)
        right = right.coerceAtMost(g.cols - 1)
        bottom = bottom.coerceAtMost(g.rows - 1)
        return Cell(left, top, right - left + 1, bottom - top + 1)
    }

    /** Inside the grid and clear of every other cell. */
    fun free(target: Cell, others: Collection<Cell>, cols: Int, rows: Int): Boolean =
        target.col >= 0 && target.row >= 0 && target.col + target.w <= cols && target.row + target.h <= rows &&
            others.none { it.overlaps(target) }

    /**
     * The cells a control may not take (FMutate.LayoutEdit's rule): a page control must clear its page and the
     * dock; a dock control must clear the dock and every page, since it is drawn on all of them.
     */
    fun others(layout: Layout, page: Page, id: String, cellOf: (Control) -> Cell): List<Cell> {
        val inDock = layout.dock.any { it.id == id }
        val pool = if (inDock) layout.dock + layout.pages.flatMap { it.controls } else layout.dock + page.controls
        return pool.filter { it.id != id }.map(cellOf)
    }
}

/** How a layout goes onto the screen in edit mode: its own grid, positions as authored. */
fun editFit(layout: Layout, page: Page, wDp: Float, hDp: Float): Fitted =
    Fitted(EditGrid.authoring(layout, wDp, hDp), Placement((layout.dock + page.controls).associate { it.id to it.at }, true))

/** "Add here" (Edit-Add.dc.html), as FMutate.Editor sends it: the tapped cell, its free run, what fits. */
data class AddMenu(val page: String, val col: Int, val row: Int, val roomW: Int, val roomH: Int, val items: List<Item>) {
    data class Item(val type: String, val name: String, val fits: Boolean, val size: String)

    companion object {
        fun parse(json: String?): AddMenu? {
            if (json.isNullOrEmpty()) return null
            return runCatching {
                val o = JSONObject(json)
                val room = o.getJSONArray("room")
                val items = o.getJSONArray("items")
                AddMenu(
                    o.getString("page"), o.getInt("col"), o.getInt("row"), room.getInt(0), room.getInt(1),
                    (0 until items.length()).map { i ->
                        val it = items.getJSONObject(i)
                        Item(it.getString("type"), it.getString("name"), it.getBoolean("fits"), it.getString("size"))
                    },
                )
            }.getOrNull()
        }
    }
}

/** What edit mode needs from the surface, rebuilt each composition. */
class EditCtx(
    val layout: Layout,
    val page: Page,
    val pageIndex: Int,
    val grid: Grid,
    val wDp: Float,
    val hDp: Float,
    val addMenu: AddMenu?,
    val scope: CoroutineScope,
    val emit: (String, Map<String, Any>) -> Unit,
    val setPage: (Int) -> Unit,
    val haptic: (Int) -> Unit,
) {
    val controls get() = layout.dock + page.controls
}

class EditMode {
    private sealed class Op(val pointer: Long) {
        class Press(pointer: Long, val control: Control?, val start: Offset) : Op(pointer)
        class Drag(pointer: Long, val control: Control, val origin: Cell, val grab: Offset) : Op(pointer) {
            var finger = Offset.Zero
            var target = origin
            var ok = true
            var edgeDir = 0
            var edgeSince = 0L
        }
        class Resize(pointer: Long, val control: Control, val origin: Cell, val corner: Int) : Op(pointer) {
            var target = origin
            var ok = true
        }
        class Swallow(pointer: Long) : Op(pointer)
    }

    var selected by mutableStateOf<String?>(null)
    private var op by mutableStateOf<Op?>(null)
    private var frame by mutableIntStateOf(0)                 // bumps on every edit-mode move: redraw the overlay
    private val pending = mutableStateMapOf<String, Cell>()   // proposed cells, until the layout prop catches up
    private val ink = Ink()

    /** A new layout arrived from Elixir: it has the edits; drop the proposals. */
    fun layoutChanged() {
        pending.clear()
    }

    /** Leaving edit mode. */
    fun reset() {
        op = null
        selected = null
        pending.clear()
    }

    /** Where to draw a control: its proposed cell while the edit is on its way, else null. */
    fun override(id: String): Cell? = pending[id]

    /** The control being dragged is drawn by the overlay, not at its origin. */
    fun hidden(id: String): Boolean = (op as? Op.Drag)?.control?.id == id

    private fun cellOf(ctx: EditCtx, c: Control): Cell = pending[c.id] ?: c.at

    private fun rectOf(ctx: EditCtx, c: Control): Grid.Rect = ctx.grid.rect(cellOf(ctx, c))

    private fun resizable(c: Control) = c.type != "menu"

    // ── touch ─────────────────────────────────────────────────────────────

    fun down(ctx: EditCtx, pointer: Long, p: Offset) {
        if (op != null) return // one finger edits; others are ignored until it lifts
        pill(ctx).firstOrNull { it.action != null && it.rect.contains(p.x, p.y) }?.let { b ->
            b.action!!.invoke()
            op = Op.Swallow(pointer)
            return
        }
        ctx.addMenu?.let { menu ->
            val box = menuBox(ctx, menu)
            if (box.rect.contains(p.x, p.y)) {
                box.items.firstOrNull { (_, r) -> r.contains(p.x, p.y) }?.let { (item, _) ->
                    if (item.fits) {
                        ctx.haptic(HapticFeedbackConstants.VIRTUAL_KEY)
                        ctx.emit("edit_add", mapOf("type" to item.type, "page" to menu.page, "col" to menu.col, "row" to menu.row))
                    }
                }
            } else ctx.emit("edit_add_close", emptyMap())
            op = Op.Swallow(pointer)
            return
        }
        val sel = ctx.controls.firstOrNull { it.id == selected }
        if (sel != null && resizable(sel)) {
            val r = rectOf(ctx, sel)
            val corners = listOf(Offset(r.x, r.y), Offset(r.x + r.w, r.y), Offset(r.x, r.y + r.h), Offset(r.x + r.w, r.y + r.h))
            val i = corners.indexOfFirst { (it - p).getDistance() < HANDLE_DP }
            if (i >= 0) {
                op = Op.Resize(pointer, sel, cellOf(ctx, sel), i)
                ctx.haptic(HapticFeedbackConstants.CLOCK_TICK)
                return
            }
        }
        val c = ctx.controls.lastOrNull { rectOf(ctx, it).contains(p.x, p.y) }
        op = Op.Press(pointer, c, p)
    }

    fun move(ctx: EditCtx, pointer: Long, p: Offset, now: Long) {
        val o = op ?: return
        if (o.pointer != pointer) return
        when (o) {
            is Op.Press -> {
                val c = o.control ?: return
                if ((p - o.start).getDistance() < SLOP_DP) return
                val r = rectOf(ctx, c)
                val d = Op.Drag(pointer, c, cellOf(ctx, c), o.start - Offset(r.x, r.y))
                d.finger = p
                selected = c.id
                op = d
                ctx.haptic(HapticFeedbackConstants.LONG_PRESS)
                dragTo(ctx, d, p, now)
            }
            is Op.Drag -> dragTo(ctx, o, p, now)
            is Op.Resize -> {
                val (col, row) = EditGrid.cellAt(ctx.grid, p.x.coerceIn(ctx.grid.left, ctx.wDp - ctx.grid.left - 1), p.y.coerceIn(ctx.grid.top, ctx.hDp - ctx.grid.top - 1))
                    ?: return
                val t = EditGrid.resize(ctx.grid, o.origin, o.corner, col, row, minSize(o.control))
                if (t != o.target) ctx.haptic(HapticFeedbackConstants.CLOCK_TICK)
                o.target = t
                o.ok = EditGrid.free(t, EditGrid.others(ctx.layout, ctx.page, o.control.id) { cellOf(ctx, it) }, ctx.grid.cols, ctx.grid.rows)
            }
            is Op.Swallow -> {}
        }
        frame++
    }

    private fun dragTo(ctx: EditCtx, d: Op.Drag, p: Offset, now: Long) {
        d.finger = p
        val tl = p - d.grab
        val t = EditGrid.snap(ctx.grid, tl.x, tl.y, d.origin.w, d.origin.h)
        if (t != d.target) ctx.haptic(HapticFeedbackConstants.CLOCK_TICK)
        d.target = t
        d.ok = EditGrid.free(t, EditGrid.others(ctx.layout, ctx.page, d.control.id) { cellOf(ctx, it) }, ctx.grid.cols, ctx.grid.rows)
        // the side edges: hold there to move the control to the previous / next page (dock controls stay)
        val inDock = ctx.layout.dock.any { it.id == d.control.id }
        val dir = when {
            inDock -> 0
            p.x < Grid.GUTTER -> -1
            p.x > ctx.wDp - Grid.GUTTER -> 1
            else -> 0
        }
        if (dir != d.edgeDir) {
            d.edgeDir = dir
            d.edgeSince = now
            if (dir != 0) ctx.scope.launch {
                while (true) {
                    delay(16)
                    if (op !== d || d.edgeDir != dir) return@launch
                    frame++
                    if (System.currentTimeMillis() - d.edgeSince >= EDGE_HOLD_MS) break
                }
                ctx.haptic(HapticFeedbackConstants.LONG_PRESS)
                ctx.emit("edit_to_page", mapOf("id" to d.control.id, "dir" to dir))
                op = Op.Swallow(d.pointer)
            }
        }
    }

    fun up(ctx: EditCtx, pointer: Long, p: Offset) {
        val o = op ?: return
        if (o.pointer != pointer) return
        op = null
        when (o) {
            is Op.Press -> {
                val c = o.control
                if (c != null) {
                    if (selected == c.id) open(ctx, c, p) else selected = c.id
                    ctx.haptic(HapticFeedbackConstants.VIRTUAL_KEY)
                } else {
                    selected = null
                    EditGrid.cellAt(ctx.grid, p.x, p.y)?.let { (col, row) ->
                        ctx.emit("edit_cell", mapOf("page" to ctx.page.id, "col" to col, "row" to row))
                    }
                }
            }
            is Op.Drag -> if (o.edgeDir == 0 && o.ok && o.target != o.origin) {
                // drop on lime: propose it; drop on red: it snaps back (nothing to send)
                pending[o.control.id] = o.target
                ctx.emit("edit_move", mapOf("id" to o.control.id, "col" to o.target.col, "row" to o.target.row))
            }
            is Op.Resize -> if (o.ok && o.target != o.origin) {
                pending[o.control.id] = o.target
                val t = o.target
                ctx.emit("edit_resize", mapOf("id" to o.control.id, "col" to t.col, "row" to t.row, "w" to t.w, "h" to t.h))
            }
            is Op.Swallow -> {}
        }
        frame++
    }

    // tap on the selected control: its sheet (a pad grid opens the pad under the finger)
    private fun open(ctx: EditCtx, c: Control, p: Offset) {
        val r = rectOf(ctx, c)
        val payload = mutableMapOf<String, Any>("id" to c.id, "len" to (if (c.vertical) r.h else r.w).roundToInt())
        if (c.type == "pad_grid" && c.padCols > 0 && c.padRows > 0) {
            val col = ((p.x - r.x) / r.w * c.padCols).toInt().coerceIn(0, c.padCols - 1)
            val row = ((p.y - r.y) / r.h * c.padRows).toInt().coerceIn(0, c.padRows - 1)
            payload["sub"] = (row * c.padCols + col).coerceAtMost(max(0, c.pads.size - 1))
        }
        ctx.emit("edit_open", payload)
    }

    // ── the pill ──────────────────────────────────────────────────────────

    private class PillPart(val text: String, val rect: Grid.Rect, val style: Int, val action: (() -> Unit)?)

    // style: 0 plain text, 1 mono text, 2 light button, 3 dark "Done" button, 4 arrow
    private fun pill(ctx: EditCtx): List<PillPart> {
        val n = ctx.layout.pages.size
        val parts = listOf(
            Triple("Editing", 0, null),
            Triple("‹", 4, { if (ctx.pageIndex > 0) ctx.setPage(ctx.pageIndex - 1) }),
            Triple("${ctx.page.name} · ${ctx.pageIndex + 1}/$n", 1, null),
            Triple("›", 4, { if (ctx.pageIndex < n - 1) ctx.setPage(ctx.pageIndex + 1) }),
            Triple("+ Page", 2, { ctx.emit("edit_add_page", emptyMap()) }),
            Triple("Done", 3, { ctx.emit("edit_done", emptyMap()) }),
        )
        val widths = parts.map { (t, s, _) ->
            when (s) {
                4 -> 32f
                2, 3 -> ink.width(t, 13f, true, false) + 26f
                1 -> ink.width(t, 12f, true, true) + 4f
                else -> ink.width(t, 13f, true, false) + 4f
            }
        }
        val gap = 6f
        val total = 14f + widths.sum() + gap * (parts.size - 1) + 4f
        var x = ctx.wDp / 2 - total / 2 + 14f
        // at the top, unless the control being edited is under it: then at the bottom. Only the pill's buttons
        // take touches, so a control under its text can still be tapped (and selecting it moves the pill).
        val top = Grid.Rect(ctx.wDp / 2 - total / 2, 6f, total, 44f)
        val busy = when (val o = op) {
            is Op.Drag -> ctx.grid.rect(o.target)
            is Op.Resize -> ctx.grid.rect(o.target)
            else -> ctx.controls.firstOrNull { it.id == selected }?.let { rectOf(ctx, it) }
        }
        val clash = busy != null && busy.x < top.x + top.w && top.x < busy.x + busy.w && busy.y < top.y + top.h && top.y < busy.y + busy.h
        val y = if (clash) ctx.hDp - 50f else 6f
        return parts.mapIndexed { i, (t, s, a) ->
            val r = Grid.Rect(x, y + 4, widths[i], 36f)
            x += widths[i] + gap
            PillPart(t, r, s, a)
        }.let { listOf(PillPart("", Grid.Rect(ctx.wDp / 2 - total / 2, y, total, 44f), -1, null)) + it }
    }

    // ── the "Add here" menu ───────────────────────────────────────────────

    private class MenuBox(val rect: Grid.Rect, val items: List<Pair<AddMenu.Item, Grid.Rect>>)

    private fun menuBox(ctx: EditCtx, m: AddMenu): MenuBox {
        val w = 300f
        val rowH = 28f
        val h = 12f + 26f + m.items.size * (rowH + 2f) + 10f
        val cell = ctx.grid.rect(Cell(m.col, m.row, 1, 1))
        var x = if (cell.x + cell.w + 12 + w <= ctx.wDp - 8) cell.x + cell.w + 12 else cell.x - 12 - w
        x = x.coerceIn(8f, max(8f, ctx.wDp - w - 8f))
        val y = (cell.y - 20f).coerceIn(8f, max(8f, ctx.hDp - h - 8f))
        val items = m.items.mapIndexed { i, it -> it to Grid.Rect(x + 12, y + 12 + 26 + i * (rowH + 2), w - 24, rowH) }
        return MenuBox(Grid.Rect(x, y, w, h), items)
    }

    // ── drawing ───────────────────────────────────────────────────────────

    /** Under the controls: the deep background and the grid. */
    fun drawUnder(s: DrawScope, ctx: EditCtx, d: Float) {
        s.drawRect(E.bgDeep)
        val g = ctx.grid
        for (row in 0 until g.rows) for (col in 0 until g.cols) {
            val r = g.rect(Cell(col, row, 1, 1))
            s.drawRoundRect(E.cell, Offset(r.x * d, r.y * d), Size(r.w * d, r.h * d), CornerRadius(8 * d))
            s.drawRoundRect(E.cellLine, Offset(r.x * d, r.y * d), Size(r.w * d, r.h * d), CornerRadius(8 * d), style = Stroke(1 * d))
        }
    }

    /** Over the controls: selection, drag, pill, menu. */
    fun drawOver(s: DrawScope, ctx: EditCtx, d: Float) {
        if (frame < 0) return // read so moves redraw
        val g = ctx.grid
        fun rr(r: Grid.Rect, color: Color, radius: Float, stroke: Float = 0f, dash: Boolean = false) {
            val style = if (stroke > 0) Stroke(stroke * d, pathEffect = if (dash) PathEffect.dashPathEffect(floatArrayOf(6 * d, 5 * d)) else null) else null
            if (style != null) s.drawRoundRect(color, Offset(r.x * d, r.y * d), Size(r.w * d, r.h * d), CornerRadius(radius * d), style = style)
            else s.drawRoundRect(color, Offset(r.x * d, r.y * d), Size(r.w * d, r.h * d), CornerRadius(radius * d))
        }
        fun footprint(cell: Cell, ok: Boolean) {
            val fill = if (ok) E.fm.copy(alpha = 0.28f) else E.danger.copy(alpha = 0.45f)
            val line = if (ok) E.fm else E.danger
            for (row in cell.row until cell.row + cell.h) for (col in cell.col until cell.col + cell.w) {
                val r = g.rect(Cell(col, row, 1, 1))
                rr(r, fill, 8f)
                rr(r, line, 8f, 1f)
            }
        }

        // the cell "Add here" is for
        ctx.addMenu?.let { m ->
            val r = g.rect(Cell(m.col, m.row, 1, 1))
            rr(r, E.paper, 8f)
            ink.text(s, "+", r.cx, r.cy, 26f, E.ink, bold = false, mono = false, d = d)
        }

        when (val o = op) {
            is Op.Drag -> {
                footprint(o.target, o.ok)
                val origin = g.rect(o.origin)
                rr(origin, E.faint, 10f, 2f, dash = true)
                ink.text(s, label(o.control), origin.x + 8, origin.y + 14, 11f, E.faint, bold = true, mono = false, d = d, left = true)
                val tl = o.finger - o.grab
                // lifted a little up and right of the finger, so the footprint under it shows (Edit-Drag board)
                val box = Grid.Rect(tl.x + 6, tl.y - 6, origin.w, origin.h)
                rr(box, E.raisedHi, 10f)
                rr(box, E.fm, 10f, 2f)
                ink.text(s, label(o.control), box.x + 8, box.y + 14, 11f, E.text, bold = true, mono = false, d = d, left = true)
                s.drawCircle(E.paper.copy(alpha = 0.35f), 20 * d, Offset(o.finger.x * d, o.finger.y * d))
                if (!o.ok && o.edgeDir == 0) {
                    val over = ctx.controls.firstOrNull { it.id != o.control.id && cellOf(ctx, it).overlaps(o.target) }
                    val tip = if (over != null) "Overlaps ${label(over).ifEmpty { typeName(over.type) }}" else "Off the grid"
                    val t = g.rect(o.target)
                    chip(s, tip, t.x + 4, t.y + t.h + 6, E.danger, E.ink, d)
                }
                if (o.edgeDir != 0) {
                    val k = ((System.currentTimeMillis() - o.edgeSince).toFloat() / EDGE_HOLD_MS).coerceIn(0f, 1f)
                    val x = if (o.edgeDir < 0) 0f else ctx.wDp - 8f
                    rr(Grid.Rect(x, 0f, 8f, ctx.hDp), E.fm.copy(alpha = 0.25f), 4f)
                    rr(Grid.Rect(x, ctx.hDp * (1 - k), 8f, ctx.hDp * k), E.fm, 4f)
                    val n = ctx.pageIndex + o.edgeDir
                    val name = ctx.layout.pages.getOrNull(n)?.name ?: "a new page"
                    chip(s, if (o.edgeDir < 0) "‹ to $name" else "to $name ›", if (o.edgeDir < 0) 16f else ctx.wDp - 160f, ctx.hDp / 2 - 12, E.fm, E.ink, d)
                }
            }
            is Op.Resize -> {
                footprint(o.target, o.ok)
                val t = g.rect(o.target)
                rr(t, if (o.ok) E.fm else E.danger, 10f, 2f)
                chip(s, "${o.target.w}×${o.target.h}", t.x + 6, t.y + 6, if (o.ok) E.fm else E.danger, E.ink, d)
            }
            else -> {}
        }

        // the selection: lime ring, four handles, size badge
        val sel = ctx.controls.firstOrNull { it.id == selected }
        if (sel != null && op !is Op.Drag && op !is Op.Resize) {
            val r = rectOf(ctx, sel)
            rr(r, E.fm, 10f, 2f)
            if (resizable(sel)) for ((x, y) in listOf(r.x to r.y, r.x + r.w to r.y, r.x to r.y + r.h, r.x + r.w to r.y + r.h)) {
                s.drawCircle(E.bgDeep, 12 * d, Offset(x * d, y * d))
                s.drawCircle(E.fm, 9 * d, Offset(x * d, y * d))
            }
            val cell = cellOf(ctx, sel)
            val what = if (sel.type == "menu") "creature · moves, never deleted" else "${typeName(sel.type).lowercase()} · ${cell.w}×${cell.h} · tap for bindings"
            val bw = ink.width(what, 11f, true, true) + 16f
            val bx = (r.x + 18).coerceAtMost(ctx.wDp - bw - 8)
            val by = if (bx < r.x + 18 && r.y > 40) r.y - 28 else r.y + 6
            chip(s, what, bx, by, E.fm, E.ink, d, mono = true)
        }

        // the pill
        val parts = pill(ctx)
        val bg = parts.first().rect
        rr(bg, E.paper, 22f)
        for (p in parts.drop(1)) {
            val r = p.rect
            when (p.style) {
                0 -> ink.text(s, p.text, r.cx, r.cy, 13f, E.ink, bold = true, mono = false, d = d)
                1 -> ink.text(s, p.text, r.cx, r.cy, 12f, E.ink, bold = true, mono = true, d = d)
                2 -> { rr(r, E.paper2, 18f); ink.text(s, p.text, r.cx, r.cy, 13f, E.ink, bold = true, mono = false, d = d) }
                3 -> { rr(r, E.ink, 18f); ink.text(s, p.text, r.cx, r.cy, 13f, E.fm, bold = true, mono = false, d = d) }
                4 -> ink.text(s, p.text, r.cx, r.cy, 16f, E.ink, bold = true, mono = false, d = d)
            }
        }

        // "Add here"
        ctx.addMenu?.let { m ->
            val box = menuBox(ctx, m)
            rr(box.rect, E.paper, 18f)
            ink.text(s, "Add here", box.rect.x + 16, box.rect.y + 24, 14f, E.ink, bold = true, mono = false, d = d, left = true)
            ink.text(s, "room: ${m.roomW} wide × ${m.roomH} tall", box.rect.x + box.rect.w - 16, box.rect.y + 24, 11f, E.ink2, bold = false, mono = true, d = d, right = true)
            for ((item, r) in box.items) {
                if (item.fits) rr(r, E.paper2, 9f)
                ink.text(s, item.name, r.x + 10, r.cy, 13f, if (item.fits) E.ink else E.disabled, bold = true, mono = false, d = d, left = true)
                ink.text(s, if (item.fits) item.size + " +" else "needs ${item.size}", r.x + r.w - 10, r.cy, 11f, if (item.fits) E.ink2 else E.needs, bold = false, mono = true, d = d, right = true)
            }
        }
    }

    private fun label(c: Control) = c.label.ifEmpty { typeName(c.type) }

    private fun typeName(t: String) = when (t) {
        "pad_grid" -> "Pads"
        "xy_pad" -> "XY pad"
        "keyboard" -> "Keyboard"
        "strum" -> "Strum"
        "screen" -> "Screen"
        "menu" -> "Creature"
        "page_switcher" -> "Pages"
        else -> t.replaceFirstChar { it.uppercase() }
    }

    private fun chip(s: DrawScope, t: String, x: Float, y: Float, bg: Color, fg: Color, d: Float, mono: Boolean = false) {
        val w = ink.width(t, 11f, true, mono) + 16f
        s.drawRoundRect(bg, Offset(x * d, y * d), Size(w * d, 22 * d), CornerRadius(8 * d))
        ink.text(s, t, x + 8, y + 11, 11f, fg, bold = true, mono = mono, d = d, left = true)
    }
}

/** Draws a short message over the surface (FMutate.Editor's toasts: why an edit didn't happen, etc.). */
fun drawToast(s: DrawScope, text: String, wDp: Float, hDp: Float, d: Float) {
    if (text.isEmpty()) return
    val ink = Ink()
    val w = ink.width(text, 13f, true, false) + 32f
    val x = wDp / 2 - w / 2
    val y = hDp - 64f
    s.drawRoundRect(E.paper, Offset(x * d, y * d), Size(w * d, 40 * d), CornerRadius(20 * d))
    ink.text(s, text, wDp / 2, y + 20, 13f, E.ink, bold = true, mono = false, d = d)
}

/** Text on the native canvas (dp in, px out). */
private class Ink {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val sans = Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
    private val sansRegular = Typeface.create(Typeface.SANS_SERIF, Typeface.NORMAL)
    private val mono = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
    private val monoRegular = Typeface.create(Typeface.MONOSPACE, Typeface.NORMAL)

    private fun set(size: Float, bold: Boolean, mono: Boolean, d: Float) {
        paint.textSize = size * d
        paint.typeface = if (mono) (if (bold) this.mono else monoRegular) else (if (bold) sans else sansRegular)
    }

    fun width(t: String, size: Float, bold: Boolean, mono: Boolean): Float {
        set(size, bold, mono, 1f)
        return paint.measureText(t)
    }

    fun text(s: DrawScope, t: String, x: Float, cy: Float, size: Float, color: Color, bold: Boolean, mono: Boolean, d: Float, left: Boolean = false, right: Boolean = false) {
        set(size, bold, mono, d)
        paint.color = color.toArgb()
        paint.textAlign = when {
            left -> Paint.Align.LEFT
            right -> Paint.Align.RIGHT
            else -> Paint.Align.CENTER
        }
        val fm = paint.fontMetrics
        val baseline = cy * d - (fm.ascent + fm.descent) / 2
        s.drawIntoCanvas { it.nativeCanvas.drawText(t, x * d, baseline, paint) }
    }
}
