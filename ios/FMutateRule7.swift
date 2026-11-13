// FMutateRule7.swift: port of android/.../fmutate/Rule7.kt.
//
// Two controls bound to one input (HANDOFF §6 rule 7) on the surface. Encoder clicks always go out, so deltas
// add. An absolute target (pot, MIDI CC) is owned by the last control that moved it; the others are drawn
// greyed out and pick up: their moves are dropped until they reach the current value. FMutate.Bindings applies
// the same rule to what reaches the firmware; this mirror is what the player sees.

import CoreGraphics

let FM_PICKUP: Float = 0.04

final class FMRule7 {
    private var owner: [String: String] = [:]   // target key -> control id
    private var last: [String: Float] = [:]     // "key|control" -> the control's last position
    /// Kotlin's owner map is snapshot state (the controls layer redraws when it changes); here the surface is told.
    var ownerChanged: () -> Void = {}

    /// May `control` set absolute target `key` to `v` (current value `current`)? Records the move either way.
    func accept(_ key: String, _ control: String, _ v: Float, _ current: Float?) -> Bool {
        let o = owner[key]
        let lk = key + "|" + control
        let prev = last[lk]
        var ok = o == nil || o == control || current == nil
        if !ok, let current {
            ok = abs(v - current) <= FM_PICKUP || (prev != nil && (prev! - current) * (v - current) <= 0)
        }
        last[lk] = v
        if ok && o != control {
            owner[key] = control
            ownerChanged()
        }
        return ok
    }

    /// Whether another control moved one of this control's absolute targets last.
    func stale(_ c: FMControl) -> Bool {
        c.bindings.contains { b in
            guard let k = b.to.absoluteKey, let o = owner[k] else { return false }
            return o != c.id
        }
    }
}

/// Greys out a stale control (drawn over it).
func fmDimOver(_ g: CGContext, _ r: FMGrid.Rect) {
    fmFillRoundRect(g, r.x, r.y, r.w, r.h, 12, FMC.dim)
}
