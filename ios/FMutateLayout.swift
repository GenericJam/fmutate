// FMutateLayout.swift: port of android/.../fmutate/Layout.kt.
//
// The layout model (priv/layout.schema.json, "fmutate.layout/1") and the grid (HANDOFF §5,
// FMutate.Style.grid_for/2). Pure: no UIKit types. Every type is prefixed FM (one Swift module with Mob's files).

import Foundation
import CoreGraphics

/// Kotlin's `roundToInt()` (Math.round: half up), so cells and values round exactly as on Android.
@inline(__always) func fmRound(_ x: CGFloat) -> Int { Int((x + 0.5).rounded(.down)) }
@inline(__always) func fmRound(_ x: Float) -> Int { Int((x + 0.5).rounded(.down)) }
@inline(__always) func fmClamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }

enum FMTarget: Equatable {
    case key(Int)
    case encoder(id: String, ptPerClick: CGFloat, invert: Bool)
    case pot
    case button(String)
    case midi(type: String, channel: Int, number: Int, jump: Bool, on: Int, off: Int)
    case page(String)
    /// App actions on the surface itself (no firmware input): "bend" switches the keyboard strips to bending.
    case action(String)

    /// Absolute targets share one value between every control bound to them (HANDOFF §6 rule 7).
    var absoluteKey: String? {
        switch self {
        case .pot: return "pot:master"
        case let .midi(type, channel, number, _, _, _):
            switch type {
            case "cc": return "cc:\(channel):\(number)"
            // a motion control's axis: one bend value per channel, shared like a CC
            case "pitch_bend": return "bend:\(channel)"
            default: return nil
            }
        default: return nil
        }
    }

    /// `b.to is Target.Midi && b.to.jump` (jump-to-position MIDI sliders, rule 5).
    var isJumpMidi: Bool {
        if case let .midi(_, _, _, jump, _, _) = self { return jump }
        return false
    }

    var isKey: Bool { if case .key = self { return true }; return false }
    var buttonId: String? { if case let .button(id) = self { return id }; return nil }
}

struct FMBinding: Equatable {
    let on: String
    let to: FMTarget
    let mode: String
}

struct FMCell: Equatable, Hashable {
    var col: Int, row: Int, w: Int, h: Int
    func overlaps(_ o: FMCell) -> Bool { col < o.col + o.w && o.col < col + w && row < o.row + o.h && o.row < row + h }
}

struct FMPad: Equatable {
    let label: String
    let color: String
    let bindings: [FMBinding]
}

struct FMControl: Equatable {
    var id: String
    var type: String
    var at: FMCell
    var label: String
    var color: String
    var bindings: [FMBinding]
    // keyboard
    var fromKey = 0
    var toKey = 26
    var octaveArrows = true
    var vertical = false
    var wobble = false
    var bendRange: CGFloat = 0.5          // semitones at half a key width of slide
    var pitchColors = false
    // velocity "position": the strip plays MIDI notes, velocity from where the key is struck (velMin..velMax);
    // "fixed" (default): firmware key presses, the firmware's own fixed velocity
    var strikeVelocity = false
    var velMin = 40
    var velMax = 127
    var velSwell = false                  // position, opt-in: front/back on a held key sets CC7 (every sounding note)
    var velPressure = false               // position, opt-in: the held note's own level follows the finger (poly aftertouch)
    // pad_grid
    var padCols = 1
    var padRows = 1
    var pads: [FMPad] = []
    // slider, xy_pad, strum, screen, page_switcher
    var sliderVertical = true
    var springBack = false
    var strings: [Int] = []
    var screenScale = 0
    var switcherDots = false
    // motion (FMutateMotionControl.swift): engage hold / latch, degrees for a value's whole span, spring back, shake
    var motionLatch = false
    var motionRange = 45
    var motionSpringBack = false
    var motionShake = "firm"

    init(id: String, type: String, at: FMCell, label: String, color: String, bindings: [FMBinding]) {
        self.id = id; self.type = type; self.at = at; self.label = label; self.color = color; self.bindings = bindings
    }

    func binding(_ on: String) -> FMBinding? { bindings.first { $0.on == on } }
}

struct FMPage: Equatable {
    let id: String
    let name: String
    let controls: [FMControl]
}

