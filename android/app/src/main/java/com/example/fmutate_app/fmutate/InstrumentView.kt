package com.example.fmutate_app.fmutate

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ActivityInfo
import android.graphics.Paint
import android.graphics.Typeface
import android.view.HapticFeedbackConstants
import android.view.WindowManager
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.changedToDownIgnoreConsumed
import androidx.compose.ui.input.pointer.changedToUpIgnoreConsumed
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/*
 * The instrument surface: every control of a layout, drawn and played natively (HANDOFF §5–§8). Touch never
 * waits for the BEAM: press feedback is painted on touch-down, and what the firmware should see goes out as
 * compact events:
 *
 *   send("in", {t: "key", k, d}) | {t: "button", id, d} | {t: "encoder", id, clicks} | {t: "pot", v}
 *            | {t: "midi", bytes: [..]}
 *   send("menu"), send("pages"), send("edit"), send("page", {id}), send("use_classic")
 *
 * The firmware's screen and LEDs come from the engine's shared memory (FirmwareShm), not from props.
 *
 * Drawing is split into layers so a frame redraws only what changed: the controls (an offscreen layer,
 * re-rendered on presses, values and LEDs), the firmware screen (each new engine frame), the Opling menu
 * button (its own animation) and an overlay (fingers, bubbles, banner).
 *
 * Props: layout (JSON string), fb (path or null), master (0..1), bend (firmware takes pitch bend), phase
 * (instance phase), quarantined, restarts (both for the Opling's mood).
 */

private object C {
    val bg = Color(0xFF14121A)
    val raised = Color(0xFF221F2B)
    val raisedHi = Color(0xFF2A2636)
    val selected = Color(0xFF34304A)
    val lineSoft = Color(0xFF2E2A3B)
    val text = Color(0xFFF3EFF8)
    val text2 = Color(0xFFC9C3D6)
    val muted = Color(0xFFA9A3B8)
    val faint = Color(0xFF6B6580)
    val keyWhite = Color(0xFFECE7F2)
    val keyBlack = Color(0xFF2A2633)
    val keyLabelOnBlack = Color(0xFFB9B2C8)
    val ledOff = Color(0xFF3A3548)
    val ledOffOnWhite = Color(0xFFD3CCDD)
    val fm = Color(0xFFC6F24E)
    val fmDim = Color(0xFF7FA62A)
    val fmTint = Color(0xFF4C5A2A)
    val led = Color(0xFFFF9F2E)
    val sliderFill = Color(0xFF3A3450)
    val warn = Color(0xFFFFB547)
    val ink = Color(0xFF14121A)
    val bezel = Color(0xFF0B0A0F)
    val buttonFg = Color(0xFFE4DFEE)

    fun pad(name: String): Color = when (name) {
        "coral" -> Color(0xFFFF9A7A)
        "amber" -> Color(0xFFFFB547)
        "sky" -> Color(0xFF8FD8FF)
        "violet" -> Color(0xFFB9A2FF)
        else -> raised
    }
}

private val BUTTON_IDS = listOf("oct_down", "oct_up", "fx", "sel", "env", "lfo", "edit", "glo", "home", "save", "arp", "seq", "play", "rec")
private val NOTE_NAMES = listOf("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")
private fun isBlack(key: Int) = when ((53 + key) % 12) { 1, 3, 6, 8, 10 -> true; else -> false }
private val KEY_NAMES = Array(27) { key ->
    val n = 53 + key
    val name = NOTE_NAMES[n % 12]
    if (name == "C") "C${n / 12 - 1}" else name
}
private fun noteName(key: Int): String = KEY_NAMES[key]

/** Controls drawn on the keys layer: they change on every note and key LED. */
private val PLAYING_TYPES = setOf("keyboard", "pad_grid", "strum")

private const val FINE_HOLD_MS = 400L
private const val LONG_PRESS_MS = 500L
private const val EDIT_HOLD_MS = 600L
private const val STILL_DP = 4f
private const val POT_RANGE_DP = 200f
private const val ARROW_DP = 36f

/** What one finger is doing: it belongs to the control it first touched until it lifts (rule 1). */
private class Grab(
    val pointer: Long,
    val control: Control?,
    val start: Offset,
    val t0: Long,
) {
    var last = start
    var moved = false
    var fine = false
    var sub = -1                 // key / pad / string currently held by this finger
    var acc = 0f                 // encoder accumulation in dp
    var clicks = 0               // clicks sent during this grab (bubble, spring back)
    var startValues = mapOf<String, Float>()
    var longFired = false
}

/** A keyboard strip's key rects for one window of firmware keys in one rect. */
private class KeyGeometry(val window: IntRange, val rect: Grid.Rect, val keys: List<Pair<Int, Grid.Rect>>)

private class SurfaceState {
    var page by mutableIntStateOf(0)
    val pressed = mutableStateMapOf<String, Boolean>()     // control id: buttons, knobs, sliders, menu
    val held = mutableStateMapOf<String, Boolean>()        // "id#sub": keys, pads, strings (their own layer)
    val toggles = mutableStateMapOf<String, Boolean>()
    val values = mutableStateMapOf<String, Float>()        // absolute targets ("pot:master", "cc:1:74")
    val kbOffset = mutableStateMapOf<String, Int>()        // keyboard window shift, in firmware keys
    val fingers = mutableStateMapOf<Long, Offset>()        // dp
    val bubbles = mutableStateMapOf<String, String>()      // control id -> text
    val encoderTurns = mutableStateMapOf<String, Int>()    // control id -> clicks since its grab started
    var screenFrame by mutableIntStateOf(0)                // bumps on a new firmware screen frame
    var buttonLedFrame by mutableIntStateOf(0)             // bumps when a button LED changes
    var keyLedFrame by mutableIntStateOf(0)                // bumps when a key LED changes
    var leds = Triple(0, 0, 0)                             // replaced only when an LED changes
}

/**
 * Mob hands a fresh props map (and `send`) on every commit of the screen, including the two that follow each
 * input event; unpacking it into stable values lets Compose skip [InstrumentSurface] when nothing changed.
 */
