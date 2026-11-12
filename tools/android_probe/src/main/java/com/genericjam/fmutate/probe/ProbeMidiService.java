package com.genericjam.fmutate.probe;

import android.media.midi.MidiDeviceService;
import android.media.midi.MidiReceiver;

/** "FMutate Probe": a virtual MIDI device with one output port; ProbeActivity "emit" plays through it. */
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
        return new MidiReceiver[0];
    }

    MidiReceiver out() {
        MidiReceiver[] outs = getOutputPortReceivers();
        return outs.length > 0 ? outs[0] : null;
    }
}
