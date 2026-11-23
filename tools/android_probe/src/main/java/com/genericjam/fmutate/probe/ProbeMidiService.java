package com.genericjam.fmutate.probe;

import android.media.midi.MidiDeviceService;
import android.media.midi.MidiReceiver;
import android.util.Log;

/**
 * "FMutate Probe": a virtual MIDI device with an output port (ProbeActivity "emit" plays through it) and an input
 * port that logs every message it is sent (logcat tag FMutateProbe, "in: b0 4a 40"): a MIDI out device for
 * FMutate's I/O screen.
 */
public class ProbeMidiService extends MidiDeviceService {
    static volatile ProbeMidiService current;

    @Override
    public void onCreate() {
        super.onCreate();
        current = this;
    }

    @Override
    public void onDestroy() {
        if (current == this) current = null;
        super.onDestroy();
    }

    @Override
    public MidiReceiver[] onGetInputPortReceivers() {
        return new MidiReceiver[]{new MidiReceiver() {
            @Override
            public void onSend(byte[] msg, int off, int n, long ts) {
                Log.i("FMutateProbe", "in: " + ProbeActivity.hex(msg, off, n));
            }
        }};
    }

    MidiReceiver out() {
        MidiReceiver[] outs = getOutputPortReceivers();
        return outs.length > 0 ? outs[0] : null;
    }
}
