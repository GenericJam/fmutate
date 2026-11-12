package com.example.fmutate_app.fmutate

import android.content.Context
import android.graphics.Paint
import android.graphics.Typeface
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.SystemClock
import android.view.Surface
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameMillis
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/*
 * The Opling (docs/design/creature.md): a small creature made of FM operators, here as the menu button of every
 * layout (HANDOFF §4). Canvas primitives only (HANDOFF §11): rounded rects, circles and one stroked curl; no
 * gradients, no rotation; animation only moves and scales.
 *
 * Moods FMutate can see (creature.md "Moods"): idle (blinks every 3–6 s, pupils follow tilt), playing (bobs on
 * each note, ticks either side), booting (eggshell), crashed (pupils crossed, three amber dots circling),
 * safe mode (asleep, "zZ"). The pose only changes when something moves, so a still Opling costs no frames.
 */

/** Ops per column (carrier at the bottom), the head column, and "twins": one eye on each of the first two columns. */
class OplingForm(val cols: IntArray, val head: Int, val split: Boolean = false) {
    val maxOps = cols.max()

    /** Unit size (s = 1), padding for the antenna included. */
    val width = cols.size * OP_W + (cols.size - 1) * COL_GAP
    val height = PAD_TOP + maxOps * (OP_H + OP_GAP) + FOOT_H

    fun colX(ci: Int) = ci * (OP_W + COL_GAP)
    fun colTop(ci: Int) = PAD_TOP + (maxOps - cols[ci]) * (OP_H + OP_GAP)

    companion object {
        /** The firmwares don't report their algorithm yet, so the menu button is always the twins. */
        val TWINS = OplingForm(intArrayOf(2, 2), head = 0, split = true)
    }
}

enum class OplingMood { Idle, Play, Hatch, Dizzy, Sleep }

// anatomy, s = 1 (creature.md)
private const val OP_W = 22f
private const val OP_H = 14f
private const val OP_R = 4f
private const val OP_GAP = 2.5f
private const val COL_GAP = 3f
private const val PAD_TOP = 11f
private const val FOOT_W = 6f
private const val FOOT_H = 3.2f
private const val FOOT_R = 1.6f
private const val EYE_D = 8f
private const val PUPIL_D = 3.8f
private const val EYE_ROOM = (EYE_D - PUPIL_D) / 2

// lime tint
private val BODY = Color(0xFFC6F24E)
private val CARRIER = Color(0xFF93CF32)
private val FEET = Color(0xFF5E8F1A)
private val ANTENNA = Color(0xFFA98BFF)
private val EYE = Color(0xFFFFFFFF)
private val PUPIL = Color(0xFF17141F)
private val TICK = Color(0xFFA9A3B8)
private val WARM = Color(0xFFFFB547)
private val SHELL = Color(0xFFF3EBD6)
private val SHELL_EDGE = Color(0xFFCDBF9C)

// the menu button (Flat-Instrument board): a 48 dp raised circle, the Opling at 0.62
private val BUTTON = Color(0xFF221F2B)
private val BUTTON_PRESSED = Color(0xFF34304A)
private const val BUTTON_DP = 48f
private const val BUTTON_SCALE = 0.62f

// animation (creature.md "Animation")
private const val BLINK_MS = 90L
private const val BOB_MS = 360L
private const val BOB_STAGGER_MS = 30L
private const val PUPIL_TAU_MS = 40f          // ~120 ms settle
private const val ORBIT_MS = 900L
private const val DIZZY_MS = 2500L            // a crash restarts at once: stay dizzy a moment so it shows
private const val PLAY_LINGER_MS = 1200L      // still "playing" this long after the last note lifts
private const val TILT_FULL = 0.35f           // g change (high-passed) that looks all the way

