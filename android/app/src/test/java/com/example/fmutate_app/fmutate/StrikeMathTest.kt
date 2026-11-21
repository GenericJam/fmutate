package com.example.fmutate_app.fmutate

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.log10

class StrikeMathTest {
    // the cases both ports must agree on, shared with ios/Tests: found from the working directory up (Gradle runs unit
    // tests in android/app)
    private val table: JSONObject by lazy {
        val start = File("").absoluteFile
        val file = generateSequence(start) { it.parentFile }.map { File(it, "test/fixtures/strike_math.json") }
            .firstOrNull { it.isFile } ?: error("test/fixtures/strike_math.json not found above $start")
        JSONObject(file.readText())
    }

    private fun rows(name: String) = table.getJSONArray(name).let { a -> (0 until a.length()).map { a.getJSONObject(it) } }

    @Test
    fun bothPortsGiveTheSharedTable() {
        val velocity = rows("velocity")
        val strike = rows("strikeLevel")
        val held = rows("heldLevel")
        assertTrue(velocity.isNotEmpty() && strike.isNotEmpty() && held.isNotEmpty())
        for (r in velocity) {
            val got = StrikeMath.velocity(r.getDouble("front").toFloat(), r.getInt("min"), r.getInt("max"))
            assertEquals("velocity: ${r.getString("case")}", r.getInt("vel"), got)
        }
        for (r in strike) {
            assertEquals("strikeLevel: ${r.getString("case")}", r.getInt("level"), StrikeMath.strikeLevel(r.getInt("vel")))
        }
        for (r in held) {
            val got = StrikeMath.heldLevel(r.getDouble("front").toFloat(), r.getDouble("struck").toFloat(), r.getInt("strike"))
            assertEquals("heldLevel: ${r.getString("case")}", r.getInt("level"), got)
        }
    }

    // a level's gain on FMutate's OberVave (native/patches/obervave/poly-aftertouch.patch: a square law), in dB
    private fun db(level: Int) = 40 * log10(level / 127.0)

    // a strip's default range: velocity 40 at the back edge (front 0), 127 at the front edge (front 1)
    private fun strike(front: Float) = StrikeMath.velocity(front, 40, 127).let { it to StrikeMath.strikeLevel(it) }

    @Test
    fun strikingTheTopOfAKeyIsQuietAndTheBottomLoud() {
        val (topVel, top) = strike(0f)
        val (midVel, mid) = strike(0.5f)
        val (bottomVel, bottom) = strike(1f)
        assertEquals(40, topVel)
        assertEquals(84, midVel)
        assertEquals(127, bottomVel)
        // the bottom (front edge) plays as the synth plays the note; the top is clearly quieter even on a patch whose
        // own velocity response is shallow (OberVave's VEL>AMP 60: about 2 dB from velocity 40 to 127), the middle
        // in between
        assertEquals(127, bottom)
        assertTrue("top ${db(top)} dB", db(top) <= -15)
        assertTrue("middle ${db(mid)} dB", db(mid) in -12.0..-5.0)
        // never silent: a strike at the very top edge, even at velocity 1, still sounds
        assertTrue(db(StrikeMath.strikeLevel(1)) >= -30)
    }

    @Test
    fun aStrikesLevelFallsInEqualStepsWithItsVelocity() {
        val levels = (1..127).map { StrikeMath.strikeLevel(it) }
        assertTrue(levels.zipWithNext().all { (a, b) -> a <= b })
        // equal dB steps: velocity 40 to 84 drops about as much as 84 to 127
        val lower = db(StrikeMath.strikeLevel(84)) - db(StrikeMath.strikeLevel(40))
        val upper = db(StrikeMath.strikeLevel(127)) - db(StrikeMath.strikeLevel(84))
        assertEquals(lower, upper, 1.0)
    }

    @Test
    fun aHeldNoteFollowsTheFingerFromItsStrikeLevel() {
        val struck = 0.25f
        val strike = StrikeMath.strikeLevel(StrikeMath.velocity(struck, 40, 127))
        // where it struck: as struck, so a tap plays its strike
        assertEquals(strike, StrikeMath.heldLevel(struck, struck, strike))
        // slid toward the top (back edge): quieter, to silence at the edge
        assertTrue(StrikeMath.heldLevel(0.1f, struck, strike) < strike)
        assertEquals(0, StrikeMath.heldLevel(0f, struck, strike))
        // slid toward the bottom (front edge): louder, to the note's full level at the edge
        assertTrue(StrikeMath.heldLevel(0.6f, struck, strike) > strike)
        assertEquals(127, StrikeMath.heldLevel(1f, struck, strike))
        val path = (0..100).map { StrikeMath.heldLevel(it / 100f, struck, strike) }
        assertTrue(path.zipWithNext().all { (a, b) -> a <= b })
        // struck at either edge
        assertEquals(127, StrikeMath.heldLevel(1f, 1f, 127))
        assertEquals(64, StrikeMath.heldLevel(0.5f, 1f, 127))
        assertEquals(strike, StrikeMath.heldLevel(0f, 0f, strike))
        assertEquals(127, StrikeMath.heldLevel(1f, 0f, strike))
    }
}