@Composable
fun InstrumentView(props: Map<String, Any?>, send: (String, Map<String, Any>) -> Unit) {
    InstrumentSurface(
        layoutJson = props["layout"] as? String ?: return,
        fbPath = props["fb"] as? String,
        bendOk = props["bend"] == true,
        phase = props["phase"] as? String ?: "",
        master = (props["master"] as? Number)?.toFloat() ?: -1f,
        quarantined = props["quarantined"] == true,
        restarts = (props["restarts"] as? Number)?.toInt() ?: 0,
        editing = props["editing"] == true,
        pageProp = props["page"] as? String ?: "",
        addMenuJson = props["add_menu"] as? String,
        toastText = props["toast"] as? String ?: "",
        toastSeq = (props["toast_seq"] as? Number)?.toLong() ?: 0L,
        send = rememberUpdatedState(send),
    )
}

@Composable
private fun InstrumentSurface(
    layoutJson: String,
    fbPath: String?,
    bendOk: Boolean,
    phase: String,
    master: Float,
    quarantined: Boolean,
    restarts: Int,
    editing: Boolean,
    pageProp: String,
    addMenuJson: String?,
    toastText: String,
    toastSeq: Long,
    send: State<(String, Map<String, Any>) -> Unit>,
) {
    val layout = remember(layoutJson) { runCatching { Layout.parse(layoutJson) }.getOrNull() } ?: return
    val state = remember(layout.id) { SurfaceState() }
    val sendNow by send
    val density = LocalDensity.current.density
    val view = LocalView.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val ink = remember(density) { Ink(density) }
    var sizePx by remember { mutableStateOf(IntSize.Zero) }

    // seed the pot from the instance once; not a tracked read, or every value change would recompose the surface
    Snapshot.withoutReadObservation {
        if (master >= 0f && "pot:master" !in state.values) state.values["pot:master"] = master
    }

    // ── edit mode, pages, toasts, rule 7 (EditMode.kt, Rule7.kt; FMutate.Editor) ──
    val edit = remember { EditMode() }
    val rule7 = remember(layout.id) { Rule7() }
    val addMenu = remember(addMenuJson) { AddMenu.parse(addMenuJson) }
    var toast by remember { mutableStateOf("") }
    LaunchedEffect(layoutJson) { edit.layoutChanged() }
    LaunchedEffect(pageProp, layout) { layout.pages.indexOfFirst { it.id == pageProp }.takeIf { it >= 0 }?.let { state.page = it } }
    LaunchedEffect(toastSeq) {
        edit.layoutChanged() // a refused edit comes back as a toast: drop its proposal
        toast = toastText
        delay(2500)
        toast = ""
    }
    // ── end edit mode ──

    // the layout's frame never rotates while playing (HANDOFF §5), and the instrument takes the whole screen:
    // system bars hidden (a swipe brings them back for a moment), drawn under a display cutout. The 28 dp
    // side gutters keep the back gesture clear.
    DisposableEffect(layout.landscape) {
        val activity = context.findActivity()
        val window = activity?.window
        activity?.requestedOrientation =
            if (layout.landscape) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE else ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
        // window attributes first: on Android 11 setting them afterwards resets the bars' behaviour to "show on
        // first touch", and the first note then brings the bars back and resizes the whole surface
        window?.attributes = window?.attributes?.apply {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        val bars = window?.let { WindowCompat.getInsetsController(it, it.decorView) }
        bars?.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        bars?.hide(WindowInsetsCompat.Type.systemBars())
        onDispose {
            bars?.show(WindowInsetsCompat.Type.systemBars())
            activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
    }

    // the firmware's screen and LEDs, once per display frame
    val shm = remember(fbPath) { fbPath?.let { runCatching { FirmwareShm(it) }.getOrNull() } }
    DisposableEffect(shm) { onDispose { shm?.close() } }
    LaunchedEffect(shm) {
        if (shm == null) return@LaunchedEffect
        while (true) {
            withFrameNanos { }
            if (shm.poll()) state.screenFrame++
            val (b, k, g) = state.leds
            if (shm.ledButtons != b || shm.ledKeys != k || shm.glowKeys != g) {
                state.leds = Triple(shm.ledButtons, shm.ledKeys, shm.glowKeys)
                if (shm.ledButtons != b) state.buttonLedFrame++
                if (shm.ledKeys != k || shm.glowKeys != g) state.keyLedFrame++
            }
        }
    }
    val screenImage = remember(shm) { shm?.bitmap?.asImageBitmap() }

    val page = layout.pages[state.page.coerceIn(0, layout.pages.size - 1)]
    val wDp = sizePx.width / density
    val hDp = sizePx.height / density
    val fitted = remember(layout, page, wDp, hDp, editing) {
        if (wDp <= 0) null else if (editing) editFit(layout, page, wDp, hDp) else fit(layout, page, wDp, hDp)
    }
    val controls = remember(layout, page) { layout.dock + page.controls }
    // a button or knob bound to a firmware key lights with that key's LED: then the controls layer follows key LEDs too
    val restKeyLeds = remember(controls) {
        controls.any { c -> c.type !in PLAYING_TYPES && c.bindings.any { it.to is Target.Key } }
    }

    fun haptic(kind: Int) = view.performHapticFeedback(kind)
    fun emit(event: String, payload: Map<String, Any> = emptyMap()) = sendNow(event, payload)
    fun input(payload: Map<String, Any>) = emit("in", payload)

    fun rectOf(c: Control): Grid.Rect? = fitted?.let { f -> (edit.override(c.id) ?: f.placement.cells[c.id])?.let { f.grid.rect(it) } }

    fun goPage(ref: String) {
        val i = when (ref) {
            "next" -> (state.page + 1) % layout.pages.size
            "prev" -> (state.page - 1 + layout.pages.size) % layout.pages.size
            else -> layout.pages.indexOfFirst { it.id == ref }.takeIf { it >= 0 } ?: state.page
        }
        if (i != state.page) {
            state.page = i
            emit("page", mapOf("id" to layout.pages[i].id))
        }
    }

    val ectx = fitted?.let {
        EditCtx(layout, page, layout.pages.indexOf(page), it.grid, wDp, hDp, addMenu, scope, { e, p -> emit(e, p) },
            { i -> goPage(layout.pages[i].id) }, { k -> haptic(k) })
    }
    val ectxNow by rememberUpdatedState(ectx)
    val editingNow by rememberUpdatedState(editing)

    /** Press or release a discrete target (keys, buttons, notes, page). */
    fun fire(t: Target, down: Boolean) {
        when (t) {
            is Target.Key -> input(mapOf("t" to "key", "k" to t.n, "d" to down))
            is Target.Button -> input(mapOf("t" to "button", "id" to t.id, "d" to down))
            is Target.Midi -> when (t.type) {
                "note" -> input(mapOf("t" to "midi", "bytes" to listOf((if (down) 0x90 else 0x80) or (t.channel - 1), t.number, if (down) 100 else 0)))
                "cc" -> if (down) input(mapOf("t" to "midi", "bytes" to listOf(0xB0 or (t.channel - 1), t.number, 127)))
                else -> {}
            }
            is Target.Page -> if (down) goPage(t.ref)
            is Target.Encoder -> if (down) input(mapOf("t" to "encoder", "id" to t.id, "clicks" to if (t.invert) -1 else 1))
            Target.Pot -> {}
        }
    }

    fun tap(t: Target) {
        fire(t, true)
        fire(t, false)
    }

    /** Press bindings of a button-like thing (a button, a single key, a pad). */
    fun pressBindings(key: String, bindings: List<Binding>, down: Boolean) {
        for (b in bindings.filter { it.on == "press" }) {
            if (b.mode == "toggle") {
                if (down) {
                    val on = !(state.toggles[key] ?: false)
                    state.toggles[key] = on
                    fire(b.to, on)
                }
            } else fire(b.to, down)
        }
        val map = if ('#' in key) state.held else state.pressed
        if (down) map[key] = true else map.remove(key)
    }

    fun sendValue(c: Control, t: Target, v: Float) {
        sendValueBytes(t, v, c.id)?.let { input(it) }
    }

    /** A relative move of `d` dp on a value control (knob, slider, xy axis). */
    fun turn(c: Control, g: Grab, b: Binding, d: Float) {
        val f = if (g.fine) 0.25f else 1f
        when (val t = b.to) {
            is Target.Encoder -> {
                g.acc += d * f * (if (t.invert) -1 else 1)
                val n = (g.acc / t.ptPerClick).toInt()
                if (n != 0) {
                    g.acc -= n * t.ptPerClick
                    g.clicks += n
                    state.encoderTurns[c.id] = (state.encoderTurns[c.id] ?: 0) + n
                    input(mapOf("t" to "encoder", "id" to t.id, "clicks" to n, "c" to c.id))
                    haptic(HapticFeedbackConstants.CLOCK_TICK)
                    state.bubbles[c.id] = (if (g.clicks > 0) "+" else "") + g.clicks + (if (g.fine) " · fine" else "")
                }
            }
            else -> {
                val key = t.absoluteKey ?: return
                val old = state.values[key] ?: 0.5f
                val v = (old + d * f / POT_RANGE_DP).coerceIn(0f, 1f)
                if (v != old) {
                    if ((v == 0f || v == 1f) && v != old) haptic(HapticFeedbackConstants.CLOCK_TICK)
                    if (!rule7.accept(key, c.id, v, old)) return
                    state.values[key] = v
                    sendValue(c, t, v)
                    state.bubbles[c.id] = "${(v * 100).roundToInt()}" + (if (g.fine) " · fine" else "")
                }
            }
        }
    }

    fun setValue(c: Control, t: Target, v: Float) {
        val key = t.absoluteKey ?: return
        if (!rule7.accept(key, c.id, v, state.values[key])) return
        state.values[key] = v
        sendValue(c, t, v)
    }

    // keyboard geometry: the visible firmware keys of a strip
    fun window(c: Control): IntRange {
        val n = (c.toKey - c.fromKey).coerceAtLeast(0)
        val start = (c.fromKey + (state.kbOffset[c.id] ?: 0)).coerceIn(0, 26 - n)
        return start..(start + n)
    }

    // per strip: its key rects for the last window and rect (rebuilt only after an octave shift or a refit)
    val keyGeometry = remember(layout) { HashMap<String, KeyGeometry>() }

    fun keyboardKeys(c: Control, r0: Grid.Rect): List<Pair<Int, Grid.Rect>> {
        val keys = window(c)
        val r = keysRect(c, r0)
        keyGeometry[c.id]?.let { g -> if (g.window == keys && g.rect == r) return g.keys }
        val arrows = if (c.octaveArrows && !hasRail(c)) ARROW_DP else 0f
        val len = (if (c.vertical) r.h else r.w) - 2 * arrows
        val across = if (c.vertical) r.w else r.h
        val whites = keys.filter { !isBlack(it) }
        if (whites.isEmpty()) return emptyList()
        val ww = len / whites.size
        val out = mutableListOf<Pair<Int, Grid.Rect>>()
        // along: position from the low end; mapped to x (horizontal) or from the bottom (vertical)
        fun rectAlong(a: Float, l: Float, depth: Float): Grid.Rect =
            if (c.vertical) Grid.Rect(r.x + r.w - depth, r.y + r.h - arrows - a - l, depth, l)
            else Grid.Rect(r.x + arrows + a, r.y, l, depth)
        var i = 0
        for (k in keys) if (!isBlack(k)) out += k to rectAlong(i++ * ww, ww - 2f, across)
        i = 0
        for (k in keys) {
            if (!isBlack(k)) { i++; continue }
            val bw = ww * 0.62f
            out += k to rectAlong(i * ww - bw / 2, bw, across * 0.6f)
        }
        keyGeometry[c.id] = KeyGeometry(keys, r, out)
        return out
    }

    fun keyAt(c: Control, r: Grid.Rect, p: Offset): Int? {
        val keys = keyboardKeys(c, r)
        // black keys sit on top
        return keys.lastOrNull { (k, kr) -> isBlack(k) && kr.contains(p.x, p.y) }?.first
            ?: keys.firstOrNull { (k, kr) -> !isBlack(k) && kr.contains(p.x, p.y) }?.first
    }

    fun arrowAt(c: Control, r: Grid.Rect, p: Offset): Int {
        if (!c.octaveArrows || hasRail(c)) return 0
        val low = if (c.vertical) p.y > r.y + r.h - ARROW_DP else p.x < r.x + ARROW_DP
        val high = if (c.vertical) p.y < r.y + ARROW_DP else p.x > r.x + r.w - ARROW_DP
        return if (low) -1 else if (high) 1 else 0
    }

    fun shiftOctave(c: Control, dir: Int) {
        val n = c.toKey - c.fromKey
        val cur = state.kbOffset[c.id] ?: 0
        val next = cur + 12 * dir
        if (c.fromKey + next in 0..(26 - n)) {
            state.kbOffset[c.id] = next
            haptic(HapticFeedbackConstants.KEYBOARD_TAP)
        } else {
            // past either end: the firmware's own OCT− / OCT+ (HANDOFF §8)
            tap(Target.Button(if (dir < 0) "oct_down" else "oct_up"))
        }
    }

    fun padAt(c: Control, r: Grid.Rect, p: Offset): Int? {
        if (!r.contains(p.x, p.y)) return null
        val col = ((p.x - r.x) / r.w * c.padCols).toInt().coerceIn(0, c.padCols - 1)
        val row = ((p.y - r.y) / r.h * c.padRows).toInt().coerceIn(0, c.padRows - 1)
        return (row * c.padCols + col).takeIf { it < c.pads.size }
    }

    fun stringAt(c: Control, r: Grid.Rect, p: Offset): Int? {
        if (c.strings.isEmpty() || !r.contains(p.x, p.y)) return null
        val i = ((r.y + r.h - p.y) / r.h * c.strings.size).toInt().coerceIn(0, c.strings.size - 1)
        return i
    }

    fun bend(c: Control, g: Grab, r: Grid.Rect, p: Offset) {
        val keys = keyboardKeys(c, r)
        val ww = keys.firstOrNull { !isBlack(it.first) }?.second?.let { if (c.vertical) it.h else it.w } ?: return
        val along = if (c.vertical) g.start.y - p.y else p.x - g.start.x
        val v = (along / ww).coerceIn(-1f, 1f)
        val raw = (8192 + v * 8191).roundToInt().coerceIn(0, 16383)
        input(mapOf("t" to "midi", "bytes" to listOf(0xE0, raw and 0x7F, raw shr 7)))
    }

    // ── touch ─────────────────────────────────────────────────────────────
    val grabs = remember { mutableMapOf<Long, Grab>() }

    fun down(id: Long, p: Offset, now: Long) {
        if (!editing && fitted?.placement?.fits == false && p.y < 30f && abs(p.x - wDp / 2) < 160f) {
            emit("use_classic")
            return
        }
        val c = controls.lastOrNull { ctl -> rectOf(ctl)?.contains(p.x, p.y) == true }
        val g = Grab(id, c, p, now)
        grabs[id] = g
        state.fingers[id] = p
        if (c == null) {
            scope.launch {
                delay(EDIT_HOLD_MS)
                if (grabs[id] === g && !g.moved) { haptic(HapticFeedbackConstants.LONG_PRESS); emit("edit") }
            }
            return
        }
        val r = rectOf(c)!!
        when (c.type) {
            "menu" -> {
                state.pressed[c.id] = true
                scope.launch {
                    delay(EDIT_HOLD_MS)
                    if (grabs[id] === g && !g.moved) { g.longFired = true; haptic(HapticFeedbackConstants.LONG_PRESS); emit("pages") }
                }
            }
            "button", "key", "label" -> {
                if (c.type == "label" && c.bindings.isEmpty()) return
                pressBindings(c.id, c.bindings, true)
                c.binding("long_press")?.let { lb ->
                    scope.launch {
                        delay(LONG_PRESS_MS)
                        if (grabs[id] === g) { g.longFired = true; haptic(HapticFeedbackConstants.LONG_PRESS); tap(lb.to) }
                    }
                }
            }
            "pad_grid" -> padAt(c, r, p)?.let { i -> g.sub = i; pressBindings("${c.id}#$i", c.pads[i].bindings, true) }
            "keyboard" -> {
                if (railHit(c, r, p.x, p.y)) { g.sub = RAIL_GRAB; state.kbOffset[c.id] = railStart(r, p.y, c.toKey - c.fromKey) - c.fromKey; return }
                val arrow = arrowAt(c, r, p)
                if (arrow != 0) { shiftOctave(c, arrow); return }
                keyAt(c, r, p)?.let { k -> g.sub = k; state.held["${c.id}#$k"] = true; fire(Target.Key(k), true) }
            }
            "strum" -> stringAt(c, r, p)?.let { s -> g.sub = s; state.held["${c.id}#$s"] = true; fire(Target.Key(c.strings[s]), true) }
            "page_switcher" -> {
                val n = layout.pages.size
                val i = ((p.x - r.x) / r.w * n).toInt().coerceIn(0, n - 1)
                goPage(layout.pages[i].id)
            }
            "knob", "slider", "xy_pad" -> {
                state.pressed[c.id] = true
                state.encoderTurns[c.id] = 0
                g.startValues = c.bindings.mapNotNull { b -> b.to.absoluteKey?.let { it to (state.values[it] ?: 0.5f) } }.toMap()
                // jump-to-position: MIDI CC sliders only (rule 5)
                if (c.type == "slider") c.binding("value")?.let { b ->
                    if (b.to is Target.Midi && b.to.jump) {
                        val v = if (c.sliderVertical) 1 - (p.y - r.y) / r.h else (p.x - r.x) / r.w
                        setValue(c, b.to, v.coerceIn(0f, 1f))
                    }
                }
                scope.launch {
                    delay(FINE_HOLD_MS)
                    if (grabs[id] === g && !g.moved) {
                        g.fine = true
                        haptic(HapticFeedbackConstants.CLOCK_TICK)
                        state.bubbles[c.id] = "fine"
                    }
                }
            }
            else -> {}
        }
    }

    fun move(id: Long, p: Offset) {
        val g = grabs[id] ?: return
        val d = p - g.last
        if (!g.moved && (p - g.start).getDistance() > STILL_DP) g.moved = true
        g.last = p
        state.fingers[id] = p
        val c = g.control ?: return
        val r = rectOf(c) ?: return
        when (c.type) {
            "pad_grid" -> {
                val i = padAt(c, r, p)
                if (i != g.sub) {
                    if (g.sub >= 0) pressBindings("${c.id}#${g.sub}", c.pads[g.sub].bindings, false)
                    g.sub = i ?: -1
                    if (i != null) pressBindings("${c.id}#$i", c.pads[i].bindings, true)
                }
            }
            "keyboard" -> {
                if (g.sub == RAIL_GRAB) { state.kbOffset[c.id] = railStart(r, p.y, c.toKey - c.fromKey) - c.fromKey; return }
                if (g.sub < 0) return
                if (c.wobble && bendOk) { bend(c, g, r, p); return }
                val k = keyAt(c, r, p)
                if (k != null && k != g.sub) {
                    state.held.remove("${c.id}#${g.sub}")
                    fire(Target.Key(g.sub), false)
                    g.sub = k
                    state.held["${c.id}#$k"] = true
                    fire(Target.Key(k), true)
                }
            }
            "strum" -> {
                val s = stringAt(c, r, p)
                if (s != g.sub) {
                    if (g.sub >= 0) { state.held.remove("${c.id}#${g.sub}"); fire(Target.Key(c.strings[g.sub]), false) }
                    g.sub = s ?: -1
                    if (s != null) { state.held["${c.id}#$s"] = true; fire(Target.Key(c.strings[s]), true) }
                }
            }
            "knob" -> c.binding("value")?.let { turn(c, g, it, d.x - d.y) }
            "slider" -> c.binding("value")?.let { b ->
                if (!(b.to is Target.Midi && b.to.jump)) turn(c, g, b, if (c.sliderVertical) -d.y else d.x)
                else {
                    val v = if (c.sliderVertical) 1 - (p.y - r.y) / r.h else (p.x - r.x) / r.w
                    setValue(c, b.to, v.coerceIn(0f, 1f))
                }
            }
            "xy_pad" -> {
                c.binding("x")?.let { turn(c, g, it, d.x) }
                c.binding("y")?.let { turn(c, g, it, -d.y) }
            }
            else -> {}
        }
    }

    fun up(id: Long) {
        val g = grabs.remove(id) ?: return
        state.fingers.remove(id)
        val c = g.control ?: return
        when (c.type) {
            "menu" -> {
                state.pressed.remove(c.id)
                if (!g.longFired) emit("menu")
            }
            "button", "key", "label" -> pressBindings(c.id, c.bindings, false)
            "pad_grid" -> if (g.sub >= 0) pressBindings("${c.id}#${g.sub}", c.pads[g.sub].bindings, false)
            "keyboard" -> if (g.sub >= 0) {
                state.held.remove("${c.id}#${g.sub}")
                fire(Target.Key(g.sub), false)
                if (c.wobble && bendOk) input(mapOf("t" to "midi", "bytes" to listOf(0xE0, 0, 64)))
            }
            "strum" -> if (g.sub >= 0) { state.held.remove("${c.id}#${g.sub}"); fire(Target.Key(c.strings[g.sub]), false) }
            "knob", "slider", "xy_pad" -> {
                state.pressed.remove(c.id)
                state.bubbles.remove(c.id)
                state.encoderTurns.remove(c.id)
                if (c.type == "xy_pad" && c.springBack) {
                    for (b in c.bindings) when (val t = b.to) {
                        is Target.Encoder -> if (g.clicks != 0) input(mapOf("t" to "encoder", "id" to t.id, "clicks" to -g.clicks))
                        else -> t.absoluteKey?.let { k -> g.startValues[k]?.let { setValue(c, t, it) } }
                    }
                }
            }
            else -> {}
        }
    }

    // controls stop sending input in edit mode: lift whatever was held when it began
    LaunchedEffect(editing) { if (editing) grabs.keys.toList().forEach { up(it) } else edit.reset() }

    // ── drawing ───────────────────────────────────────────────────────────
    Box(modifier = Modifier.fillMaxSize()) {
    if (editing) Canvas(modifier = Modifier.fillMaxSize()) { ectx?.let { edit.drawUnder(this, it, density) } }
    // the controls on two layers, each re-recorded only when what it shows changes: the rest (buttons, knobs,
    // labels; an offscreen layer, so other frames composite it as one texture) and the playing ones (keys,
    // pads, strings: they change on every note and key LED, so a plain layer that is cheap to re-record)
    Canvas(
        modifier = Modifier
            .fillMaxSize()
            .onSizeChanged { sizePx = it }
            .pointerInput(layout, fitted, state.page, editing) {
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent(PointerEventPass.Main)
                        val now = System.currentTimeMillis()
                        for (ch in event.changes) {
                            val p = Offset(ch.position.x / density, ch.position.y / density)
                            when {
                                ch.changedToDownIgnoreConsumed() ->
                                    if (editingNow) ectxNow?.let { edit.down(it, ch.id.value, p) } else down(ch.id.value, p, now)
                                ch.changedToUpIgnoreConsumed() ->
                                    if (editingNow) ectxNow?.let { edit.up(it, ch.id.value, p) } else up(ch.id.value)
                                ch.positionChanged() ->
                                    if (editingNow) ectxNow?.let { edit.move(it, ch.id.value, p, now) } else move(ch.id.value, p)
                            }
                            ch.consume()
                        }
                    }
                }
            }
            .graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen),
    ) {
        if (state.buttonLedFrame < 0 || (restKeyLeds && state.keyLedFrame < 0)) return@Canvas
        if (!editing) drawRect(C.bg)
        if (fitted == null) return@Canvas
        val dr = Draw(this, density, ink)
        for (c in controls) {
            if (edit.hidden(c.id)) continue
            val r = rectOf(c) ?: continue
            when (c.type) {
                "button", "key" -> dr.button(c, r, state, ledFor(c, state.leds))
                "knob" -> dr.knob(c, r, state)
                "slider" -> dr.slider(c, r, state)
                "xy_pad" -> dr.xy(c, r, state)

                "screen" -> dr.screenBezel(r, c.screenScale, shm?.valid == true, phase)
                "label" -> dr.label(c, r)
                "page_switcher" -> dr.switcher(c, r, layout, state.page)
            }
            if (rule7.stale(c)) dimOver(this, r, density)
        }
    }
    Canvas(modifier = Modifier.fillMaxSize().graphicsLayer()) {
        if (state.keyLedFrame < 0 || fitted == null) return@Canvas
        val dr = Draw(this, density, ink)
        for (c in controls) {
            if (edit.hidden(c.id)) continue
            val r = rectOf(c) ?: continue
            when (c.type) {
                "pad_grid" -> dr.pads(c, r, state)
                "keyboard" -> {
                    dr.keyboard(if (hasRail(c)) c.copy(octaveArrows = false) else c, r, state, keyboardKeys(c, r), state.leds)
                    if (hasRail(c)) drawRail(this, r, window(c), density)
                }
                "strum" -> dr.strum(c, r, state)
            }
        }
    }
    // the firmware screen: a new engine frame (up to 60 a second) redraws only this layer
    Canvas(modifier = Modifier.fillMaxSize().graphicsLayer()) {
        if (state.screenFrame < 0 || shm == null || screenImage == null || !shm.valid) return@Canvas
        val dr = Draw(this, density, ink)
        for (c in controls) if (c.type == "screen" && !edit.hidden(c.id)) rectOf(c)?.let { dr.screenPixels(it, c.screenScale, screenImage) }
    }
    // ── menu: the Opling (Opling.kt), on its own layer ──
    controls.firstOrNull { it.type == "menu" && !edit.hidden(it.id) }?.let { m ->
        rectOf(m)?.let { r ->
            OplingMenuButton(
                r.x, r.y, r.w, r.h,
                pressed = { state.pressed[m.id] == true },
                notesHeld = { state.held.size },
                phase = phase, quarantined = quarantined, restarts = restarts,
            )
        }
    }
    // ── end menu ──
    // fingers, value bubbles and the banner: redrawn on every finger move without touching the controls
    Canvas(modifier = Modifier.fillMaxSize().graphicsLayer()) {
        val f = fitted ?: return@Canvas
        val dr = Draw(this, density, ink)
        for ((id, t) in state.bubbles) controls.firstOrNull { it.id == id }?.let { c -> rectOf(c)?.let { dr.bubbleFor(c, it, t) } }
        for ((_, p) in state.fingers) dr.finger(p)
        if (!f.placement.fits && !editing) dr.banner("Doesn't fit this phone · tap for Classic")
    }
    // edit mode (grid selection, drags, pill, "Add here") and toasts, over everything
    Canvas(modifier = Modifier.fillMaxSize()) {
        if (editing) ectx?.let { edit.drawOver(this, it, density) }
        drawToast(this, toast, wDp, hDp, density)
    }
    }
}