/** The antenna curl in its 9 × 11 box (Creature board). */
private val CURL = Path().apply {
    moveTo(2f, 11f)
    cubicTo(2f, 6f, 2f, 2f, 5.5f, 2f)
    cubicTo(8f, 2f, 8.2f, 5.5f, 5.8f, 5.6f)
    cubicTo(4.3f, 5.7f, 4.3f, 3.9f, 5.4f, 3.9f)
}

/** What moves, and what moves it. Only [frame] is snapshot state: the Canvas redraws when the pose changes. */
private class OplingAnim(var restarts: Int) {
    var frame by mutableIntStateOf(0)
    val wake = Channel<Unit>(Channel.CONFLATED)

    // inputs
    var phase = ""
    var quarantined = false
    var held = 0
    var beatAt = Long.MIN_VALUE / 2
    var lastNoteAt = Long.MIN_VALUE / 2
    var dizzyUntil = 0L
    var tiltX = 0f
    var tiltY = 0f

    // pose
    var mood = OplingMood.Idle
    var blink = 1f
    var lookX = 0f
    var lookY = 0f
    val drop = FloatArray(6)
    var orbit = 0f
    private var blinkAt = 0L
    private var last = 0L
    private var signature = 0L

    fun inputs(phase: String, quarantined: Boolean, restarts: Int, now: Long) {
        if (restarts > this.restarts) dizzyUntil = now + DIZZY_MS
        this.restarts = restarts
        this.phase = phase
        this.quarantined = quarantined
        wake.trySend(Unit)
    }

    fun notes(n: Int, now: Long) {
        if (n > held) beatAt = now
        if (n == 0 && held > 0) lastNoteAt = now
        held = n
        wake.trySend(Unit)
    }

    /** Advances the pose to [now]; returns how long nothing will move (0: animate the next frame). */
    fun step(form: OplingForm, now: Long): Long {
        val dt = (now - last).coerceIn(0, 50).toFloat()
        last = now
        mood = when {
            phase == "safe_mode" || quarantined -> OplingMood.Sleep
            phase == "crashed" || now < dizzyUntil -> OplingMood.Dizzy
            phase == "booting" -> OplingMood.Hatch
            held > 0 || now - lastNoteAt < PLAY_LINGER_MS -> OplingMood.Play
            else -> OplingMood.Idle
        }
        var wait = Long.MAX_VALUE
        if (mood == OplingMood.Dizzy) wait = min(wait, dizzyUntil - now)
        if (mood == OplingMood.Play && held == 0) wait = min(wait, lastNoteAt + PLAY_LINGER_MS - now)

        // blink: eye height 100 % → 20 % → 100 % over 90 ms, every 3–6 s
        blink = 1f
        if (mood == OplingMood.Idle || mood == OplingMood.Play || mood == OplingMood.Hatch) {
            if (blinkAt == 0L) blinkAt = now + nextBlink()
            val u = now - blinkAt
            when {
                u < 0 -> wait = min(wait, -u)
                u < BLINK_MS -> { blink = 1f - 0.8f * (1f - abs(2f * u / BLINK_MS - 1f)); wait = 0 }
                else -> { blinkAt = now + nextBlink(); wait = min(wait, blinkAt - now) }
            }
        } else blinkAt = 0L

        // pupils: sprung towards the tilt (looking up from the eggshell)
        val follow = mood == OplingMood.Idle || mood == OplingMood.Play
        val tx = if (follow) tiltX else 0f
        val ty = if (follow) tiltY else if (mood == OplingMood.Hatch) -1f else 0f
        val k = 1f - exp(-dt / PUPIL_TAU_MS)
        lookX += (tx - lookX) * k
        lookY += (ty - lookY) * k
        if (abs(tx - lookX) > 0.02f || abs(ty - lookY) > 0.02f) wait = 0 else { lookX = tx; lookY = ty }

        // bob: on each note every column drops 4 % of the body height and springs back, 30 ms apart
        val bobbing = mood == OplingMood.Play && now - beatAt < BOB_MS + BOB_STAGGER_MS * form.cols.size
        for (ci in form.cols.indices) {
            val u = (now - beatAt - BOB_STAGGER_MS * ci).toFloat()
            drop[ci] = if (bobbing && u >= 0 && u < BOB_MS) 0.04f * form.height * exp(-u / 90f) * cos(2f * PI.toFloat() * u / 300f) else 0f
        }
        if (bobbing) wait = 0

        orbit = if (mood == OplingMood.Dizzy) { wait = 0; (now % ORBIT_MS).toFloat() / ORBIT_MS } else 0f

        // redraw only when what's drawn changed
        var sig = mood.ordinal.toLong()
        sig = sig * 31 + (blink * 20).roundToInt()
        sig = sig * 31 + (lookX * 16).roundToInt()
        sig = sig * 31 + (lookY * 16).roundToInt()
        for (ci in form.cols.indices) sig = sig * 31 + (drop[ci] * 10).roundToInt()
        sig = sig * 31 + (orbit * 64).roundToInt()
        if (sig != signature) {
            signature = sig
            frame++
        }
        return wait
    }

