import UIKit

// Edit in place, home-screen style (HANDOFF §5; boards Edit-Drag, Edit-Add): EditMode.kt. While the instrument
// is in edit mode its controls send nothing; this draws the grid, the pill (page name, ‹ ›, + Page, Done), the
// selection (lime ring, corner handles, size badge), drags (dashed ghost at the origin, lime or red footprint,
// edge-hold to move a control to the next page) and the "Add here" menu, and proposes every edit to Elixir:
//
//   send("edit_move", {id, col, row}) | send("edit_resize", {id, col, row, w, h}) | send("edit_to_page", {id, dir})
//   send("edit_cell", {page, col, row}) | send("edit_add", {type, page, col, row}) | send("edit_add_close")
//   send("edit_add_page") | send("edit_open", {id, sub, len}) | send("edit_done") | send("page", {id})
//
// Elixir (FMutate.Editor, FMutate.LayoutEdit) owns the rules and the layout: it saves the edit and sends the new
// layout back as the view's prop. Until then a dropped control is drawn where it was dropped (`pending`).
// Coordinates are cells of the layout's own grid: edit mode always shows that grid, fitted to the screen.
//
// iOS: Compose redraws whatever read the edit state; here the surface passes two hooks in FMEditCtx: `frame`
// (redraw the edit overlay) and `placed` (a control's cell changed or it was hidden/shown: the control layers).

private enum FME {
    static let bgDeep = fmColor(0xFF0E0D12)
    static let cell = fmColor(0xFF16141D)
    static let cellLine = fmColor(0xFF24212E)
    static let fm = fmColor(0xFFC6F24E)
    static let danger = fmColor(0xFFFF9A7A)
    static let raisedHi = fmColor(0xFF2A2636)
    static let faint = fmColor(0xFF6B6580)
    static let text = fmColor(0xFFF3EFF8)
    static let paper = fmColor(0xFFF3EFF8)
    static let paper2 = fmColor(0xFFE2DCEB)
    static let ink = fmColor(0xFF14121A)
    static let ink2 = fmColor(0xFF5E5870)
    static let disabled = fmColor(0xFF8F89A3)
    static let needs = fmColor(0xFFB4472F)
    // Kotlin's `.copy(alpha = …)` variants, made once
    static let fmFill = fmColor(0xFFC6F24E, alpha: 0.28)
    static let dangerFill = fmColor(0xFFFF9A7A, alpha: 0.45)
    static let fingerDot = fmColor(0xFFF3EFF8, alpha: 0.35)
    static let edgeTrack = fmColor(0xFFC6F24E, alpha: 0.25)
}

private let SLOP_DP: CGFloat = 8
private let HANDLE_DP: CGFloat = 22
let FM_EDGE_HOLD_MS: Int64 = 500

/// Grid maths for edit mode (EditGrid; EditGridTest.kt pins it). Pure.
enum FMEditGrid {
    /// Edit mode always shows the layout's own grid, its cells sized to fill this screen.
    static func authoring(_ layout: FMLayout, _ wDp: CGFloat, _ hDp: CGFloat) -> FMGrid {
        let uw = wDp - 2 * FMGrid.GUTTER
        let uh = hDp - 2 * FMGrid.INSET
        let cw = (uw - CGFloat(layout.gridCols - 1) * FMGrid.GAP) / CGFloat(layout.gridCols)
        let ch = (uh - CGFloat(layout.gridRows - 1) * FMGrid.GAP) / CGFloat(layout.gridRows)
        return FMGrid(cols: layout.gridCols, rows: layout.gridRows, cellW: cw, cellH: ch, gap: FMGrid.GAP,
                      left: FMGrid.GUTTER, top: FMGrid.INSET)
    }

    /// The cell under a point, or nil outside the grid (gaps count as the cell before them).
    static func cellAt(_ g: FMGrid, _ x: CGFloat, _ y: CGFloat) -> (Int, Int)? {
        guard x >= g.left, y >= g.top else { return nil }
        let col = Int(((x - g.left) / (g.cellW + g.gap)).rounded(.down))
        let row = Int(((y - g.top) / (g.cellH + g.gap)).rounded(.down))
        return col < g.cols && row < g.rows ? (col, row) : nil
    }