// MARK: - JSON helpers (org.json's opt*/get* semantics; NSNull counts as missing)

private struct FMJSONError: Error {}
private typealias FMObj = [String: Any]

private extension Dictionary where Key == String, Value == Any {
    func val(_ k: String) -> Any? { let v = self[k]; return v is NSNull ? nil : v }
    func getObj(_ k: String) throws -> FMObj { guard let o = val(k) as? FMObj else { throw FMJSONError() }; return o }
    func optObj(_ k: String) -> FMObj? { val(k) as? FMObj }
    func getArr(_ k: String) throws -> [Any] { guard let a = val(k) as? [Any] else { throw FMJSONError() }; return a }
    func optArr(_ k: String) -> [Any]? { val(k) as? [Any] }
    func getInt(_ k: String) throws -> Int {
        if let n = val(k) as? NSNumber { return n.intValue }
        if let s = val(k) as? String, let d = Double(s) { return Int(d) }
        throw FMJSONError()
    }
    func optInt(_ k: String, _ d: Int) -> Int { (try? getInt(k)) ?? d }
    func optDouble(_ k: String, _ d: Double) -> Double {
        if let n = val(k) as? NSNumber { return n.doubleValue }
        if let s = val(k) as? String, let v = Double(s) { return v }
        return d
    }
    func getString(_ k: String) throws -> String {
        guard let v = val(k) else { throw FMJSONError() }
        if let s = v as? String { return s }
        return "\(v)"
    }
    func optString(_ k: String, _ d: String) -> String { (try? getString(k)) ?? d }
    func optBool(_ k: String, _ d: Bool) -> Bool {
        if let n = val(k) as? NSNumber { return n.boolValue }
        if let s = val(k) as? String { return s.lowercased() == "true" ? true : (s.lowercased() == "false" ? false : d) }
        return d
    }
    func getBool(_ k: String) throws -> Bool {
        if let n = val(k) as? NSNumber { return n.boolValue }
        if let s = val(k) as? String, s == "true" || s == "false" { return s == "true" }
        throw FMJSONError()
    }
    func has(_ k: String) -> Bool { self[k] != nil }
}

private func fmObjects(_ a: [Any]) throws -> [FMObj] {
    try a.map { guard let o = $0 as? FMObj else { throw FMJSONError() }; return o }
}

