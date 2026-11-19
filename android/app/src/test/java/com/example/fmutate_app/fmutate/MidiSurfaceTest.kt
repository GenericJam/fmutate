package com.example.fmutate_app.fmutate

import org.junit.Assert.assertEquals
import org.junit.Test

class MidiSurfaceTest {
    @Test
    fun parsesWhatFMutateMidiSends() {
        val text = "p\tarp\t1\nt\tpads#3\t0\nv\tmaster\tpot:master\t0.5039\ne\tknob1\t-3"
        assertEquals(
            listOf(
                MidiShow.Press("arp", true),
                MidiShow.Toggle("pads#3", false),
                MidiShow.Value("master", "pot:master", 0.5039f),
                MidiShow.Clicks("knob1", -3),
            ),
            MidiShow.parse(text),
        )
    }

    @Test
    fun skipsWhatItDoesNotKnowAndClampsValues() {
        assertEquals(listOf(MidiShow.Value("s", "cc:1:74", 1f)), MidiShow.parse("x\ty\nv\ts\tcc:1:74\t1.5\ne\tk\tmany\n"))
    }

    @Test
    fun queuedBatchesDrainInOrder() {
        MidiSurface.clear()
        MidiSurface.offer("p\ta\t1")
        MidiSurface.offer("p\ta\t0")
        assertEquals(listOf(MidiShow.Press("a", true), MidiShow.Press("a", false)), MidiSurface.drain())
        assertEquals(emptyList<MidiShow>(), MidiSurface.drain())
    }
}