    private fun nextBlink() = 3000L + (Math.random() * 3000).toLong()
}

/**
 * The menu button: the Opling in a 48 dp circle, centred in its cell (x, y, w, h in dp). Pressed moves 2 dp
 * (HANDOFF §11). [notesHeld] counts the notes held on the surface: a new one is a beat.
 */
@Composable
internal fun OplingMenuButton(
    x: Float, y: Float, w: Float, h: Float,
    pressed: () -> Boolean,
    notesHeld: () -> Int,
    phase: String,
    quarantined: Boolean,
    restarts: Int,
) {
    val form = OplingForm.TWINS
    val anim = remember { OplingAnim(restarts) }
    val painter = remember { OplingPainter() }
    val held by rememberUpdatedState(notesHeld)

    SideEffect { anim.inputs(phase, quarantined, restarts, SystemClock.uptimeMillis()) }
    LaunchedEffect(anim) { snapshotFlow { held() }.collect { anim.notes(it, SystemClock.uptimeMillis()) } }
    LaunchedEffect(anim) {
        var wait = 0L
        while (true) {
            wait = if (wait <= 0L) withFrameMillis { anim.step(form, SystemClock.uptimeMillis()) }
            else {
                withTimeoutOrNull(wait) { anim.wake.receive() }
                anim.step(form, SystemClock.uptimeMillis())
            }
        }
    }
    TiltEffect(anim)

    Canvas(modifier = Modifier.offset(x.dp, y.dp).size(w.dp, h.dp).graphicsLayer()) {
        if (anim.frame < 0) return@Canvas
        val d = density
        val down = pressed()
        val side = min(BUTTON_DP, min(w, h))
        val cx = w / 2 * d
        val cy = (h / 2 + if (down) 2f else 0f) * d
        drawCircle(if (down) BUTTON_PRESSED else BUTTON, side / 2 * d, Offset(cx, cy))
        val s = side / BUTTON_DP * BUTTON_SCALE * d
        painter.draw(this, form, anim, cx - form.width * s / 2, cy - form.height * s / 2, s)
    }
}