private fun ledFor(c: Control, leds: Triple<Int, Int, Int>): Boolean {
    for (b in c.bindings) when (val t = b.to) {
        is Target.Button -> { val i = BUTTON_IDS.indexOf(t.id); if (i >= 0 && (leds.first shr i) and 1 == 1) return true }
        is Target.Key -> if ((leds.second shr t.n) and 1 == 1) return true
        else -> {}
    }
    return false
}

private fun sendValueBytes(t: Target, v: Float, control: String): Map<String, Any>? = when (t) {
    Target.Pot -> mapOf("t" to "pot", "v" to v.toDouble(), "c" to control)
    is Target.Midi -> if (t.type == "cc") mapOf(
        "t" to "midi", "bytes" to listOf(0xB0 or (t.channel - 1), t.number, (v * 127).roundToInt()),
        "c" to control, "abs" to (t.absoluteKey ?: ""), "v" to v.toDouble(),
    ) else null
    else -> null
}

/**
 * Text on the instrument in fixed dp (HANDOFF §11: fixed geometry, no dynamic type), with android Paints made
 * once per style, so recording a frame never lays text out.
 */
private class Ink(private val d: Float) {
    class Style(val paint: Paint, val dy: Float)

    private val styles = HashMap<Int, Style>()

    fun style(size: Float, mono: Boolean, weight: Int): Style =
        styles.getOrPut((size * 10).roundToInt() * 10_000 + weight * 2 + (if (mono) 1 else 0)) {
            val p = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                textSize = size * d
                textAlign = Paint.Align.CENTER
                typeface = Typeface.create(if (mono) Typeface.MONOSPACE else Typeface.SANS_SERIF, weight, false)
            }
            val fm = p.fontMetrics
            Style(p, -(fm.ascent + fm.descent) / 2)
        }
}

