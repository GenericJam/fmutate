// FMutateSideKeyboard.swift: port of android/.../fmutate/SideKeyboard.kt.
//
// The portrait side keyboard's colour rail (HANDOFF §8, Portrait-Groove.dc.html): a vertical keyboard strip with
// pitch colours gets a thin rail of the 88-key colours (FMutate.Style.pitch_color/1) along its inner edge,
// spanning the FM-1's 27 keys, low at the bottom, with a frame around the keys on screen. The rail is the scroll
// handle: touching or dragging it moves the window; dragging keys never scrolls (it plays, rule 2).

import CoreGraphics

let FM_RAIL_DP: CGFloat = 22
private let RAIL_W: CGFloat = 10

/// Grab.sub of a finger scrolling the rail (keys are 0..26; -1 is "nothing held").
let FM_RAIL_GRAB = -2

func fmHasRail(_ c: FMControl) -> Bool { c.type == "keyboard" && c.vertical && c.pitchColors }

/// The part of a strip the keys take (all of it, unless it has a rail).
func fmKeysRect(_ c: FMControl, _ r: FMGrid.Rect) -> FMGrid.Rect {
    fmHasRail(c) ? FMGrid.Rect(x: r.x + FM_RAIL_DP, y: r.y, w: r.w - FM_RAIL_DP, h: r.h) : r
}

func fmRailHit(_ c: FMControl, _ r: FMGrid.Rect, _ x: CGFloat, _ y: CGFloat) -> Bool {
    fmHasRail(c) && r.contains(x, y) && x < r.x + FM_RAIL_DP
}

/// First visible key for a finger at `y` on the rail: the window of `n + 1` keys centred on it.
func fmRailStart(_ r: FMGrid.Rect, _ y: CGFloat, _ n: Int) -> Int {
    let k = Int((r.y + r.h - y) / r.h * 27)
    return fmClamp(k - n / 2, 0, 26 - n)
}

/// FMutate.Style.pitch_color/1: hue 0..300 across the 88 keys.
func fmPitchColor(_ midi: Int, _ lightness: CGFloat = 0.62) -> CGColor {
    fmHSL(CGFloat(fmClamp(midi - 21, 0, 87)) / 87 * 300, 0.72, lightness)
}

private let RAIL_BG = fmColor(0xFF0E0D12)
private let RAIL_FRAME = fmColor(0xFFF3EFF8)

func fmDrawRail(_ g: CGContext, _ r: FMGrid.Rect, _ window: ClosedRange<Int>) {
    let x = r.x + (FM_RAIL_DP - RAIL_W) / 2
    let seg = r.h / 27
    fmFillRoundRect(g, x, r.y, RAIL_W, r.h, 5, RAIL_BG)
    for k in 0...26 {
        let y = r.y + r.h - CGFloat(k + 1) * seg
        g.setFillColor(fmPitchColor(53 + k))
        g.fill(CGRect(x: x, y: y, width: RAIL_W, height: seg + 0.3))
    }
    let top = r.y + r.h - CGFloat(window.upperBound + 1) * seg
    let h = CGFloat(window.upperBound - window.lowerBound + 1) * seg
    fmStrokeRoundRect(g, x - 4, top - 2, RAIL_W + 8, h + 4, 6, RAIL_FRAME, 2)
}
