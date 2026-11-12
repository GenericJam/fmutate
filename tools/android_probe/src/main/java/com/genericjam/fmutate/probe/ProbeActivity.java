package com.genericjam.fmutate.probe;

import android.app.Activity;
import android.database.Cursor;
import android.media.midi.MidiDevice;
import android.media.midi.MidiDeviceInfo;
import android.media.midi.MidiInputPort;
import android.media.midi.MidiManager;
import android.media.midi.MidiOutputPort;
import android.media.midi.MidiReceiver;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Drives FMutate from a second app (logcat tag FMutateProbe):
 *
 *   am start -n com.genericjam.fmutate.probe/.ProbeActivity --es do cookie
 *       the sibling node, port and cookie from FMutate's signature-protected provider
 *   am start -n ... --es do notes [--ei note 60] [--ei count 1] [--ei hold 1500] [--ei gap 300] [--ei channel 1]
 *       note on/off into the "FMutate A" virtual port, each stamped System.nanoTime()
 *   am start -n ... --es do listen [--ei ms 3000]
 *       what comes out of "FMutate A" (the clock FMutate sends), with tick intervals
 *   am start -n ... --es do emit [--ei note 60] [--ei hold 1500]
 *       a note out of this app's own "FMutate Probe" port (once FMutate has opened it)
 */
public class ProbeActivity extends Activity {
    private static final String TAG = "FMutateProbe";
    private static final String PORT = "FMutate A";

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        final Bundle x = getIntent().getExtras() != null ? getIntent().getExtras() : new Bundle();
        final String what = x.getString("do", "cookie");
        new Thread(() -> {
            try {
                switch (what) {
                    case "cookie": cookie(); break;
                    case "notes": notes(x); break;
                    case "listen": listen(x); break;
                    case "emit": emit(x); break;
                    default: Log.w(TAG, "unknown command " + what);
                }
            } catch (Throwable t) {
                Log.e(TAG, what + " failed", t);
            }
            runOnUiThread(this::finish);
        }, "probe").start();
    }

    private void cookie() {
        Uri uri = Uri.parse("content://com.genericjam.fmutate.siblings/node");
        try (Cursor c = getContentResolver().query(uri, null, null, null, null)) {
            if (c == null || !c.moveToFirst()) {
                Log.w(TAG, "cookie: no answer (is FMutate installed and started once?)");
                return;
            }
            Log.i(TAG, "sibling node=" + c.getString(0) + " port=" + c.getString(1) + " cookie=" + c.getString(2)
                    + " protocol=" + c.getString(3));
        } catch (SecurityException e) {
            Log.w(TAG, "cookie: refused: " + e.getMessage());
        }
    }

    private MidiDevice openPort(MidiManager m, Handler h) throws InterruptedException {
        MidiDeviceInfo found = null;
        for (MidiDeviceInfo info : m.getDevicesForTransport(MidiManager.TRANSPORT_MIDI_BYTE_STREAM)) {
            String name = info.getProperties().getString(MidiDeviceInfo.PROPERTY_NAME);
            if (PORT.equals(name)) found = info;
        }
        if (found == null) {
            Log.w(TAG, "no MIDI device named " + PORT);
            return null;
        }
        CountDownLatch done = new CountDownLatch(1);
        AtomicReference<MidiDevice> dev = new AtomicReference<>();
        m.openDevice(found, d -> { dev.set(d); done.countDown(); }, h);
        done.await(5, TimeUnit.SECONDS);
        return dev.get();
    }

    private Handler handler() {
        HandlerThread t = new HandlerThread("probe-midi");
        t.start();
        return new Handler(t.getLooper());
    }

    private void notes(Bundle x) throws Exception {
        MidiManager m = getSystemService(MidiManager.class);
        MidiDevice dev = openPort(m, handler());
        if (dev == null) return;
        MidiInputPort in = dev.openInputPort(0);
        int note = x.getInt("note", 60), count = x.getInt("count", 1), hold = x.getInt("hold", 1500);
        int gap = x.getInt("gap", 300), ch = x.getInt("channel", 1) - 1;
        Thread.sleep(200);
        for (int i = 0; i < count; i++) {
            long t = System.nanoTime();
            in.send(new byte[]{(byte) (0x90 | ch), (byte) note, 100}, 0, 3, t);
            Log.i(TAG, "note on " + note + " ch " + (ch + 1) + " at " + t);
            Thread.sleep(hold);
            in.send(new byte[]{(byte) (0x80 | ch), (byte) note, 0}, 0, 3, System.nanoTime());
            Thread.sleep(gap);
        }
        Log.i(TAG, "notes: sent " + count);
        in.close();
        dev.close();
    }

    private void listen(Bundle x) throws Exception {
        MidiManager m = getSystemService(MidiManager.class);
        MidiDevice dev = openPort(m, handler());
        if (dev == null) return;
        MidiOutputPort out = dev.openOutputPort(0);
        final List<long[]> ticks = new ArrayList<>();
        final int[] other = {0};
        out.connect(new MidiReceiver() {
            @Override
            public void onSend(byte[] msg, int off, int n, long ts) {
                synchronized (ticks) {
                    for (int i = off; i < off + n; i++) {
                        if ((msg[i] & 0xFF) == 0xF8) ticks.add(new long[]{ts, System.nanoTime()});
                        else other[0]++;
                    }
                }
            }
        });
        Thread.sleep(x.getInt("ms", 3000));
        out.close();
        dev.close();
        synchronized (ticks) {
            Log.i(TAG, "listen: " + ticks.size() + " clock ticks, " + other[0] + " other bytes");
            if (ticks.size() > 2) {
                double sum = 0, min = Double.MAX_VALUE, max = 0, late = 0;
                for (int i = 1; i < ticks.size(); i++) {
                    double d = (ticks.get(i)[0] - ticks.get(i - 1)[0]) / 1e6;
                    sum += d;
                    min = Math.min(min, d);
                    max = Math.max(max, d);
                    late = Math.max(late, (ticks.get(i)[1] - ticks.get(i)[0]) / 1e6);
                }
                double mean = sum / (ticks.size() - 1);
                Log.i(TAG, String.format("listen: tick interval by timestamp mean %.3f ms (min %.3f, max %.3f) = %.1f BPM;"
                        + " arrival vs timestamp at most %.2f ms", mean, min, max, 60000 / (mean * 24), late));
            }
        }
    }

    private void emit(Bundle x) throws Exception {
        ProbeMidiService s = ProbeMidiService.current;
        MidiReceiver out = s != null ? s.out() : null;
        if (out == null) {
            Log.w(TAG, "emit: FMutate Probe isn't open (open it in FMutate's I/O screen first)");
            return;
        }
        int note = x.getInt("note", 60), hold = x.getInt("hold", 1500);
        out.send(new byte[]{(byte) 0x90, (byte) note, 100}, 0, 3, System.nanoTime());
        Log.i(TAG, "emit: note on " + note);
        Thread.sleep(hold);
        out.send(new byte[]{(byte) 0x80, (byte) note, 0}, 0, 3, System.nanoTime());
        Log.i(TAG, "emit: note off " + note);
    }
}
