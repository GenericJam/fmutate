package com.example.fmutate_app.fmutate

import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.channels.Channel

/**
 * What learned MIDI controls show on the instrument surface (MIDI learn). FMutate.MIDI applies a learned
 * hardware control's bindings in Elixir (the firmware gets its inputs from there) and hands the surface only
 * what it must show, as text lines (FMutate.MIDI.Controls.surface_text): fm1io's `surface/1` NIF calls
 * [FMutateIO.surface] on a BEAM dirty-IO thread, which queues them here; the surface drains the queue once per
 * display frame ([InstrumentView]), so a fast knob sweep is one recomposition a frame and the screen's Elixir
 * process never hears of it.
 *
 *     p <key> <0|1>                  a learned press went down / up (key: control id, or "<id>#<pad>")
 *     t <key> <0|1>                  its toggle is now off / on
 *     v <control> <target> <value>   absolute target (Target.absoluteKey) moved to value (0..1) by control
 *     e <control> <clicks>           encoder clicks sent for a knob / slider / XY pad
 *     h <key> <0|1>                  an automapped pad holds the FM-1 button this control is bound to: lit only
 *     o <-1|1>                       an automapped pad pressed OCT− / OCT+ (velocity strips' own octave follows)
 */
sealed class MidiShow {
    data class Press(val key: String, val down: Boolean) : MidiShow()
    data class Toggle(val key: String, val on: Boolean) : MidiShow()
    data class Value(val control: String, val target: String, val v: Float) : MidiShow()
    data class Clicks(val control: String, val n: Int) : MidiShow()
    data class Shine(val key: String, val down: Boolean) : MidiShow()
    data class Octave(val dir: Int) : MidiShow()

    companion object {
        /** The lines of one batch; malformed lines are skipped. */
        fun parse(text: String): List<MidiShow> = text.split('\n').mapNotNull { line ->
            val f = line.split('\t')
            when (f[0]) {
                "p" -> if (f.size == 3) Press(f[1], f[2] == "1") else null
                "t" -> if (f.size == 3) Toggle(f[1], f[2] == "1") else null
                "v" -> if (f.size == 4) f[3].toFloatOrNull()?.let { Value(f[1], f[2], it.coerceIn(0f, 1f)) } else null
                "e" -> if (f.size == 3) f[2].toIntOrNull()?.let { Clicks(f[1], it) } else null
                "h" -> if (f.size == 3) Shine(f[1], f[2] == "1") else null
                "o" -> if (f.size == 2) f[1].toIntOrNull()?.let { Octave(it.coerceIn(-1, 1)) } else null
                else -> null
            }
        }
    }
}

object MidiSurface {
    // batches nobody drained (no surface shown) are dropped past this many, oldest first
    private const val KEEP = 256

    private val queue = ConcurrentLinkedQueue<String>()
    private val size = AtomicInteger(0)
    private val wake = Channel<Unit>(Channel.CONFLATED)

    /** From [FMutateIO.surface] (any thread). */
    fun offer(text: String) {
        queue.add(text)
        if (size.incrementAndGet() > KEEP && queue.poll() != null) size.decrementAndGet()
        wake.trySend(Unit)
    }

    /** Suspends until something was offered. */
    suspend fun await() = wake.receive()

    /** Everything queued, in order. */
    fun drain(): List<MidiShow> {
        val out = ArrayList<MidiShow>()
        while (true) {
            val text = queue.poll() ?: break
            size.decrementAndGet()
            out.addAll(MidiShow.parse(text))
        }
        return out
    }

    /** A new surface starts from what it is told from now on. */
    fun clear() {
        while (queue.poll() != null) size.decrementAndGet()
    }
}
