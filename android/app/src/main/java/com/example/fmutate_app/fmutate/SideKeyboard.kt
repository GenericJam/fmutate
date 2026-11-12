package com.example.fmutate_app.fmutate

import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke

/*
 * The portrait side keyboard's colour rail (HANDOFF §8, Portrait-Groove.dc.html): a vertical keyboard strip with
 * pitch colours gets a thin rail of the 88-key colours (FMutate.Style.pitch_color/1) along its inner edge,
 * spanning the FM-1's 27 keys, low at the bottom, with a frame around the keys on screen. The rail is the scroll
 * handle: touching or dragging it moves the window; dragging keys never scrolls (it plays, rule 2).
 */

const val RAIL_DP = 22f
private const val RAIL_W = 10f

/** Grab.sub of a finger scrolling the rail (keys are 0..26; -1 is "nothing held"). */
const val RAIL_GRAB = -2

fun hasRail(c: Control) = c.type == "keyboard" && c.vertical && c.pitchColors

/** The part of a strip the keys take (all of it, unless it has a rail). */
fun keysRect(c: Control, r: Grid.Rect): Grid.Rect =
    if (hasRail(c)) Grid.Rect(r.x + RAIL_DP, r.y, r.w - RAIL_DP, r.h) else r

fun railHit(c: Control, r: Grid.Rect, x: Float, y: Float) = hasRail(c) && r.contains(x, y) && x < r.x + RAIL_DP

/** First visible key for a finger at `y` on the rail: the window of `n + 1` keys centred on it. */
fun railStart(r: Grid.Rect, y: Float, n: Int): Int {
    val k = ((r.y + r.h - y) / r.h * 27f).toInt()
    return (k - n / 2).coerceIn(0, 26 - n)
}

/** FMutate.Style.pitch_color/1: hue 0..300 across the 88 keys. */
fun pitchColor(midi: Int, lightness: Float = 0.62f): Color =
    Color.hsl((midi - 21).coerceIn(0, 87) / 87f * 300f, 0.72f, lightness)

fun drawRail(s: DrawScope, r: Grid.Rect, window: IntRange, d: Float) {
    val x = r.x + (RAIL_DP - RAIL_W) / 2
    val seg = r.h / 27f
    s.drawRoundRect(Color(0xFF0E0D12), Offset(x * d, r.y * d), Size(RAIL_W * d, r.h * d), CornerRadius(5 * d))
    for (k in 0..26) {
        val y = r.y + r.h - (k + 1) * seg
        s.drawRect(pitchColor(53 + k), Offset(x * d, y * d), Size(RAIL_W * d, (seg + 0.3f) * d))
    }
    val top = r.y + r.h - (window.last + 1) * seg
    val h = (window.last - window.first + 1) * seg
    s.drawRoundRect(
        Color(0xFFF3EFF8), Offset((x - 4) * d, (top - 2) * d), Size((RAIL_W + 8) * d, (h + 4) * d),
        CornerRadius(6 * d), style = Stroke(2 * d),
    )
}
