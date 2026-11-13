package com.example.fmutate_app.fmutate

import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.view.Surface
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.roundToInt
import kotlin.math.sign
import kotlin.math.sqrt

/*
 * Motion controls ("type": "motion", FMutate.Motion): a tile the player holds (or latches on) while moving the
 * phone. Its gestures drive bindings like an XY pad's axes and a button's press:
 *
 *   x      tilt X (roll; the right edge going down moves the value up)       a value
 *   y      tilt Y (pitch; the top edge coming up moves the value up)         a value
 *   twist  turning the phone about the screen's normal (gyroscope; clockwise) a value
 *   shake  a jolt of the phone (accelerometer)                                a press
 *   near   something over the proximity sensor                                a press
 *
 * Sensors are read here, on the main thread, never through the BEAM, and only while a motion control is engaged
 * (hold: a finger on the tile; latch: tapped on): engaging registers what its bindings need at SENSOR_DELAY_GAME,
 * the last control to let go unregisters. Values move relative to how the phone was held at engage (touch never
 * jumps a value, HANDOFF §6) and go through the surface's usual paths (rule 7 for absolute targets; encoder
 * clicks add). Readings allocate nothing: each engagement keeps its bindings and their state in arrays.
 */

/** The pure maths (unit-tested on the JVM, MotionMathTest). Angles in degrees, acceleration in m/s². */
object MotionMath {
    const val G = 9.80665f
    /** Tilt around the engage orientation that moves nothing: a hand's tremor. */
    const val DEAD_DEG = 2f
    /** Gravity low-pass (per reading at ~50 Hz): smooths the hand's jitter, follows a tilt within ~0.1 s. */
    const val LOW_PASS = 0.3f
    /** No second shake within this long of the first: one jolt rings for a few readings. */
    const val SHAKE_REFRACTORY_MS = 250L
    /** How long a shake holds a momentary press. */
    const val SHAKE_PRESS_MS = 120L
    /** A value target moves by at least this much per send (a MIDI CC's step). */
    const val STEP = 1f / 128f
    /** Gravity is trusted for tilt only while the phone accelerates less than this (g): a shake doesn't tilt. */
    const val STEADY_G = 0.35f

    /** Shake thresholds: acceleration beyond gravity, in g. */
    fun shakeThreshold(name: String): Float = when (name) {
        "gentle" -> 0.6f
        "hard" -> 2.0f
        else -> 1.2f
    }

    /**
     * Device axes to screen axes for a display rotation (Surface.ROTATION_*): x to the screen's right, y to its
     * top, whatever way the phone is turned. Writes into [out] (x, y).
     */
    fun toScreen(rotation: Int, x: Float, y: Float, out: FloatArray) {
        when (rotation) {
            1 -> { out[0] = -y; out[1] = x }
            2 -> { out[0] = -x; out[1] = -y }
            3 -> { out[0] = y; out[1] = -x }
            else -> { out[0] = x; out[1] = y }
        }
    }

    private const val DEG = (180.0 / PI).toFloat()

    /** Roll from gravity in screen axes: positive when the right edge goes down. */
    fun roll(sx: Float, sy: Float, sz: Float): Float = atan2(-sx, sqrt(sy * sy + sz * sz)) * DEG

    /** Pitch from gravity in screen axes: positive when the top edge comes up (towards the player). */
    fun pitch(sy: Float, sz: Float): Float = atan2(sy, sz) * DEG

    /** a − b on a circle, in −180..180 (a pitch passing through upright doesn't jump a whole turn). */
    fun angleDiff(a: Float, b: Float): Float {
        var d = (a - b) % 360f
        if (d > 180f) d -= 360f
        if (d < -180f) d += 360f
        return d
    }

    /** The movement past the dead zone: 0 inside ±[dead], then from 0 on. */
    fun deadZone(d: Float, dead: Float = DEAD_DEG): Float = if (abs(d) <= dead) 0f else d - dead * sign(d)

    /** A value target's value: [start] at engage, its whole span over [rangeDeg] of movement. */
    fun value(start: Float, deltaDeg: Float, rangeDeg: Float): Float =
        (start + deadZone(deltaDeg) / rangeDeg).coerceIn(0f, 1f)