    /// Where a w×h control lands with its top-left corner at (x, y): the nearest cell, kept on the grid.
    static func snap(_ g: FMGrid, _ x: CGFloat, _ y: CGFloat, _ w: Int, _ h: Int) -> FMCell {
        let col = fmClamp(fmRound((x - g.left) / (g.cellW + g.gap)), 0, max(0, g.cols - w))
        let row = fmClamp(fmRound((y - g.top) / (g.cellH + g.gap)), 0, max(0, g.rows - h))
        return FMCell(col: col, row: row, w: w, h: h)
    }

    /// Resize from a corner (0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right) towards the cell
    /// (col, row): the opposite corner stays put, whole cells only, never below `min`, never off the grid.
    static func resize(_ g: FMGrid, _ from: FMCell, _ corner: Int, _ col: Int, _ row: Int, _ min: (Int, Int)) -> FMCell {
        let c = fmClamp(col, 0, g.cols - 1)
        let r = fmClamp(row, 0, g.rows - 1)
        var left = from.col
        var top = from.row
        var right = from.col + from.w - 1
        var bottom = from.row + from.h - 1
        if corner == 0 || corner == 2 { left = Swift.min(c, right - min.0 + 1) } else { right = Swift.max(c, left + min.0 - 1) }
        if corner == 0 || corner == 1 { top = Swift.min(r, bottom - min.1 + 1) } else { bottom = Swift.max(r, top + min.1 - 1) }
        left = Swift.max(left, 0)
        top = Swift.max(top, 0)
        right = Swift.min(right, g.cols - 1)
        bottom = Swift.min(bottom, g.rows - 1)
        return FMCell(col: left, row: top, w: right - left + 1, h: bottom - top + 1)
    }

    /// Inside the grid and clear of every other cell.
    static func free(_ target: FMCell, _ others: [FMCell], _ cols: Int, _ rows: Int) -> Bool {
        target.col >= 0 && target.row >= 0 && target.col + target.w <= cols && target.row + target.h <= rows &&
            !others.contains { $0.overlaps(target) }
    }

    /// The cells a control may not take (FMutate.LayoutEdit's rule): a page control must clear its page and the
    /// dock; a dock control must clear the dock and every page, since it is drawn on all of them.
    static func others(_ layout: FMLayout, _ page: FMPage, _ id: String, _ cellOf: (FMControl) -> FMCell) -> [FMCell] {
        let inDock = layout.dock.contains { $0.id == id }
        let pool = inDock ? layout.dock + layout.pages.flatMap(\.controls) : layout.dock + page.controls
        return pool.filter { $0.id != id }.map(cellOf)
    }
}

/// How a layout goes onto the screen in edit mode: its own grid, positions as authored.
func fmEditFit(_ layout: FMLayout, _ page: FMPage, _ wDp: CGFloat, _ hDp: CGFloat) -> FMFitted {
    var cells: [String: FMCell] = [:]
    for c in layout.dock + page.controls { cells[c.id] = c.at }   // Kotlin's associate: the last one wins
    return FMFitted(grid: FMEditGrid.authoring(layout, wDp, hDp), placement: FMPlacement(cells: cells, fits: true))
}

/// "Add here" (Edit-Add.dc.html), as FMutate.Editor sends it: the tapped cell, its free run, what fits.
struct FMAddMenu: Equatable {
    /// `reason`: why an item that would fit can't be added here (a motion control on a phone without sensors).
    struct Item: Equatable {
        let type: String, name: String, fits: Bool, size: String
        var reason = ""
    }

    let page: String, col: Int, row: Int, roomW: Int, roomH: Int
    let items: [Item]