/** Pupils follow tilt: the accelerometer, high-passed (changes in tilt, not how the phone is held), in screen axes. */
@Composable
private fun TiltEffect(anim: OplingAnim) {
    val context = LocalContext.current
    val view = LocalView.current
    DisposableEffect(anim) {
        val sm = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
        val sensor = sm?.getDefaultSensor(Sensor.TYPE_GRAVITY) ?: sm?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        var baseX = Float.NaN
        var baseY = 0f
        var lastT = 0L
        val listener = object : SensorEventListener {
            override fun onSensorChanged(e: SensorEvent) {
                // device axes → "downhill" in screen axes (x right, y down)
                val nx = -e.values[0] / SensorManager.GRAVITY_EARTH
                val ny = e.values[1] / SensorManager.GRAVITY_EARTH
                val (gx, gy) = when (view.display?.rotation) {
                    Surface.ROTATION_90 -> -ny to nx
                    Surface.ROTATION_180 -> -nx to -ny
                    Surface.ROTATION_270 -> ny to -nx
                    else -> nx to ny
                }
                val t = e.timestamp / 1_000_000
                if (baseX.isNaN()) { baseX = gx; baseY = gy; lastT = t }
                val k = 1f - exp(-(t - lastT).coerceIn(0, 200) / 1500f)
                lastT = t
                baseX += (gx - baseX) * k
                baseY += (gy - baseY) * k
                var lx = (gx - baseX) / TILT_FULL
                var ly = (gy - baseY) / TILT_FULL
                val len = hypot(lx, ly)
                if (len > 1f) { lx /= len; ly /= len }
                if (abs(lx - anim.tiltX) > 0.06f || abs(ly - anim.tiltY) > 0.06f) {
                    anim.tiltX = lx
                    anim.tiltY = ly
                    anim.wake.trySend(Unit)
                }
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
        }
        if (sm != null && sensor != null) sm.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_UI)
        onDispose { sm?.unregisterListener(listener) }
    }
}

/** Draws an Opling with its top-left (antenna padding included) at (left, top) px, `s` px per unit. */
private class OplingPainter {
    private val shell = Path()
    private val zSmall = zPaint()
    private val zBig = zPaint()