    /**
     * Clicks an encoder should have had since engage: [rangeDeg] of movement is a [potDp] knob drag
     * (the pot's full range), at [ptPerClick] dp per click.
     */
    fun clicks(deltaDeg: Float, rangeDeg: Float, ptPerClick: Float, invert: Boolean, potDp: Float = 200f): Int {
        val n = (deadZone(deltaDeg) / rangeDeg * potDp / ptPerClick).toInt()
        return if (invert) -n else n
    }

    /** Whether a value moved enough to send: a whole [STEP], or onto either end. */
    fun worthSending(v: Float, last: Float): Boolean =
        last.isNaN() || abs(v - last) >= STEP || (v != last && (v == 0f || v == 1f))

    /** MIDI pitch bend (14 bit) for a value: 0.5 is the centre (8192). */
    fun bendRaw(v: Float): Int = (8192 + (v - 0.5f) * 2f * 8191f).roundToInt().coerceIn(0, 16383)

    /** Acceleration beyond gravity, in g. */
    fun jolt(x: Float, y: Float, z: Float): Float = abs(sqrt(x * x + y * y + z * z) / G - 1f)

    /** Turns jolts into shakes: above the threshold, at most one per refractory period. */
    class ShakeDetector(var threshold: Float) {
        private var last = Long.MIN_VALUE / 2

        fun update(jolt: Float, nowMs: Long): Boolean {
            if (jolt < threshold || nowMs - last < SHAKE_REFRACTORY_MS) return false
            last = nowMs
            return true
        }
    }
}

/** What a motion control does to the surface's targets (InstrumentView supplies these). */
interface MotionSink {
    /** Set an absolute target (pot, MIDI CC, pitch bend) to [v]; false when rule 7 refused it. */
    fun value(c: Control, t: Target, v: Float): Boolean
    /** Send [n] encoder clicks. */
    fun clicks(c: Control, t: Target.Encoder, n: Int)
    /** A press binding goes down or up. */
    fun fire(t: Target, down: Boolean)
    /** The current value of an absolute target, 0.5 if nobody set it. */
    fun current(key: String): Float
    /** A motion control let go: values it held back from the surface's state can be shown now. */
    fun settle()
}

/** One engaged motion control: its bindings in arrays, the orientation at engage, what it sent. */
private class Engagement(val c: Control, val rotation: Int, val on: BooleanArray /* presses: down now / toggled on */) {
    val range = c.motionRange.toFloat()
    val gestures = Array(c.bindings.size) { c.bindings[it].on }
    val targets = Array(c.bindings.size) { c.bindings[it].to }
    val toggle = BooleanArray(c.bindings.size) { c.bindings[it].mode == "toggle" }
    val keys = Array(c.bindings.size) { c.bindings[it].to.absoluteKey }
    val start = FloatArray(c.bindings.size)                   // absolute targets: their value at engage
    val sent = FloatArray(c.bindings.size)                    // and what it last sent (start: nothing moved yet)
    val clicks = IntArray(c.bindings.size)                    // encoders: clicks sent since engage
    val needsAccel = gestures.any { it == "x" || it == "y" || it == "shake" }
    val needsGyro = gestures.any { it == "twist" }
    val needsProx = gestures.any { it == "near" }

    val gravity = FloatArray(3)
    var haveGravity = false
    var roll0 = 0f
    var pitch0 = 0f
    var roll = 0f
    var pitch = 0f
    var twist = 0f
    var gyroNs = 0L
    val shake = MotionMath.ShakeDetector(MotionMath.shakeThreshold(c.motionShake))
    var shakeUpAt = 0L                                       // when a momentary shake press lets go
    var near = false
}

/**
 * The surface's motion controls: engages and disengages them, registers the sensors the engaged ones need and
 * nothing while none is, and turns readings into the sink's sends.
 */
class MotionControls(private val sm: SensorManager?, private val sink: () -> MotionSink) : SensorEventListener {
    private val accel = sm?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    private val gyro = sm?.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
    private val prox = sm?.getDefaultSensor(Sensor.TYPE_PROXIMITY)
    private val engaged = ArrayList<Engagement>()
    // per control: its press bindings that are down or toggled on, kept across engagements (a toggle stays on)
    private val presses = HashMap<String, Pair<Control, BooleanArray>>()
    private val screen = FloatArray(2)
    private var registered = 0                                 // bit 0 accel, 1 gyro, 2 proximity