    /// org.json's getString/getInt/getBoolean: a missing or mistyped field drops the whole menu.
    static func parse(_ json: String?) -> FMAddMenu? {
        guard let json, !json.isEmpty, let o = fmParseJSONObject(json) else { return nil }
        func str(_ o: [String: Any], _ k: String) -> String? { o[k] as? String }
        func int(_ v: Any?) -> Int? {
            if let n = v as? NSNumber { return n.intValue }
            if let s = v as? String, let d = Double(s) { return Int(d) }
            return nil
        }
        func bool(_ v: Any?) -> Bool? {
            if let n = v as? NSNumber { return n.boolValue }
            if let s = v as? String, s == "true" || s == "false" { return s == "true" }
            return nil
        }
        guard let page = str(o, "page"), let col = int(o["col"]), let row = int(o["row"]),
              let room = o["room"] as? [Any], room.count >= 2, let rw = int(room[0]), let rh = int(room[1]),
              let raw = o["items"] as? [Any] else { return nil }
        var items: [Item] = []
        for v in raw {
            guard let i = v as? [String: Any], let type = str(i, "type"), let name = str(i, "name"),
                  let fits = bool(i["fits"]), let size = str(i, "size") else { return nil }
            items.append(Item(type: type, name: name, fits: fits, size: size, reason: str(i, "reason") ?? ""))
        }
        return FMAddMenu(page: page, col: col, row: row, roomW: rw, roomH: rh, items: items)
    }
}

/// What edit mode needs from the surface, rebuilt for each call.
struct FMEditCtx {
    let layout: FMLayout
    let page: FMPage
    let pageIndex: Int
    let grid: FMGrid
    let wDp: CGFloat
    let hDp: CGFloat
    let addMenu: FMAddMenu?
    let emit: (String, [String: Any]) -> Void
    let setPage: (Int) -> Void
    let haptic: (FMHaptic) -> Void
    let frame: () -> Void    // redraw the edit overlay
    let placed: () -> Void   // pending cells or the hidden (dragged) control changed: redraw the controls

    var controls: [FMControl] { layout.dock + page.controls }
}

final class FMEditMode {
    private class Op {
        let pointer: FMPointer
        init(_ pointer: FMPointer) { self.pointer = pointer }
    }
    private final class Press: Op {
        let control: FMControl?
        let start: CGPoint
        init(_ pointer: FMPointer, _ control: FMControl?, _ start: CGPoint) { self.control = control; self.start = start; super.init(pointer) }
    }
    private final class Drag: Op {
        let control: FMControl
        let origin: FMCell
        let grab: CGPoint
        var finger = CGPoint.zero
        var target: FMCell
        var ok = true
        var edgeDir = 0
        var edgeSince: Int64 = 0
        init(_ pointer: FMPointer, _ control: FMControl, _ origin: FMCell, _ grab: CGPoint) {
            self.control = control; self.origin = origin; self.grab = grab; target = origin; super.init(pointer)
        }
    }
    private final class Resize: Op {
        let control: FMControl
        let origin: FMCell
        let corner: Int
        var target: FMCell
        var ok = true
        init(_ pointer: FMPointer, _ control: FMControl, _ origin: FMCell, _ corner: Int) {
            self.control = control; self.origin = origin; self.corner = corner; target = origin; super.init(pointer)
        }
    }
    private final class Swallow: Op {}

    private(set) var selected: String?
    private var op: Op?
    private var pending: [String: FMCell] = [:]   // proposed cells, until the layout prop catches up
    private let ink = FMInk()

    /// A new layout arrived from Elixir: it has the edits; drop the proposals. True if there were any.
    @discardableResult
    func layoutChanged() -> Bool {
        if pending.isEmpty { return false }
        pending.removeAll()
        return true
    }

    /// Leaving edit mode.
    func reset() {
        op = nil
        selected = nil
        pending.removeAll()
    }

    /// Where to draw a control: its proposed cell while the edit is on its way, else nil.
    func override(_ id: String) -> FMCell? { pending[id] }

    /// The control being dragged is drawn by the overlay, not at its origin.
    func hidden(_ id: String) -> Bool { (op as? Drag)?.control.id == id }

    private func cellOf(_ c: FMControl) -> FMCell { pending[c.id] ?? c.at }

    private func rectOf(_ ctx: FMEditCtx, _ c: FMControl) -> FMGrid.Rect { ctx.grid.rect(cellOf(c)) }

    private func resizable(_ c: FMControl) -> Bool { c.type != "menu" }

    // MARK: touch