    private fun zPaint() = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.create(Typeface.MONOSPACE, 700, false)
        color = TICK.toArgb()
    }

    fun draw(ds: DrawScope, form: OplingForm, a: OplingAnim, left: Float, top: Float, s: Float) = with(ds) {
        fun rr(x: Float, y: Float, w: Float, h: Float, r: Float, c: Color) =
            drawRoundRect(c, Offset(left + x * s, top + y * s), Size(w * s, h * s), CornerRadius(r * s))
        fun dot(x: Float, y: Float, dia: Float, c: Color) = drawCircle(c, dia / 2 * s, Offset(left + x * s, top + y * s))

        val mood = a.mood
        val headTop = form.colTop(form.head) + a.drop[form.head]
        val headX = form.colX(form.head)

        for (ci in form.cols.indices) {
            val cnt = form.cols[ci]
            val x = form.colX(ci)
            val y0 = form.colTop(ci) + a.drop[ci]
            for (i in 0 until cnt) rr(x, y0 + i * (OP_H + OP_GAP), OP_W, OP_H, OP_R, if (i == cnt - 1) CARRIER else BODY)
            val fy = y0 + cnt * (OP_H + OP_GAP)
            rr(x + 3f, fy, FOOT_W, FOOT_H, FOOT_R, FEET)
            rr(x + OP_W - 3f - FOOT_W, fy, FOOT_W, FOOT_H, FOOT_R, FEET)
            // eyes on the head op, or one on each of the first two columns (twins)
            if (form.split && ci < 2) eye(ds, a, left, top, s, x + if (ci == 0) OP_W * 0.3f else OP_W * 0.7f, y0, ci == 0)
            else if (!form.split && ci == form.head) {
                eye(ds, a, left, top, s, x + OP_W * 0.3f, y0, true)
                eye(ds, a, left, top, s, x + OP_W * 0.7f, y0, false)
            }
        }
        // antenna: the feedback loop, on the head op
        withTransform({
            translate(left + (headX + OP_W * 0.56f) * s, top + (headTop - 10.5f) * s)
            scale(s, s, Offset.Zero)
        }) {
            drawPath(CURL, ANTENNA, style = Stroke(1.7f, cap = StrokeCap.Round, join = StrokeJoin.Round))
        }

        val w = form.width
        val h = form.height
        when (mood) {
            OplingMood.Play -> {
                rr(-5f, h * 0.32f, 1.6f, 6f, 0.8f, TICK)
                rr(-8.5f, h * 0.38f, 1.6f, 4f, 0.8f, TICK)
                rr(w + 3.4f, h * 0.32f, 1.6f, 6f, 0.8f, TICK)
                rr(w + 6.9f, h * 0.38f, 1.6f, 4f, 0.8f, TICK)
            }
            OplingMood.Dizzy -> for (i in 0 until 3) {
                // three amber dots circling above the head (they move; nothing rotates)
                val t = 2f * PI.toFloat() * (a.orbit + i / 3f) - PI.toFloat() / 2
                dot(headX + OP_W * 0.5f + OP_W * 0.35f * cos(t), headTop - 5.5f + 2.5f * sin(t), 2.6f, WARM)
            }
            OplingMood.Sleep -> {
                val zx = left + (headX + OP_W + 1f) * s
                val base = top + (headTop - 11f + 9f * 0.85f) * s
                zSmall.textSize = 6f * s
                zBig.textSize = 9f * s
                val canvas = drawContext.canvas.nativeCanvas
                canvas.drawText("z", zx, base, zSmall)
                canvas.drawText("Z", zx + zSmall.measureText("z"), base, zBig)
            }
            OplingMood.Hatch -> {
                // zig-zag eggshell over the lower 58 % of the body (100 × 60 box, stretched)
                val bx = left - 3f * s
                val by = top + h * 0.42f * s
                val sx = (w + 6f) * s / 100f
                val sy = (h * 0.58f + 1f) * s / 60f
                shell.reset()
                shell.moveTo(bx, by + 14 * sy)
                for (i in 1..10) shell.lineTo(bx + 10 * i * sx, by + (if (i % 2 == 1) 3 else 14) * sy)
                shell.lineTo(bx + 100 * sx, by + 42 * sy)
                shell.quadraticBezierTo(bx + 100 * sx, by + 60 * sy, bx + 82 * sx, by + 60 * sy)
                shell.lineTo(bx + 18 * sx, by + 60 * sy)
                shell.quadraticBezierTo(bx, by + 60 * sy, bx, by + 42 * sy)
                shell.close()
                drawPath(shell, SHELL)
                drawPath(shell, SHELL_EDGE, style = Stroke(1.5f * density))
            }
            OplingMood.Idle -> {}
        }
    }

    /** One eye centred at (cx, opTop + 2): white, pokes 2 above the op; pupil sprung inside it. */
    private fun eye(ds: DrawScope, a: OplingAnim, left: Float, top: Float, s: Float, cx: Float, opTop: Float, isLeft: Boolean) = with(ds) {
        val ex = left + (cx - EYE_D / 2) * s
        if (a.mood == OplingMood.Sleep) {
            // closed: a thin dark bar
            drawRoundRect(PUPIL, Offset(ex, top + (opTop + 2f) * s), Size(EYE_D * s, 1.6f * s), CornerRadius(1f * s))
            return@with
        }
        val eh = EYE_D * a.blink
        val ecy = opTop + 2f
        drawRoundRect(EYE, Offset(ex, top + (ecy - eh / 2) * s), Size(EYE_D * s, eh * s), CornerRadius(EYE_D / 2 * s, eh / 2 * s))
        // crashed: pupils crossed inward
        val dizzy = a.mood == OplingMood.Dizzy
        val lx = if (dizzy) (if (isLeft) 1f else -1f) else a.lookX
        val ly = if (dizzy) 0.4f else a.lookY
        val px = cx + lx * EYE_ROOM * 0.85f
        val py = ecy + ly * EYE_ROOM * 0.85f * a.blink
        val ph = PUPIL_D * a.blink
        drawOval(PUPIL, Offset(left + (px - PUPIL_D / 2) * s, top + (py - ph / 2) * s), Size(PUPIL_D * s, ph * s))
    }
}