func fmParseJSONObject(_ json: String) -> [String: Any]? {
    guard let data = json.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

struct FMLayout: Equatable {
    let id: String
    let name: String
    let landscape: Bool
    let gridCols: Int
    let gridRows: Int
    let switcher: String
    let dock: [FMControl]
    let pages: [FMPage]

    static func parse(_ json: String) -> FMLayout? {
        guard let o = fmParseJSONObject(json) else { return nil }
        return try? fromJson(o)
    }

    fileprivate static func fromJson(_ o: FMObj) throws -> FMLayout {
        let grid = try o.getObj("grid")
        let dock = try controls(o.optArr("dock"))
        let pages = try fmObjects(try o.getArr("pages")).map { p in
            FMPage(id: try p.getString("id"), name: p.optString("name", try p.getString("id")), controls: try controls(p.optArr("controls")))
        }
        let cols = try grid.getInt("cols"), rows = try grid.getInt("rows")
        return FMLayout(
            id: try o.getString("id"),
            name: o.optString("name", try o.getString("id")),
            landscape: o.optString("frame", "landscape") == "landscape",
            gridCols: cols,
            gridRows: rows,
            switcher: o.optString("switcher", "names"),
            dock: withMenu(dock, pages, cols, rows),
            pages: pages
        )
    }

    // Every layout has exactly one menu (the creature) in the dock; add it at the first free cell if missing.
    private static func withMenu(_ dock: [FMControl], _ pages: [FMPage], _ cols: Int, _ rows: Int) -> [FMControl] {
        if dock.contains(where: { $0.type == "menu" }) || pages.contains(where: { p in p.controls.contains { $0.type == "menu" } }) { return dock }
        let taken = dock.map(\.at) + pages.flatMap { p in p.controls.map(\.at) }
        for r in 0..<max(rows, 0) {
            for c in 0..<max(cols, 0) {
                let cell = FMCell(col: c, row: r, w: 1, h: 1)
                if !taken.contains(where: { $0.overlaps(cell) }) {
                    return dock + [FMControl(id: "menu", type: "menu", at: cell, label: "", color: "default", bindings: [])]
                }
            }
        }
        return dock
    }

    private static func controls(_ a: [Any]?) throws -> [FMControl] {
        guard let a else { return [] }
        return try fmObjects(a).map(control)
    }

    private static func control(_ o: FMObj) throws -> FMControl {
        let at = try o.getObj("at")
        let kb = o.optObj("keyboard")
        let pg = o.optObj("pad_grid")
        let sl = o.optObj("slider")
        let xy = o.optObj("xy_pad")
        let st = o.optObj("strum")
        let sc = o.optObj("screen")
        let ps = o.optObj("page_switcher")
        let mo = o.optObj("motion")
        var c = FMControl(
            id: try o.getString("id"),
            type: try o.getString("type"),
            at: FMCell(col: try at.getInt("col"), row: try at.getInt("row"), w: try at.getInt("w"), h: try at.getInt("h")),
            label: o.optString("label", ""),
            color: o.optString("color", "default"),
            bindings: try bindings(o.optArr("bindings"))
        )
        if let kb {
            c.fromKey = kb.optInt("from_key", 0)
            c.toKey = kb.optInt("to_key", 26)
            c.octaveArrows = kb.optBool("octave_arrows", true)
            c.vertical = kb.optString("orientation", "horizontal") == "vertical"
            c.wobble = kb.optString("glide", "glissando") == "wobble"
            c.bendRange = CGFloat(kb.optDouble("bend_range", 0.5))
            c.pitchColors = kb.optBool("pitch_colors", false)
            if let v = kb.optObj("velocity") {
                c.strikeVelocity = v.optString("source", "fixed") == "position"
                c.velMin = v.optInt("min", 40)
                c.velMax = v.optInt("max", 127)
                c.velSwell = v.optBool("swell", false)
                c.velPressure = v.optBool("pressure", false)
            }
        }
        if let pg {
            c.padCols = pg.optInt("cols", 1)
            c.padRows = pg.optInt("rows", 1)
            c.pads = try fmObjects(pg.optArr("pads") ?? []).map {
                FMPad(label: $0.optString("label", ""), color: $0.optString("color", "default"), bindings: try bindings($0.optArr("bindings")))
            }
        }
        // Kotlin: `sl?.optString(..) != "horizontal"` (no slider object: vertical)
        c.sliderVertical = sl?.optString("orientation", "vertical") != "horizontal"
        c.springBack = xy?.optString("on_release", "stay") == "spring_back"
        c.strings = try (st?.optArr("keys") ?? []).map { v -> Int in
            guard let n = v as? NSNumber else { throw FMJSONError() }
            return n.intValue
        }
        c.screenScale = sc?.optInt("scale", 0) ?? 0
        c.switcherDots = ps?.optString("look", "names") == "dots"
        c.motionLatch = mo?.optString("engage", "hold") == "latch"
        c.motionRange = fmClamp(mo?.optInt("range", 45) ?? 45, 5, 180)
        c.motionSpringBack = mo?.optString("on_release", "stay") == "spring_back"
        c.motionShake = mo?.optString("shake", "firm") ?? "firm"
        return c
    }

    private static func bindings(_ a: [Any]?) throws -> [FMBinding] {
        guard let a else { return [] }
        return try fmObjects(a).compactMap { b in
            try target(try b.getObj("to")).map { FMBinding(on: b.optString("on", "press"), to: $0, mode: b.optString("mode", "momentary")) }
        }
    }

    private static func target(_ t: FMObj) throws -> FMTarget? {
        if t.has("key") { return .key(try t.getInt("key")) }
        if t.has("encoder") {
            return .encoder(id: try t.getString("encoder"), ptPerClick: CGFloat(t.optDouble("pt_per_click", 6.0)), invert: t.optBool("invert", false))
        }
        if t.has("pot") { return .pot }
        if t.has("button") { return .button(try t.getString("button")) }
        if t.has("midi") {
            let m = try t.getObj("midi")
            return .midi(type: try m.getString("type"), channel: m.optInt("channel", 1), number: m.optInt("number", 0),
                         jump: m.optBool("jump", false), on: m.optInt("on", 127), off: m.optInt("off", 0))
        }
        if t.has("page") { return .page(try t.getString("page")) }
        if t.has("action") { return .action(try t.getString("action")) }
        return nil
    }
}

/// The device grid (HANDOFF §5): all values in dp (points on iOS).
struct FMGrid: Equatable {
    let cols: Int, rows: Int
    let cellW: CGFloat, cellH: CGFloat, gap: CGFloat, left: CGFloat, top: CGFloat

    struct Rect: Equatable {
        var x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
        func contains(_ px: CGFloat, _ py: CGFloat) -> Bool { px >= x && px < x + w && py >= y && py < y + h }
        var cx: CGFloat { x + w / 2 }
        var cy: CGFloat { y + h / 2 }
        var cg: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    }

    func rect(_ c: FMCell) -> Rect {
        Rect(x: left + CGFloat(c.col) * (cellW + gap),
             y: top + CGFloat(c.row) * (cellH + gap),
             w: CGFloat(c.w) * cellW + CGFloat(c.w - 1) * gap,
             h: CGFloat(c.h) * cellH + CGFloat(c.h - 1) * gap)
    }

    // Side gutters: Android keeps 28 dp clear for its back gesture. iOS has no side back gesture in a full-screen
    // app, so its gutters are 12 pt, or the safe area where that is wider (the sensor housing of a notched iPhone
    // in landscape); the top and bottom insets also widen to the safe area (the home indicator). The iPhone SE
    // (667 × 375 pt) needs this: with 28 pt gutters the classic layout's 14 columns would be 36 pt wide
    // (docs/decisions/2026-11-13-ios-port.md §4).
    static let GUTTER: CGFloat = 12
    static let INSET: CGFloat = 12
    static let MIN_CELL: CGFloat = 48
    static let GAP: CGFloat = 8
    /// The gap a squeezed layout may drop to so its cells stay >= FM_SQUEEZE_MIN (fmFit rule 2).
    static let SQUEEZE_GAP: CGFloat = 4

    /// FMutate.Style.grid_for/2 on the area left after the margins.
    static func forScreen(_ wDp: CGFloat, _ hDp: CGFloat, _ m: FMMargins) -> FMGrid {
        let uw = wDp - 2 * m.side
        let uh = hDp - m.top - m.bottom
        let cols = max(1, Int(((uw + GAP) / (MIN_CELL + GAP)).rounded(.down)))
        let rows = max(1, Int(((uh + GAP) / (MIN_CELL + GAP)).rounded(.down)))
        return FMGrid(cols: cols, rows: rows,
                      cellW: (uw - CGFloat(cols - 1) * GAP) / CGFloat(cols),
                      cellH: (uh - CGFloat(rows - 1) * GAP) / CGFloat(rows),
                      gap: GAP, left: m.side, top: m.top)
    }

    /// A layout's own cols × rows filling the area left after the margins, with this gap.
    static func sized(_ cols: Int, _ rows: Int, _ wDp: CGFloat, _ hDp: CGFloat, _ m: FMMargins, gap: CGFloat = GAP) -> FMGrid {
        let uw = wDp - 2 * m.side
        let uh = hDp - m.top - m.bottom
        return FMGrid(cols: cols, rows: rows,
                      cellW: (uw - CGFloat(cols - 1) * gap) / CGFloat(cols),
                      cellH: (uh - CGFloat(rows - 1) * gap) / CGFloat(rows),
                      gap: gap, left: m.side, top: m.top)
    }
}

/// The room kept clear around the grid, in points: both side gutters, the top and the bottom inset.
struct FMMargins: Equatable {
    var side: CGFloat, top: CGFloat, bottom: CGFloat

    /// GUTTER and INSET, widened to the view's safe area (left, top, right, bottom).
    static func safe(left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) -> FMMargins {
        FMMargins(side: max(FMGrid.GUTTER, left, right), top: max(FMGrid.INSET, top), bottom: max(FMGrid.INSET, bottom))
    }
}

/// Minimum sizes in cells (HANDOFF §5; FMutate.LayoutEdit.min_size/1 is the same rule). Sliders and keyboard
/// strips are measured along their own orientation; the firmware screen needs 2×2.
func fmMinSize(_ c: FMControl) -> (Int, Int) {
    switch c.type {
    case "slider": return c.sliderVertical ? (1, 2) : (2, 1)
    case "keyboard": return c.vertical ? (2, 4) : (4, 2)
    default: return fmMinSize(type: c.type)
    }
}

func fmMinSize(type: String) -> (Int, Int) {
    switch type {
    case "slider": return (1, 2)
    case "xy_pad", "pad_grid", "screen": return (2, 2)
    case "strum": return (1, 3)
    case "keyboard": return (4, 2)
    case "page_switcher": return (2, 1)
    default: return (1, 1)
    }
}

/// A layout's cells moved onto the device grid: positions scale with cols/rows and round. Returns the moved
/// cell per control id and whether everything still fits (no control below its minimum size, no overlap).
struct FMPlacement: Equatable {
    let cells: [String: FMCell]
    let fits: Bool
}

func fmPlace(_ layout: FMLayout, _ page: FMPage, _ grid: FMGrid) -> FMPlacement {
    let sx = CGFloat(grid.cols) / CGFloat(layout.gridCols)
    let sy = CGFloat(grid.rows) / CGFloat(layout.gridRows)
    let all = layout.dock + page.controls
    var cells: [String: FMCell] = [:]
    for c in all {
        if layout.gridCols == grid.cols && layout.gridRows == grid.rows {
            cells[c.id] = c.at
        } else {
            let col = fmRound(CGFloat(c.at.col) * sx)
            let row = fmRound(CGFloat(c.at.row) * sy)
            let w = max(1, fmRound(CGFloat(c.at.col + c.at.w) * sx) - col)
            let h = max(1, fmRound(CGFloat(c.at.row + c.at.h) * sy) - row)
            cells[c.id] = FMCell(col: col, row: row, w: w, h: h)
        }
    }
    let inside = cells.values.allSatisfy { $0.col >= 0 && $0.row >= 0 && $0.col + $0.w <= grid.cols && $0.row + $0.h <= grid.rows }
    let bigEnough = all.allSatisfy { c in let m = fmMinSize(c); let cell = cells[c.id]!; return cell.w >= m.0 && cell.h >= m.1 }
    let list = Array(cells.values)
    var noOverlap = true
    outer: for i in list.indices {
        for j in (i + 1)..<list.count where list[i].overlaps(list[j]) { noOverlap = false; break outer }
    }
    return FMPlacement(cells: cells, fits: inside && bigEnough && noOverlap)
}

/// How a layout goes onto this screen (HANDOFF §5; reflow is an open question there, this is the tech decision):
///  1. the device grid equals the authoring grid: as authored;
///  2. otherwise keep the authoring grid and resize its cells to the screen, if every cell stays >= SQUEEZE_MIN dp
///     (a 14-column layout on an 800 dp phone gets ~46 dp cells: still playable, nothing moves), narrowing the
///     gap to SQUEEZE_GAP if that is what it takes (the classic layout on the iPhone SE: 42 pt cells);
///  3. otherwise move the cells onto the device grid (place) and report whether it still fits.
struct FMFitted: Equatable {
    let grid: FMGrid
    let placement: FMPlacement
}

let FM_SQUEEZE_MIN: CGFloat = 40

func fmFit(_ layout: FMLayout, _ page: FMPage, _ wDp: CGFloat, _ hDp: CGFloat, _ m: FMMargins) -> FMFitted {
    let device = FMGrid.forScreen(wDp, hDp, m)
    if device.cols != layout.gridCols || device.rows != layout.gridRows {
        for gap in [FMGrid.GAP, FMGrid.SQUEEZE_GAP] {
            let squeezed = FMGrid.sized(layout.gridCols, layout.gridRows, wDp, hDp, m, gap: gap)
            if squeezed.cellW >= FM_SQUEEZE_MIN && squeezed.cellH >= FM_SQUEEZE_MIN {
                return FMFitted(grid: squeezed, placement: fmPlace(layout, page, squeezed))
            }
        }
    }
    return FMFitted(grid: device, placement: fmPlace(layout, page, device))
}
