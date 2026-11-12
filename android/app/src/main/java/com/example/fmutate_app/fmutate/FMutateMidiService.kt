package com.example.fmutate_app.fmutate

import android.media.midi.MidiDeviceService
import android.media.midi.MidiDeviceStatus
import android.media.midi.MidiReceiver

/**
 * Instance A's virtual MIDI port, `FMutate A` (HANDOFF §10): one input port (other apps play the instance
 * through it) and one output port (the clock FMutate sends, later the firmware's MIDI out). Declared in the
 * manifest with res/xml/fmutate_midi_a.xml; Android starts it when an app opens the port, so it lives in the
 * app process next to the BEAM. A second instance gets its own subclass, manifest entry and xml.
 *
 * Bytes arriving on the input go straight to [FMutateIO.fromVirtual] on the binder thread that delivered
 * them (no hop to the main thread).
 */
open class FMutateMidiService : MidiDeviceService() {
    /** The instance this port belongs to (0 = "a"). */
    open val instance: Int = 0

    private val input = object : MidiReceiver() {
        override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
            FMutateIO.fromVirtual(instance, msg, offset, count, timestamp)
        }
    }

    override fun onCreate() {
        super.onCreate()
        FMutateIO.attachService(instance, this)
    }

    override fun onDestroy() {
        FMutateIO.detachService(instance, this)
        super.onDestroy()
    }

    override fun onGetInputPortReceivers(): Array<MidiReceiver> = arrayOf(input)

    override fun onDeviceStatusChanged(status: MidiDeviceStatus) {
        FMutateIO.virtualStatus(instance, status.isInputPortOpen(0), status.getOutputPortOpenCount(0))
    }

    /** Send out of the output port to every app listening; false when nobody is. */
    fun send(data: ByteArray, timestamp: Long): Boolean {
        val out = outputPortReceivers.firstOrNull() ?: return false
        out.send(data, 0, data.size, timestamp)
        return true
    }
}