/** Draws in dp: every coordinate is multiplied by the density here. */
private class Draw(val s: DrawScope, val d: Float, val ink: Ink) {
    fun Float.px() = this * d
    private fun off(x: Float, y: Float) = Offset(x.px(), y.px())
    private fun sz(w: Float, h: Float) = Size(w.px(), h.px())
    private fun rr(x: Float, y: Float, w: Float, h: Float, r: Float, color: Color) =
        s.drawRoundRect(color, off(x, y), sz(w, h), CornerRadius(r.px()))

    fun text(t: String, cx: Float, cy: Float, size: Float, color: Color, mono: Boolean = false, weight: Int = 600) {
        if (t.isEmpty()) return
        val st = ink.style(size, mono, weight)
        st.paint.color = color.toArgb()
        s.drawContext.canvas.nativeCanvas.drawText(t, cx.px(), cy.px() + st.dy, st.paint)
    }

    fun button(c: Control, r: Grid.Rect, st: SurfaceState, lit: Boolean) {
        val pressed = st.pressed[c.id] == true
        val on = st.toggles[c.id] == true
        val y = if (pressed) r.y + 2 else r.y
        val bg = when { pressed -> C.fm; on -> C.selected; c.color != "default" -> C.pad(c.color); else -> C.raised }
        rr(r.x, y, r.w, r.h, 10f, bg)
        text(c.label, r.cx, y + r.h / 2, 11f, if (pressed || c.color != "default") C.ink else C.buttonFg)
        s.drawCircle(if (lit) C.led else if (pressed) C.fmDim else C.ledOff, 3f.px(), off(r.x + r.w - 10, y + 10))
    }

