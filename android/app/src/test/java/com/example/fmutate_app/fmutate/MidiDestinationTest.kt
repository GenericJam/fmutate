package com.example.fmutate_app.fmutate

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

// A MIDI binding's destination ("to": synth, out, both; FMutate.MIDI.Out): what the surface sends, and rule 7's keys,
// which FMutate.MIDI.Controls.target_key/1 must match.
class MidiDestinationTest {
    private val json = """{"format":"fmutate.layout/1","id":"m","name":"m","firmware":{"id":"obervave"},"frame":"landscape",
        "grid":{"cols":14,"rows":6},"pages":[{"id":"p","controls":[
        {"id":"xy","type":"xy_pad","at":{"col":0,"row":0,"w":3,"h":3},"bindings":[
          {"on":"x","to":{"midi":{"type":"cc","number":74,"to":"out"}}},
          {"on":"y","to":{"midi":{"type":"cc","number":71,"to":"both"}}}]},
        {"id":"k","type":"knob","at":{"col":4,"row":0,"w":1,"h":1},"bindings":[{"on":"value","to":{"midi":{"type":"cc","number":74}}}]},
        {"id":"t","type":"motion","at":{"col":5,"row":0,"w":1,"h":1},"bindings":[{"on":"y","to":{"midi":{"type":"pitch_bend","channel":2,"to":"out"}}}]}
        ]}]}"""

    private val controls = Layout.fromJson(JSONObject(json)).pages[0].controls

    private fun target(id: String, on: String) = controls.first { it.id == id }.binding(on)!!.to as Target.Midi

    @Test
    fun anOutOnlyMessageHasItsOwnRule7ValueAndBothSharesTheSynths() {
        assertEquals("out:cc:1:74", target("xy", "x").absoluteKey)
        assertEquals("cc:1:74", target("k", "value").absoluteKey)
        assertEquals("cc:1:71", target("xy", "y").absoluteKey)
        assertEquals("out:bend:2", target("t", "y").absoluteKey)
    }

    @Test
    fun thePayloadSaysWhereItGoesUnlessThatIsTheSynth() {
        val bytes = listOf(0xB0, 74, 64)
        assertEquals(mapOf("t" to "midi", "bytes" to bytes, "to" to "out"), target("xy", "x").payload(bytes))
        assertEquals(mapOf("t" to "midi", "bytes" to bytes), target("k", "value").payload(bytes))
        assertEquals("both", target("xy", "y").payload(bytes, "c" to "xy")["to"])
    }

    @Test
    fun aNewEngineGetsOnlyWhatGoesToTheSynth() {
        assertNull(target("xy", "x").synthSide())
        assertEquals("synth", target("xy", "y").synthSide()!!.to)
        assertEquals(target("k", "value"), target("k", "value").synthSide())
    }
}