    /** Bumps when a tile's dot moved: only the motion layer reads it. */
    var frame by mutableIntStateOf(0)
        private set

    val hasAccel get() = accel != null

    private fun find(id: String): Engagement? {
        for (k in engaged.indices) if (engaged[k].c.id == id) return engaged[k]
        return null
    }

    fun isEngaged(id: String) = find(id) != null

    /** The dot of an engaged tile: tilt X and Y in −1..1 of its range (0, 0 when not engaged). */
    fun dotX(id: String): Float = find(id)?.let { (MotionMath.angleDiff(it.roll, it.roll0) / it.range).coerceIn(-1f, 1f) } ?: 0f
    fun dotY(id: String): Float = find(id)?.let { (MotionMath.angleDiff(it.pitch, it.pitch0) / it.range).coerceIn(-1f, 1f) } ?: 0f

    fun engage(c: Control, rotation: Int) {
        if (find(c.id) != null) return
        val on = presses[c.id]?.takeIf { it.first == c }?.second ?: BooleanArray(c.bindings.size).also { presses[c.id] = c to it }
        val e = Engagement(c, rotation, on)
        val s = sink()
        for (i in e.keys.indices) e.keys[i]?.let { e.start[i] = s.current(it); e.sent[i] = e.start[i] }
        engaged.add(e)
        reregister()
    }

    /** Let go: momentary presses up, values stay or spring back (as the XY pad's on_release). */
    fun disengage(id: String) {
        val e = find(id) ?: return
        engaged.remove(e)
        val s = sink()
        for (i in e.targets.indices) {
            val t = e.targets[i]
            val g = e.gestures[i]
            if (g == "shake" || g == "near") {
                if (e.on[i] && !e.toggle[i]) { e.on[i] = false; s.fire(t, false) }
            } else if (e.c.motionSpringBack) {
                if (t is Target.Encoder) { if (e.clicks[i] != 0) s.clicks(e.c, t, -e.clicks[i]) }
                else if (e.sent[i] != e.start[i]) s.value(e.c, t, e.start[i])
            }
        }
        s.settle()
        reregister()
        frame++
    }

    /** Keep only these controls engaged (a page change, a new layout). */
    fun retain(ids: Set<String>) {
        engaged.filter { it.c.id !in ids }.forEach { disengage(it.c.id) }
    }

    fun disengageAll() = engaged.map { it.c.id }.forEach { disengage(it) }