    fun knob(c: Control, r: Grid.Rect, st: SurfaceState) {
        val b = c.binding("value")
        val active = st.pressed[c.id] == true
        val labelH = 14f
        val size = min(56f, min(r.w, r.h - labelH))
        val k = size / 56f
        val cx = r.cx
        val cy = r.y + (r.h - labelH) / 2
        fun pt(deg: Float, rad: Float) = Offset((cx + rad * k * cos(deg * PI / 180).toFloat()).px(), (cy + rad * k * sin(deg * PI / 180).toFloat()).px())
        if (b?.to is Target.Encoder) {
            val turns = st.encoderTurns[c.id] ?: 0
            for (i in 0 until 16) {
                val lit = active && turns != 0 && i < min(16, abs(turns))
                s.drawCircle(if (lit) C.fm else C.ledOff, 1.7f * k * d, pt(-90f + i * 22.5f, 24.5f))
            }
            s.drawCircle(if (active) C.sliderFill else C.raisedHi, 16f * k * d, Offset(cx.px(), cy.px()))
            s.drawCircle(C.text, 2.6f * k * d, pt(-90f + turns * 22.5f, 10f))
        } else {
            val v = b?.to?.absoluteKey?.let { st.values[it] } ?: 0.5f
            val stroke = Stroke(4f * k * d, cap = StrokeCap.Round)
            val tl = Offset((cx - 22 * k).px(), (cy - 22 * k).px())
            val arc = Size((44 * k).px(), (44 * k).px())
            s.drawArc(C.lineSoft, 135f, 270f, false, tl, arc, style = stroke)
            if (v > 0.002f) s.drawArc(C.fm, 135f, 270f * v, false, tl, arc, style = stroke)
            s.drawCircle(C.raisedHi, 15f * k * d, Offset(cx.px(), cy.px()))
            s.drawCircle(C.text, 2.6f * k * d, pt(135f + 270f * v, 10f))
        }
        text(c.label, cx, r.y + r.h - labelH / 2, 10f, if (active) C.fm else C.muted, mono = true)
    }