    func down(_ ctx: FMEditCtx, _ pointer: FMPointer, _ p: CGPoint) {
        if op != nil { return } // one finger edits; others are ignored until it lifts
        defer { ctx.frame() }
        if let b = pill(ctx).first(where: { $0.action != nil && $0.rect.contains(p.x, p.y) }) {
            b.action?()
            op = Swallow(pointer)
            return
        }
        if let menu = ctx.addMenu {
            let box = menuBox(ctx, menu)
            if box.rect.contains(p.x, p.y) {
                if let item = box.items.first(where: { $0.1.contains(p.x, p.y) })?.0, item.fits {
                    ctx.haptic(.virtualKey)
                    ctx.emit("edit_add", ["type": item.type, "page": menu.page, "col": menu.col, "row": menu.row])
                }
            } else {
                ctx.emit("edit_add_close", [:])
            }
            op = Swallow(pointer)
            return
        }
        if let sel = ctx.controls.first(where: { $0.id == selected }), resizable(sel) {
            let r = rectOf(ctx, sel)
            let corners = [CGPoint(x: r.x, y: r.y), CGPoint(x: r.x + r.w, y: r.y), CGPoint(x: r.x, y: r.y + r.h), CGPoint(x: r.x + r.w, y: r.y + r.h)]
            if let i = corners.firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < HANDLE_DP }) {
                op = Resize(pointer, sel, cellOf(sel), i)
                ctx.haptic(.clockTick)
                return
            }
        }
        let c = ctx.controls.last { rectOf(ctx, $0).contains(p.x, p.y) }
        op = Press(pointer, c, p)
    }

    func move(_ ctx: FMEditCtx, _ pointer: FMPointer, _ p: CGPoint, _ now: Int64) {
        guard let o = op, o.pointer == pointer else { return }
        switch o {
        case let o as Press:
            guard let c = o.control, hypot(p.x - o.start.x, p.y - o.start.y) >= SLOP_DP else { return }
            let r = rectOf(ctx, c)
            let d = Drag(pointer, c, cellOf(c), CGPoint(x: o.start.x - r.x, y: o.start.y - r.y))
            d.finger = p
            selected = c.id
            op = d
            ctx.haptic(.longPress)
            dragTo(ctx, d, p, now)
            ctx.placed()
        case let o as Drag:
            dragTo(ctx, o, p, now)
        case let o as Resize:
            let g = ctx.grid
            guard let cell = FMEditGrid.cellAt(g, fmClamp(p.x, g.left, ctx.wDp - g.left - 1),
                                               fmClamp(p.y, g.top, ctx.hDp - g.top - 1)) else { return }
            let t = FMEditGrid.resize(g, o.origin, o.corner, cell.0, cell.1, fmMinSize(o.control))
            if t != o.target { ctx.haptic(.clockTick) }
            o.target = t
            o.ok = FMEditGrid.free(t, FMEditGrid.others(ctx.layout, ctx.page, o.control.id, cellOf), g.cols, g.rows)
        default:
            break
        }
        ctx.frame()
    }

    private func dragTo(_ ctx: FMEditCtx, _ d: Drag, _ p: CGPoint, _ now: Int64) {
        d.finger = p
        let t = FMEditGrid.snap(ctx.grid, p.x - d.grab.x, p.y - d.grab.y, d.origin.w, d.origin.h)
        if t != d.target { ctx.haptic(.clockTick) }
        d.target = t
        d.ok = FMEditGrid.free(t, FMEditGrid.others(ctx.layout, ctx.page, d.control.id, cellOf), ctx.grid.cols, ctx.grid.rows)
        // the side edges: hold there to move the control to the previous / next page (dock controls stay)
        let inDock = ctx.layout.dock.contains { $0.id == d.control.id }
        let dir = inDock ? 0 : (p.x < FMGrid.GUTTER ? -1 : (p.x > ctx.wDp - FMGrid.GUTTER ? 1 : 0))
        if dir != d.edgeDir {
            d.edgeDir = dir
            d.edgeSince = now
            if dir != 0 { edgeHold(ctx, d, dir) }
        }
    }

    // Kotlin's 16 ms coroutine loop: redraw the hold bar until it fills, then move the control
    private func edgeHold(_ ctx: FMEditCtx, _ d: Drag, _ dir: Int) {
        fmAfter(16) { [weak self] in
            guard let self, self.op === d, d.edgeDir == dir else { return }
            ctx.frame()
            if fmNowMs() - d.edgeSince < FM_EDGE_HOLD_MS { self.edgeHold(ctx, d, dir); return }
            ctx.haptic(.longPress)
            ctx.emit("edit_to_page", ["id": d.control.id, "dir": dir])
            self.op = Swallow(d.pointer)
            ctx.placed()
            ctx.frame()
        }
    }

    func up(_ ctx: FMEditCtx, _ pointer: FMPointer, _ p: CGPoint) {
        guard let o = op, o.pointer == pointer else { return }
        op = nil
        switch o {
        case let o as Press:
            if let c = o.control {
                if selected == c.id { open(ctx, c, p) } else { selected = c.id }
                ctx.haptic(.virtualKey)
            } else {
                selected = nil
                if let cell = FMEditGrid.cellAt(ctx.grid, p.x, p.y) {
                    ctx.emit("edit_cell", ["page": ctx.page.id, "col": cell.0, "row": cell.1])
                }
            }
        case let o as Drag:
            // drop on lime: propose it; drop on red: it snaps back (nothing to send)
            if o.edgeDir == 0 && o.ok && o.target != o.origin {
                pending[o.control.id] = o.target
                ctx.emit("edit_move", ["id": o.control.id, "col": o.target.col, "row": o.target.row])
            }
            ctx.placed()
        case let o as Resize:
            if o.ok && o.target != o.origin {
                pending[o.control.id] = o.target
                let t = o.target
                ctx.emit("edit_resize", ["id": o.control.id, "col": t.col, "row": t.row, "w": t.w, "h": t.h])
                ctx.placed()
            }
        default:
            break
        }
        ctx.frame()
    }

    // tap on the selected control: its sheet (a pad grid opens the pad under the finger)
    private func open(_ ctx: FMEditCtx, _ c: FMControl, _ p: CGPoint) {
        let r = rectOf(ctx, c)
        var payload: [String: Any] = ["id": c.id, "len": fmRound(c.vertical ? r.h : r.w)]
        if c.type == "pad_grid" && c.padCols > 0 && c.padRows > 0 {
            let col = fmClamp(Int((p.x - r.x) / r.w * CGFloat(c.padCols)), 0, c.padCols - 1)
            let row = fmClamp(Int((p.y - r.y) / r.h * CGFloat(c.padRows)), 0, c.padRows - 1)
            payload["sub"] = min(row * c.padCols + col, max(0, c.pads.count - 1))
        }
        ctx.emit("edit_open", payload)
    }

    // MARK: the pill

    private struct PillPart {
        let text: String
        let rect: FMGrid.Rect
        let style: Int
        let action: (() -> Void)?
    }

    // style: 0 plain text, 1 mono text, 2 light button, 3 dark "Done" button, 4 arrow; the first part is the pill
    private func pill(_ ctx: FMEditCtx) -> [PillPart] {
        let n = ctx.layout.pages.count
        let parts: [(String, Int, (() -> Void)?)] = [
            ("Editing", 0, nil),
            ("‹", 4, { if ctx.pageIndex > 0 { ctx.setPage(ctx.pageIndex - 1) } }),
            ("\(ctx.page.name) · \(ctx.pageIndex + 1)/\(n)", 1, nil),
            ("›", 4, { if ctx.pageIndex < n - 1 { ctx.setPage(ctx.pageIndex + 1) } }),
            ("+ Page", 2, { ctx.emit("edit_add_page", [:]) }),
            ("Done", 3, { ctx.emit("edit_done", [:]) }),
        ]
        let widths: [CGFloat] = parts.map { t, s, _ in
            switch s {
            case 4: return 32
            case 2, 3: return ink.width(t, 13, mono: false, weight: 700) + 26
            case 1: return ink.width(t, 12, mono: true, weight: 700) + 4
            default: return ink.width(t, 13, mono: false, weight: 700) + 4
            }
        }
        let gap: CGFloat = 6
        let total = 14 + widths.reduce(0, +) + gap * CGFloat(parts.count - 1) + 4
        var x = ctx.wDp / 2 - total / 2 + 14
        // at the top, unless the control being edited is under it: then at the bottom. Only the pill's buttons
        // take touches, so a control under its text can still be tapped (and selecting it moves the pill).
        let top = FMGrid.Rect(x: ctx.wDp / 2 - total / 2, y: 6, w: total, h: 44)
        let busy: FMGrid.Rect?
        switch op {
        case let o as Drag: busy = ctx.grid.rect(o.target)
        case let o as Resize: busy = ctx.grid.rect(o.target)
        default: busy = ctx.controls.first { $0.id == selected }.map { rectOf(ctx, $0) }
        }
        let clash = busy.map { b in b.x < top.x + top.w && top.x < b.x + b.w && b.y < top.y + top.h && top.y < b.y + b.h } ?? false
        let y: CGFloat = clash ? ctx.hDp - 50 : 6
        var out = [PillPart(text: "", rect: FMGrid.Rect(x: ctx.wDp / 2 - total / 2, y: y, w: total, h: 44), style: -1, action: nil)]
        for (i, (t, s, a)) in parts.enumerated() {
            out.append(PillPart(text: t, rect: FMGrid.Rect(x: x, y: y + 4, w: widths[i], h: 36), style: s, action: a))
            x += widths[i] + gap
        }
        return out
    }

    // MARK: the "Add here" menu

    private struct MenuBox {
        let rect: FMGrid.Rect
        let items: [(FMAddMenu.Item, FMGrid.Rect)]
    }

    private func menuBox(_ ctx: FMEditCtx, _ m: FMAddMenu) -> MenuBox {
        let w: CGFloat = 300
        // 28 dp rows, tighter when the list would run off a short (landscape) screen
        let rowH = max(min(28, (ctx.hDp - 16 - 48) / CGFloat(m.items.count) - 2), 20)
        let h = 12 + 26 + CGFloat(m.items.count) * (rowH + 2) + 10
        let cell = ctx.grid.rect(FMCell(col: m.col, row: m.row, w: 1, h: 1))
        var x = cell.x + cell.w + 12 + w <= ctx.wDp - 8 ? cell.x + cell.w + 12 : cell.x - 12 - w
        x = fmClamp(x, 8, max(8, ctx.wDp - w - 8))
        let y = fmClamp(cell.y - 20, 8, max(8, ctx.hDp - h - 8))
        let items = m.items.enumerated().map { i, it in
            (it, FMGrid.Rect(x: x + 12, y: y + 12 + 26 + CGFloat(i) * (rowH + 2), w: w - 24, h: rowH))
        }
        return MenuBox(rect: FMGrid.Rect(x: x, y: y, w: w, h: h), items: items)
    }

    // MARK: drawing

    /// Under the controls: the deep background and the grid.
    func drawUnder(_ g: CGContext, _ ctx: FMEditCtx, _ bounds: CGRect) {
        g.setFillColor(FME.bgDeep)
        g.fill(bounds)
        let grid = ctx.grid
        for row in 0..<max(grid.rows, 0) {
            for col in 0..<max(grid.cols, 0) {
                let r = grid.rect(FMCell(col: col, row: row, w: 1, h: 1))
                fmFillRoundRect(g, r.x, r.y, r.w, r.h, 8, FME.cell)
                fmStrokeRoundRect(g, r.x, r.y, r.w, r.h, 8, FME.cellLine, 1)
            }
        }
    }

    /// Over the controls: selection, drag, pill, menu.
    func drawOver(_ g: CGContext, _ ctx: FMEditCtx) {
        let grid = ctx.grid
        func rr(_ r: FMGrid.Rect, _ color: CGColor, _ radius: CGFloat, _ stroke: CGFloat = 0, dash: Bool = false) {
            if stroke > 0 {
                fmStrokeRoundRect(g, r.x, r.y, r.w, r.h, radius, color, stroke, dash: dash ? [6, 5] : nil)
            } else {
                fmFillRoundRect(g, r.x, r.y, r.w, r.h, radius, color)
            }
        }
        func footprint(_ cell: FMCell, _ ok: Bool) {
            let fill = ok ? FME.fmFill : FME.dangerFill
            let line = ok ? FME.fm : FME.danger
            for row in cell.row..<(cell.row + cell.h) {
                for col in cell.col..<(cell.col + cell.w) {
                    let r = grid.rect(FMCell(col: col, row: row, w: 1, h: 1))
                    rr(r, fill, 8)
                    rr(r, line, 8, 1)
                }
            }
        }

        // the cell "Add here" is for
        if let m = ctx.addMenu {
            let r = grid.rect(FMCell(col: m.col, row: m.row, w: 1, h: 1))
            rr(r, FME.paper, 8)
            ink.draw(g, "+", r.cx, r.cy, 26, FME.ink, weight: 400)
        }

        switch op {
        case let o as Drag:
            footprint(o.target, o.ok)
            let origin = grid.rect(o.origin)
            rr(origin, FME.faint, 10, 2, dash: true)
            ink.draw(g, label(o.control), origin.x + 8, origin.y + 14, 11, FME.faint, weight: 700, align: .left)
            let tl = CGPoint(x: o.finger.x - o.grab.x, y: o.finger.y - o.grab.y)
            // lifted a little up and right of the finger, so the footprint under it shows (Edit-Drag board)
            let box = FMGrid.Rect(x: tl.x + 6, y: tl.y - 6, w: origin.w, h: origin.h)
            rr(box, FME.raisedHi, 10)
            rr(box, FME.fm, 10, 2)
            ink.draw(g, label(o.control), box.x + 8, box.y + 14, 11, FME.text, weight: 700, align: .left)
            fmFillCircle(g, o.finger.x, o.finger.y, 20, FME.fingerDot)
            if !o.ok && o.edgeDir == 0 {
                let over = ctx.controls.first { $0.id != o.control.id && cellOf($0).overlaps(o.target) }
                let tip: String
                if let over {
                    let l = label(over)
                    tip = "Overlaps \(l.isEmpty ? typeName(over.type) : l)"
                } else {
                    tip = "Off the grid"
                }
                let t = grid.rect(o.target)
                chip(g, tip, t.x + 4, t.y + t.h + 6, FME.danger, FME.ink)
            }
            if o.edgeDir != 0 {
                let k = fmClamp(CGFloat(fmNowMs() - o.edgeSince) / CGFloat(FM_EDGE_HOLD_MS), 0, 1)
                let x: CGFloat = o.edgeDir < 0 ? 0 : ctx.wDp - 8
                rr(FMGrid.Rect(x: x, y: 0, w: 8, h: ctx.hDp), FME.edgeTrack, 4)
                rr(FMGrid.Rect(x: x, y: ctx.hDp * (1 - k), w: 8, h: ctx.hDp * k), FME.fm, 4)
                let n = ctx.pageIndex + o.edgeDir
                let name = n >= 0 && n < ctx.layout.pages.count ? ctx.layout.pages[n].name : "a new page"
                chip(g, o.edgeDir < 0 ? "‹ to \(name)" : "to \(name) ›", o.edgeDir < 0 ? 16 : ctx.wDp - 160, ctx.hDp / 2 - 12, FME.fm, FME.ink)
            }
        case let o as Resize:
            footprint(o.target, o.ok)
            let t = grid.rect(o.target)
            rr(t, o.ok ? FME.fm : FME.danger, 10, 2)
            chip(g, "\(o.target.w)×\(o.target.h)", t.x + 6, t.y + 6, o.ok ? FME.fm : FME.danger, FME.ink)
        default:
            break
        }

        // the selection: lime ring, four handles, size badge
        if let sel = ctx.controls.first(where: { $0.id == selected }), !(op is Drag), !(op is Resize) {
            let r = rectOf(ctx, sel)
            rr(r, FME.fm, 10, 2)
            if resizable(sel) {
                for (x, y) in [(r.x, r.y), (r.x + r.w, r.y), (r.x, r.y + r.h), (r.x + r.w, r.y + r.h)] {
                    fmFillCircle(g, x, y, 12, FME.bgDeep)
                    fmFillCircle(g, x, y, 9, FME.fm)
                }
            }
            let cell = cellOf(sel)
            let what = sel.type == "menu" ? "creature · moves, never deleted"
                : "\(typeName(sel.type).lowercased()) · \(cell.w)×\(cell.h) · tap for bindings"
            let bw = ink.width(what, 11, mono: true, weight: 700) + 16
            let bx = min(r.x + 18, ctx.wDp - bw - 8)
            let by = bx < r.x + 18 && r.y > 40 ? r.y - 28 : r.y + 6
            chip(g, what, bx, by, FME.fm, FME.ink, mono: true)
        }

        // the pill
        let parts = pill(ctx)
        rr(parts[0].rect, FME.paper, 22)
        for p in parts.dropFirst() {
            let r = p.rect
            switch p.style {
            case 0: ink.draw(g, p.text, r.cx, r.cy, 13, FME.ink, weight: 700)
            case 1: ink.draw(g, p.text, r.cx, r.cy, 12, FME.ink, mono: true, weight: 700)
            case 2: rr(r, FME.paper2, 18); ink.draw(g, p.text, r.cx, r.cy, 13, FME.ink, weight: 700)
            case 3: rr(r, FME.ink, 18); ink.draw(g, p.text, r.cx, r.cy, 13, FME.fm, weight: 700)
            case 4: ink.draw(g, p.text, r.cx, r.cy, 16, FME.ink, weight: 700)
            default: break
            }
        }

        // "Add here"
        if let m = ctx.addMenu {
            let box = menuBox(ctx, m)
            rr(box.rect, FME.paper, 18)
            ink.draw(g, "Add here", box.rect.x + 16, box.rect.y + 24, 14, FME.ink, weight: 700, align: .left)
            ink.draw(g, "room: \(m.roomW) wide × \(m.roomH) tall", box.rect.x + box.rect.w - 16, box.rect.y + 24, 11, FME.ink2,
                     mono: true, weight: 400, align: .right)
            for (item, r) in box.items {
                if item.fits { rr(r, FME.paper2, 9) }
                ink.draw(g, item.name, r.x + 10, r.cy, 13, item.fits ? FME.ink : FME.disabled, weight: 700, align: .left)
                let aside = item.fits ? item.size + " +" : (!item.reason.isEmpty ? item.reason : "needs \(item.size)")
                ink.draw(g, aside, r.x + r.w - 10, r.cy, 11, item.fits ? FME.ink2 : FME.needs, mono: true, weight: 400, align: .right)
            }
        }
    }

    private func label(_ c: FMControl) -> String { c.label.isEmpty ? typeName(c.type) : c.label }

    private func typeName(_ t: String) -> String {
        switch t {
        case "pad_grid": return "Pads"
        case "xy_pad": return "XY pad"
        case "keyboard": return "Keyboard"
        case "strum": return "Strum"
        case "screen": return "Screen"
        case "menu": return "Creature"
        case "page_switcher": return "Pages"
        default: return t.prefix(1).uppercased() + t.dropFirst()
        }
    }

    private func chip(_ g: CGContext, _ t: String, _ x: CGFloat, _ y: CGFloat, _ bg: CGColor, _ fg: CGColor, mono: Bool = false) {
        let w = ink.width(t, 11, mono: mono, weight: 700) + 16
        fmFillRoundRect(g, x, y, w, 22, 8, bg)
        ink.draw(g, t, x + 8, y + 11, 11, fg, mono: mono, weight: 700, align: .left)
    }
}

/// Draws a short message over the surface (FMutate.Editor's toasts: why an edit didn't happen, etc.).
func fmDrawToast(_ g: CGContext, _ ink: FMInk, _ text: String, _ wDp: CGFloat, _ hDp: CGFloat) {
    if text.isEmpty { return }
    let w = ink.width(text, 13, mono: false, weight: 700) + 32
    let x = wDp / 2 - w / 2
    let y = hDp - 64
    fmFillRoundRect(g, x, y, w, 40, 20, FME.paper)
    ink.draw(g, text, wDp / 2, y + 20, 13, FME.ink, weight: 700)
}
