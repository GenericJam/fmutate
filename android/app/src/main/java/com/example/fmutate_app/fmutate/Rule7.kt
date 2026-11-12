package com.example.fmutate_app.fmutate

import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import kotlin.math.abs

/*
 * Two controls bound to one input (HANDOFF §6 rule 7) on the surface. Encoder clicks always go out, so deltas
 * add. An absolute target (pot, MIDI CC) is owned by the last control that moved it; the others are drawn
 * greyed out and pick up: their moves are dropped until they reach the current value. FMutate.Bindings applies
 * the same rule to what reaches the firmware; this mirror is what the player sees.
 */

const val PICKUP = 0.04f

class Rule7 {
    private val owner = mutableStateMapOf<String, String>()   // target key -> control id
    private val last = mutableMapOf<String, Float>()          // "key|control" -> the control's last position

    /** May `control` set absolute target `key` to `v` (current value `current`)? Records the move either way. */
    fun accept(key: String, control: String, v: Float, current: Float?): Boolean {
        val o = owner[key]
        val prev = last["$key|$control"]
        val ok = o == null || o == control || current == null || abs(v - current) <= PICKUP ||
            (prev != null && (prev - current) * (v - current) <= 0f)
        last["$key|$control"] = v
        if (ok) owner[key] = control
        return ok
    }

    /** Whether another control moved one of this control's absolute targets last. */
    fun stale(c: Control): Boolean = c.bindings.any { b ->
        val k = b.to.absoluteKey
        k != null && owner[k].let { it != null && it != c.id }
    }
}

/** Greys out a stale control (drawn over it). */
fun dimOver(s: DrawScope, r: Grid.Rect, d: Float) =
    s.drawRoundRect(Color(0xFF14121A).copy(alpha = 0.55f), Offset(r.x * d, r.y * d), Size(r.w * d, r.h * d), CornerRadius(12 * d))