    /** A control's value bubble (overlay layer): above a knob's dial, above sliders and XY pads. */
    fun bubbleFor(c: Control, r: Grid.Rect, t: String) {
        if (c.type == "knob") {
            val k = min(56f, min(r.w, r.h - 14f)) / 56f
            bubble(t, r.cx, r.y + (r.h - 14f) / 2 - 34 * k)
        } else bubble(t, r.cx, r.y - 4)
    }

    private fun bubble(t: String, cx: Float, cy: Float) {
        val w = ink.style(10f, true, 700).paint.measureText(t) / d + 12
        rr(cx - w / 2, cy - 9, w, 18f, 6f, C.fm)
        text(t, cx, cy, 10f, C.ink, mono = true, weight = 700)
    }

    fun slider(c: Control, r: Grid.Rect, st: SurfaceState) {
        val b = c.binding("value")
        val active = st.pressed[c.id] == true
        rr(r.x, r.y, r.w, r.h, 14f, C.raised)
        val v = b?.to?.absoluteKey?.let { st.values[it] }
        if (v != null) {
            if (c.sliderVertical) rr(r.x, r.y + r.h * (1 - v), r.w, r.h * v, 14f, if (active) C.fmTint else C.sliderFill)
            else rr(r.x, r.y, r.w * v, r.h, 14f, if (active) C.fmTint else C.sliderFill)
        } else if (active) rr(r.x, r.y, r.w, r.h, 14f, C.fmTint)
        text(c.label, r.cx, if (c.sliderVertical) r.y + r.h - 12 else r.cy, 10f, if (active) C.fm else C.muted, mono = true)
    }