    private fun reregister() {
        var want = 0
        for (e in engaged) {
            if (e.needsAccel || e.needsGyro) want = want or 1     // twist alone still shows the dot's tilt
            if (e.needsGyro) want = want or 2
            if (e.needsProx) want = want or 4
        }
        if (want == registered || sm == null) return
        sm.unregisterListener(this)
        if (want and 1 != 0 && accel != null) sm.registerListener(this, accel, SensorManager.SENSOR_DELAY_GAME)
        if (want and 2 != 0 && gyro != null) sm.registerListener(this, gyro, SensorManager.SENSOR_DELAY_GAME)
        if (want and 4 != 0 && prox != null) sm.registerListener(this, prox, SensorManager.SENSOR_DELAY_NORMAL)
        registered = want
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    override fun onSensorChanged(ev: SensorEvent) {
        if (engaged.isEmpty()) return
        val s = sink()
        val nowMs = ev.timestamp / 1_000_000
        var moved = false
        for (k in engaged.indices) {
            val e = engaged[k]
            when (ev.sensor.type) {
                Sensor.TYPE_ACCELEROMETER -> moved = accelerometer(e, s, ev.values, nowMs) || moved
                Sensor.TYPE_GYROSCOPE -> gyroscope(e, s, ev.values[2], ev.timestamp)
                Sensor.TYPE_PROXIMITY -> proximity(e, s, ev.values[0] < (prox?.maximumRange ?: 5f).coerceAtMost(5f))
            }
        }
        if (moved) frame++
    }

    private fun accelerometer(e: Engagement, s: MotionSink, v: FloatArray, nowMs: Long): Boolean {
        // shake: the raw jolt, before smoothing
        val jolt = MotionMath.jolt(v[0], v[1], v[2])
        if (e.needsAccel) {
            val shook = e.shake.update(jolt, nowMs)
            for (i in e.gestures.indices) if (e.gestures[i] == "shake") {
                if (shook) {
                    if (e.toggle[i]) { e.on[i] = !e.on[i]; s.fire(e.targets[i], e.on[i]) }
                    else if (!e.on[i]) { e.on[i] = true; s.fire(e.targets[i], true); e.shakeUpAt = nowMs + MotionMath.SHAKE_PRESS_MS }
                } else if (e.on[i] && !e.toggle[i] && nowMs >= e.shakeUpAt) { e.on[i] = false; s.fire(e.targets[i], false) }
            }
        }
        if (e.haveGravity && jolt > MotionMath.STEADY_G) return false
        val g = e.gravity
        if (!e.haveGravity) {
            g[0] = v[0]; g[1] = v[1]; g[2] = v[2]
        } else {
            g[0] += MotionMath.LOW_PASS * (v[0] - g[0]); g[1] += MotionMath.LOW_PASS * (v[1] - g[1]); g[2] += MotionMath.LOW_PASS * (v[2] - g[2])
        }
        MotionMath.toScreen(e.rotation, g[0], g[1], screen)
        val oldRoll = e.roll
        val oldPitch = e.pitch
        e.roll = MotionMath.roll(screen[0], screen[1], g[2])
        e.pitch = MotionMath.pitch(screen[1], g[2])
        if (!e.haveGravity) {
            e.haveGravity = true
            e.roll0 = e.roll
            e.pitch0 = e.pitch
            return true
        }
        axes(e, s, "x", MotionMath.angleDiff(e.roll, e.roll0))
        axes(e, s, "y", MotionMath.angleDiff(e.pitch, e.pitch0))
        return abs(e.roll - oldRoll) > 0.2f || abs(e.pitch - oldPitch) > 0.2f
    }

    private fun gyroscope(e: Engagement, s: MotionSink, wz: Float, ns: Long) {
        if (e.gyroNs != 0L) {
            val dt = (ns - e.gyroNs) / 1e9f
            // z points out of the screen: a clockwise turn (seen from the front) is a negative rate
            if (dt in 0f..0.5f) e.twist -= wz * dt * (180f / PI.toFloat())
            axes(e, s, "twist", e.twist)
        }
        e.gyroNs = ns
    }

    private fun proximity(e: Engagement, s: MotionSink, near: Boolean) {
        if (near == e.near) return
        e.near = near
        for (i in e.gestures.indices) if (e.gestures[i] == "near") {
            if (e.toggle[i]) { if (near) { e.on[i] = !e.on[i]; s.fire(e.targets[i], e.on[i]) } }
            else { e.on[i] = near; s.fire(e.targets[i], near) }
        }
    }

    /** One axis moved [delta] degrees from engage: its value bindings follow. */
    private fun axes(e: Engagement, s: MotionSink, gesture: String, delta: Float) {
        for (i in e.gestures.indices) {
            if (e.gestures[i] != gesture) continue
            when (val t = e.targets[i]) {
                is Target.Encoder -> {
                    val want = MotionMath.clicks(delta, e.range, t.ptPerClick, t.invert)
                    val n = want - e.clicks[i]
                    if (n != 0) { e.clicks[i] = want; s.clicks(e.c, t, n) }
                }
                else -> {
                    if (e.keys[i] == null) continue
                    val v = MotionMath.value(e.start[i], delta, e.range)
                    if (MotionMath.worthSending(v, e.sent[i]) && s.value(e.c, t, v)) e.sent[i] = v
                }
            }
        }
    }

    /** The surface is going: stop listening, let go of presses (toggled ones too). */
    fun close() {
        val s = sink()
        for ((c, on) in presses.values) for (i in on.indices) if (on[i]) s.fire(c.bindings[i].to, false)
        presses.clear()
        engaged.clear()
        sm?.unregisterListener(this)
        registered = 0
        s.settle()
    }
}

/** Surface.ROTATION_* of the display a view is on. */
fun displayRotation(view: android.view.View): Int = view.display?.rotation ?: Surface.ROTATION_0
