package com.example.fmutate_app.fmutate

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.cos
import kotlin.math.sin

class MotionMathTest {
    private val g = MotionMath.G

    // gravity's reaction (what the accelerometer reads at rest) for a phone flat on its back, then rolled
    // [roll] degrees to the right edge down and pitched [pitch] degrees top edge up
    private fun gravity(roll: Double, pitch: Double): FloatArray {
        val r = Math.toRadians(roll)
        val p = Math.toRadians(pitch)
        return floatArrayOf((-sin(r) * g).toFloat(), (sin(p) * cos(r) * g).toFloat(), (cos(p) * cos(r) * g).toFloat())
    }

    @Test
    fun tiltReadsRollAndPitchFromGravity() {
        val a = gravity(20.0, 0.0)
        assertEquals(20f, MotionMath.roll(a[0], a[1], a[2]), 0.01f)
        val b = gravity(0.0, 30.0)
        assertEquals(30f, MotionMath.pitch(b[1], b[2]), 0.01f)
        assertEquals(0f, MotionMath.roll(b[0], b[1], b[2]), 0.01f)
        // the other way
        val c = gravity(-15.0, -10.0)
        assertEquals(-15f, MotionMath.roll(c[0], c[1], c[2]), 0.01f)
        assertEquals(-10f, MotionMath.pitch(c[1], c[2]), 0.3f)
    }

    @Test
    fun screenAxesFollowTheDisplayRotation() {
        val out = FloatArray(2)
        MotionMath.toScreen(0, 1f, 2f, out); assertEquals(1f, out[0]); assertEquals(2f, out[1])
        // landscape, turned left (ROTATION_90): the device's top is the screen's left
        MotionMath.toScreen(1, 1f, 2f, out); assertEquals(-2f, out[0]); assertEquals(1f, out[1])
        MotionMath.toScreen(3, 1f, 2f, out); assertEquals(2f, out[0]); assertEquals(-1f, out[1])
    }

    @Test
    fun valuesMoveRelativeToEngageWithADeadZone() {
        // inside the dead zone nothing moves: a hand's tremor, or picking up a held phone's first wobble
        assertEquals(0.3f, MotionMath.value(0.3f, 1.9f, 45f), 0f)
        assertEquals(0.3f, MotionMath.value(0.3f, -2f, 45f), 0f)
        // past it, the whole range over `range` degrees, from where the value was (touch never jumps it)
        assertEquals(0.3f + 10f / 45f, MotionMath.value(0.3f, 12f, 45f), 1e-6f)
        assertEquals(0.3f - 10f / 45f, MotionMath.value(0.3f, -12f, 45f), 1e-6f)
        assertEquals(1f, MotionMath.value(0.3f, 80f, 45f), 0f)
        assertEquals(0f, MotionMath.value(0.3f, -80f, 30f), 0f)
    }

    @Test
    fun anglesWrapAroundUpright() {
        assertEquals(20f, MotionMath.angleDiff(-170f, 170f), 1e-4f)
        assertEquals(-20f, MotionMath.angleDiff(170f, -170f), 1e-4f)
    }

    @Test
    fun encodersGetAKnobDragOfClicksOverTheRange() {
        // 45° past the dead zone = a 200 dp drag = 33 clicks at 6 dp a click
        assertEquals(33, MotionMath.clicks(47f, 45f, 6f, invert = false))
        assertEquals(-33, MotionMath.clicks(47f, 45f, 6f, invert = true))
        assertEquals(0, MotionMath.clicks(2f, 45f, 6f, invert = false))
        assertEquals(-3, MotionMath.clicks(-6.5f, 45f, 6f, invert = false))
    }

    @Test
    fun onlyWholeStepsAreSent() {
        assertTrue(MotionMath.worthSending(0.5f, Float.NaN))
        assertFalse(MotionMath.worthSending(0.505f, 0.5f))
        assertTrue(MotionMath.worthSending(0.5f + 1f / 128f, 0.5f))
        // the ends are always reached
        assertTrue(MotionMath.worthSending(1f, 0.997f))
        assertFalse(MotionMath.worthSending(1f, 1f))
    }

    @Test
    fun pitchBendIsCentredAtHalf() {
        assertEquals(8192, MotionMath.bendRaw(0.5f))
        assertEquals(16383, MotionMath.bendRaw(1f))
        assertEquals(1, MotionMath.bendRaw(0f))
    }

    @Test
    fun shakesNeedTheThresholdAndAreSpacedByTheRefractoryTime() {
        assertEquals(0f, MotionMath.jolt(0f, 0f, g), 1e-6f)
        assertEquals(1.5f, MotionMath.jolt(0f, g * 2.5f, 0f), 1e-5f)
        val d = MotionMath.ShakeDetector(MotionMath.shakeThreshold("firm"))
        assertFalse(d.update(1.0f, 0))
        assertTrue(d.update(1.3f, 20))
        assertFalse(d.update(2.5f, 40))       // the same jolt still ringing
        assertFalse(d.update(1.5f, 260))
        assertTrue(d.update(1.5f, 280))
        // gentle takes less, hard more
        assertTrue(MotionMath.ShakeDetector(MotionMath.shakeThreshold("gentle")).update(0.7f, 0))
        assertFalse(MotionMath.ShakeDetector(MotionMath.shakeThreshold("hard")).update(1.9f, 0))
    }

    @Test
    fun aMotionControlParsesWithItsSettingsAndPitchBendIsShared() {
        val json = """{"format":"fmutate.layout/1","id":"m","name":"m","firmware":{"id":"obervave"},"frame":"landscape",
            "grid":{"cols":14,"rows":6},"pages":[{"id":"p","controls":[{"id":"t","type":"motion","at":{"col":0,"row":0,"w":1,"h":1},
            "motion":{"engage":"latch","range":30,"on_release":"spring_back","shake":"hard"},
            "bindings":[{"on":"y","to":{"midi":{"type":"pitch_bend","channel":2}}},{"on":"shake","to":{"key":7},"mode":"toggle"}]}]}]}"""
        val c = Layout.fromJson(JSONObject(json)).pages[0].controls[0]
        assertTrue(c.motionLatch)
        assertEquals(30, c.motionRange)
        assertTrue(c.motionSpringBack)
        assertEquals("hard", c.motionShake)
        assertEquals("bend:2", c.binding("y")!!.to.absoluteKey)
        assertEquals("toggle", c.binding("shake")!!.mode)
        assertEquals(1 to 1, minSize(c))
    }
}