    fun xy(c: Control, r: Grid.Rect, st: SurfaceState) {
        val active = st.pressed[c.id] == true
        rr(r.x, r.y, r.w, r.h, 12f, if (active) C.fmTint else C.raised)
        s.drawLine(C.lineSoft, off(r.cx, r.y + 8), off(r.cx, r.y + r.h - 8), 1f.px())
        s.drawLine(C.lineSoft, off(r.x + 8, r.cy), off(r.x + r.w - 8, r.cy), 1f.px())
        text(c.label, r.cx, r.y + 12, 10f, C.muted, mono = true)
    }

    fun pads(c: Control, r: Grid.Rect, st: SurfaceState) {
        val gap = 6f
        val pw = (r.w - (c.padCols - 1) * gap) / c.padCols
        val ph = (r.h - (c.padRows - 1) * gap) / c.padRows
        for ((i, pad) in c.pads.withIndex()) {
            val col = i % c.padCols
            val row = i / c.padCols
            if (row >= c.padRows) break
            val pressed = st.held["${c.id}#$i"] == true
            val x = r.x + col * (pw + gap)
            val y = r.y + row * (ph + gap) + if (pressed) 2 else 0
            val base = if (pad.color == "default") C.raised else C.pad(pad.color)
            rr(x, y, pw, ph, 12f, if (pressed) C.fm else base)
            text(pad.label, x + pw / 2, y + ph / 2, 11f, if (pressed || pad.color != "default") C.ink else C.buttonFg)
        }
    }

