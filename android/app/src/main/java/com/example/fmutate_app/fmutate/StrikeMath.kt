package com.example.fmutate_app.fmutate

import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * Strike position on a keyboard strip (velocity source "position"): how loud a note plays from where its key is struck
 * and where the finger is while it is held. `front` is where the finger is on its key: 1 at the front edge (the bottom
 * of a horizontal strip, nearest the player), 0 at the back edge (the top). ios/FMutateStrikeMath.swift has the same.
 */
object StrikeMath {
    /** How far below a front-edge strike a strike at velocity 1 plays, by its level alone (dB). */
    const val LEVEL_RANGE_DB = 24.0

    /** Velocity from where a key is struck: [max] at its front edge, [min] at its back edge. */
    fun velocity(front: Float, min: Int, max: Int): Int = (min + (max - min) * front).roundToInt().coerceIn(1, 127)

    /**
     * The level a note starts at (MIDI polyphonic aftertouch, 0 silent .. 127 as played; firmwares with
     * `caps.note_pressure`) from its strike velocity: 127 at velocity 127, then equal dB steps down to
     * [LEVEL_RANGE_DB] below it at velocity 1. A synth's own velocity response can be too shallow to hear: OberVave's
     * amp at its default VEL>AMP 60 plays velocity 40 (a strip's default back edge) about 2 dB below 127, so a strike
     * at the top of a key sounded like one at the bottom. Its level is a square law (FMutate's poly-aftertouch patch),
     * so velocity 40 (level 49) is about 16.5 dB down, 84 (79) 8 dB.
     */
    fun strikeLevel(vel: Int): Int {
        val db = -LEVEL_RANGE_DB * (127 - vel.coerceIn(1, 127)) / 126.0
        return (127 * 10.0.pow(db / 40)).roundToInt()
    }

    /**
     * A held note's level from where the finger is now ([front]), relative to where it struck ([struck], at level
     * [strike]): the strike's level there, rising to 127 at the front edge and fading to silence at the back edge.
     */
    fun heldLevel(front: Float, struck: Float, strike: Int): Int = when {
        front >= struck && struck >= 1f -> strike
        front >= struck -> (strike + (127 - strike) * (front - struck) / (1f - struck)).roundToInt()
        else -> (strike * front / struck).roundToInt()
    }
}