    fun keyboard(c: Control, r: Grid.Rect, st: SurfaceState, keys: List<Pair<Int, Grid.Rect>>, leds: Triple<Int, Int, Int>) {
        for ((k, kr) in keys) {
            val pressed = st.held["${c.id}#$k"] == true
            val lit = (leds.second shr k) and 1 == 1
            val glow = (leds.third shr k) and 1 == 1
            val dy = if (pressed) 2f else 0f
            if (!isBlack(k)) {
                val color = if (pressed) C.fm else if (c.pitchColors) pitch(53 + k, 0.62f) else C.keyWhite
                rr(kr.x, kr.y + dy, kr.w, kr.h, 6f, color)
                val ledC = if (lit) C.led else if (pressed) C.fmDim else if (glow) C.led.copy(alpha = 0.45f) else C.ledOffOnWhite
                if (lit) s.drawCircle(C.led.copy(alpha = 0.3f), 8f.px(), off(kr.cx, kr.y + dy + 12))
                s.drawCircle(ledC, 3f.px(), off(kr.cx, kr.y + dy + 12))
                if (kr.w > 22) text(noteName(k), kr.cx, kr.y + kr.h - 12 + dy, 10f, C.faint, mono = true)
            } else {
                rr(kr.x - 1, kr.y - 1, kr.w + 2, kr.h + 2, 7f, C.bg)
                val color = if (pressed) C.fm else if (c.pitchColors) pitch(53 + k, 0.47f) else C.keyBlack
                rr(kr.x, kr.y + dy, kr.w, kr.h, 6f, color)
                val ledC = if (lit) C.led else if (pressed) C.fmDim else if (glow) C.led.copy(alpha = 0.45f) else C.ledOff
                s.drawCircle(ledC, 3f.px(), off(kr.cx, kr.y + dy + 10))
            }
        }
        if (c.octaveArrows) {
            val a = ARROW_DP
            if (c.vertical) {
                rr(r.x, r.y + r.h - a + 4, r.w, a - 4, 10f, C.raised); text("▼", r.cx, r.y + r.h - a / 2, 12f, C.text2)
                rr(r.x, r.y, r.w, a - 4, 10f, C.raised); text("▲", r.cx, r.y + a / 2 - 2, 12f, C.text2)
            } else {
                rr(r.x, r.y, a - 4, r.h, 10f, C.raised); text("◀", r.x + a / 2 - 2, r.cy, 12f, C.text2)
                rr(r.x + r.w - a + 4, r.y, a - 4, r.h, 10f, C.raised); text("▶", r.x + r.w - a / 2 + 2, r.cy, 12f, C.text2)
            }
        }
    }

    fun strum(c: Control, r: Grid.Rect, st: SurfaceState) {
        rr(r.x, r.y, r.w, r.h, 12f, C.raised)
        val n = c.strings.size
        for (i in 0 until n) {
            val y = r.y + r.h - (i + 0.5f) * r.h / n
            val pressed = st.held["${c.id}#$i"] == true
            s.drawLine(if (pressed) C.fm else C.text2, off(r.x + 8, y), off(r.x + r.w - 8, y), (if (pressed) 3f else 1.5f).px())
        }
    }

    /** Where the firmware screen goes in a control: integer device-pixel scale only (HANDOFF §7). */
    data class ScreenBox(val x: Float, val y: Float, val side: Float, val sidePx: Int)

    fun screenBox(r: Grid.Rect, scale: Int): ScreenBox {
        val bezel = 6f
        val availPx = min(r.w - 2 * bezel, r.h - 2 * bezel).px()
        var k = floor(availPx / 240f).toInt().coerceAtLeast(1)
        if (scale in 1..4) k = min(k, max(1, scale))
        val sidePx = 240 * k
        val side = sidePx / d
        return ScreenBox(r.cx - side / 2, r.cy - side / 2, side, sidePx)
    }

    fun screenBezel(r: Grid.Rect, scale: Int, live: Boolean, phase: String) {
        val b = screenBox(r, scale)
        rr(b.x - 6, b.y - 6, b.side + 12, b.side + 12, 12f, C.bezel)
        s.drawRect(Color.Black, off(b.x, b.y), sz(b.side, b.side))
        if (!live) text(if (phase == "safe_mode") "safe mode" else "booting…", b.x + b.side / 2, b.y + b.side / 2, 12f, C.muted, mono = true)
    }

    fun screenPixels(r: Grid.Rect, scale: Int, image: ImageBitmap) {
        val b = screenBox(r, scale)
        s.drawImage(
            image,
            srcOffset = IntOffset.Zero, srcSize = IntSize(240, 240),
            dstOffset = IntOffset(b.x.px().roundToInt(), b.y.px().roundToInt()), dstSize = IntSize(b.sidePx, b.sidePx),
            filterQuality = FilterQuality.None,
        )
    }

    fun label(c: Control, r: Grid.Rect) = text(c.label, r.cx, r.cy, 11f, C.muted, mono = true)

    fun switcher(c: Control, r: Grid.Rect, layout: Layout, page: Int) {
        val n = layout.pages.size
        val w = r.w / n
        for ((i, p) in layout.pages.withIndex()) {
            val x = r.x + i * w
            if (c.switcherDots) s.drawCircle(if (i == page) C.fm else C.ledOff, 4f.px(), off(x + w / 2, r.cy))
            else {
                rr(x + 2, r.cy - 14, w - 4, 28f, 14f, if (i == page) C.selected else C.raised)
                text(p.name, x + w / 2, r.cy, 11f, if (i == page) C.fm else C.text2)
            }
        }
    }

    fun finger(p: Offset) = s.drawCircle(C.fm.copy(alpha = 0.35f), 18f.px(), off(p.x, p.y), style = Stroke(2f.px()))

    fun banner(t: String) {
        val w = ink.style(12f, false, 600).paint.measureText(t) / d + 24
        val cx = s.size.width / d / 2
        rr(cx - w / 2, 4f, w, 24f, 12f, C.warn)
        text(t, cx, 16f, 12f, C.ink)
    }

    /** FMutate.Style.pitch_color/1: hue 0..300 across the 88 keys. */
    fun pitch(midi: Int, lightness: Float): Color {
        val h = ((midi - 21).coerceIn(0, 87) / 87f) * 300f
        return Color.hsl(h, 0.72f, lightness)
    }
}

private fun Context.findActivity(): Activity? {
    var c: Context? = this
    while (c is ContextWrapper) {
        if (c is Activity) return c
        c = c.baseContext
    }
    return null
}
