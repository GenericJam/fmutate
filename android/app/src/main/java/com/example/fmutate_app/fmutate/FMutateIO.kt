package com.example.fmutate_app.fmutate

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.midi.MidiDevice
import android.media.midi.MidiDeviceInfo
import android.media.midi.MidiManager
import android.media.midi.MidiOutputPort
import android.media.midi.MidiReceiver
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import java.lang.ref.WeakReference
import java.util.concurrent.ConcurrentHashMap

/**
 * FMutate's I/O on the Android side (HANDOFF §10), bridged to the BEAM by the `fm1io` NIF (c_src/fm1io.c,
 * Elixir FMutate.IONif / FMutate.IO / FMutate.MIDI):
 *
 *  - MIDI in: the instances' virtual ports ([FMutateMidiService]) and the devices the player opens (USB,
 *    Bluetooth, other apps' virtual ports). Bytes go to the BEAM with [nativeMidi] on the thread that
 *    delivered them, tagged with their source (`-1 - instance` for a virtual port, `deviceId * 16 + port`
 *    for a device) and two CLOCK_MONOTONIC stamps (the sender's, and now).
 *  - MIDI out: [midiSend] sends out of an instance's virtual port.
 *  - State (MIDI devices, who has the virtual ports open, audio output devices, the Bluetooth MIDI scan) is
 *    pushed whole as JSON ([nativeEvent]) whenever it changes; [call] answers commands from the BEAM.
 *
 * [init] runs from MainActivity.onCreate. Without it (Android started the app process only for the MIDI
 * service, before any activity), the BEAM isn't running and incoming bytes are dropped.
 */
object FMutateIO {
    private const val TAG = "FMutateIO"
    private const val BLE_MIDI_SERVICE = "03B80E5A-EDE8-4B33-A751-6CE34EC4C700"
    private const val SCAN_MS = 10_000L
    private const val PERMISSION_WAIT_MS = 30_000L
    private const val PERMISSION_CODE = 0x4D49

    @JvmStatic private external fun nativeInit()
    @JvmStatic private external fun nativeMidi(
        source: Int, data: ByteArray, offset: Int, count: Int, sentNs: Long, recvNs: Long,
    ): Boolean
    @JvmStatic private external fun nativeEvent(json: String)

    @Volatile private var ready = false
    private var context: Context? = null
    private var activity: WeakReference<Activity>? = null
    private val main = Handler(Looper.getMainLooper())
    private var midi: MidiManager? = null
    private var audio: AudioManager? = null

    private class Opened(val device: MidiDevice, val ports: List<MidiOutputPort>)

    private val opened = ConcurrentHashMap<Int, Opened>()
    private val services = ConcurrentHashMap<Int, FMutateMidiService>()
    private val senders = ConcurrentHashMap<Int, Boolean>()
    private val listeners = ConcurrentHashMap<Int, Int>()
    private val found = ConcurrentHashMap<String, BluetoothDevice>()
    @Volatile private var scanning = false
    private var scanCallback: ScanCallback? = null

    /** From MainActivity.onCreate (main thread). Safe to call again when the activity is recreated. */
    fun init(activity: Activity) {
        this.activity = WeakReference(activity)
        if (ready) return
        val ctx = activity.applicationContext
        context = ctx
        audio = ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        if (ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_MIDI)) {
            midi = ctx.getSystemService(Context.MIDI_SERVICE) as? MidiManager
        }
        midi?.let { m ->
            if (Build.VERSION.SDK_INT >= 33) {
                m.registerDeviceCallback(MidiManager.TRANSPORT_MIDI_BYTE_STREAM, { main.post(it) }, deviceCallback)
            } else {
                @Suppress("DEPRECATION")
                m.registerDeviceCallback(deviceCallback, main)
            }
        }
        audio?.registerAudioDeviceCallback(audioCallback, main)
        nativeInit()
        ready = true
        push()
    }

    // ── MIDI in ────────────────────────────────────────────────────────────

    /** Bytes another app sent into an instance's virtual port (binder thread). */
    fun fromVirtual(instance: Int, msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
        if (ready) nativeMidi(-1 - instance, msg, offset, count, timestamp, System.nanoTime())
    }

    private fun receiverFor(source: Int) = object : MidiReceiver() {
        override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
            nativeMidi(source, msg, offset, count, timestamp, System.nanoTime())
        }
    }

    private fun open(id: Int): JSONObject {
        val m = midi ?: return error("no_midi")
        if (opened.containsKey(id)) return ok()
        val info = devices().firstOrNull { it.id == id } ?: return error("no_such_device")
        m.openDevice(info, { device -> connect(device) }, main)
        return ok()
    }

    /** Opens every output port of the device and plays what it sends. */
    private fun connect(device: MidiDevice?) {
        if (device == null) {
            Log.w(TAG, "open failed")
            push()
            return
        }
        val id = device.info.id
        val ports = (0 until device.info.outputPortCount).mapNotNull { p ->
            device.openOutputPort(p)?.also { it.connect(receiverFor(id * 16 + p)) }
        }
        opened[id] = Opened(device, ports)
        push()
    }

    private fun close(id: Int): JSONObject {
        opened.remove(id)?.let { o ->
            o.ports.forEach { runCatching { it.close() } }
            runCatching { o.device.close() }
        }
        push()
        return ok()
    }

    private val deviceCallback = object : MidiManager.DeviceCallback() {
        override fun onDeviceAdded(device: MidiDeviceInfo) = push()
        override fun onDeviceRemoved(device: MidiDeviceInfo) {
            if (opened.containsKey(device.id)) close(device.id) else push()
        }
        override fun onDeviceStatusChanged(status: android.media.midi.MidiDeviceStatus) = push()
    }

    // ── MIDI out, the virtual ports ────────────────────────────────────────

    fun attachService(instance: Int, service: FMutateMidiService) {
        services[instance] = service
    }

    fun detachService(instance: Int, service: FMutateMidiService) {
        services.remove(instance, service)
        senders.remove(instance)
        listeners.remove(instance)
        if (ready) main.post { push() }
    }

    fun virtualStatus(instance: Int, senderOpen: Boolean, listenerCount: Int) {
        senders[instance] = senderOpen
        listeners[instance] = listenerCount
        if (ready) main.post { push() }
    }

    /** From the BEAM (fm1io midi_send): out of instance [port]'s virtual port. False when nobody listens. */
    @JvmStatic
    fun midiSend(port: Int, data: ByteArray, timestamp: Long): Boolean {
        if ((listeners[port] ?: 0) == 0) return false
        return services[port]?.send(data, timestamp) ?: false
    }

    // ── Bluetooth MIDI ─────────────────────────────────────────────────────

    private fun blePermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= 31) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun bleGranted(): Boolean {
        val ctx = context ?: return false
        return blePermissions().all { ContextCompat.checkSelfPermission(ctx, it) == PackageManager.PERMISSION_GRANTED }
    }

    private fun bleSupported(): Boolean {
        val ctx = context ?: return false
        return midi != null && ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) &&
            (ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter != null
    }

    private fun scanBluetooth(): JSONObject {
        if (!bleSupported()) return error("unsupported")
        if (!bleGranted()) {
            val act = activity?.get() ?: return error("no_activity")
            main.post { ActivityCompat.requestPermissions(act, blePermissions(), PERMISSION_CODE) }
            // the answer goes to MainActivity; start the scan as soon as it is granted
            val until = System.currentTimeMillis() + PERMISSION_WAIT_MS
            val check = object : Runnable {
                override fun run() {
                    if (bleGranted()) startScan()
                    else if (System.currentTimeMillis() < until) main.postDelayed(this, 500)
                    else push()
                }
            }
            main.postDelayed(check, 500)
            return ok().put("permission", "requested")
        }
        main.post { startScan() }
        return ok()
    }

    @Suppress("MissingPermission")
    private fun startScan() {
        val ctx = context ?: return
        val scanner = (ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)
            ?.adapter?.bluetoothLeScanner ?: return push()
        if (scanning) return
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                found[result.device.address] = result.device
                push()
            }
            override fun onScanFailed(errorCode: Int) {
                Log.w(TAG, "BLE scan failed: $errorCode")
                scanning = false
                push()
            }
        }
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid.fromString(BLE_MIDI_SERVICE)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        try {
            scanner.startScan(listOf(filter), settings, cb)
        } catch (e: SecurityException) {
            Log.w(TAG, "BLE scan not permitted: $e")
            return push()
        }
        scanCallback = cb
        scanning = true
        push()
        main.postDelayed({ stopScan() }, SCAN_MS)
    }

    @Suppress("MissingPermission")
    private fun stopScan() {
        val ctx = context ?: return
        val cb = scanCallback ?: return
        runCatching {
            (ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter?.bluetoothLeScanner?.stopScan(cb)
        }
        scanCallback = null
        scanning = false
        push()
    }

    /** Connects a scanned Bluetooth MIDI device and plays what it sends. */
    private fun openBluetooth(address: String): JSONObject {
        val m = midi ?: return error("no_midi")
        val device = found[address] ?: return error("not_found")
        m.openBluetoothDevice(device, { d -> connect(d) }, main)
        return ok()
    }

    // ── Audio outputs ──────────────────────────────────────────────────────

    private val audioCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) = push()
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) = push()
    }

    private fun audioType(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE,
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "speaker"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET -> "headphones"
        AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_ACCESSORY -> "usb"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_BLE_SPEAKER -> "bluetooth"
        else -> "other"
    }

    // ── State ──────────────────────────────────────────────────────────────

    private fun devices(): List<MidiDeviceInfo> {
        val m = midi ?: return emptyList()
        val all = if (Build.VERSION.SDK_INT >= 33) {
            m.getDevicesForTransport(MidiManager.TRANSPORT_MIDI_BYTE_STREAM).toList()
        } else {
            @Suppress("DEPRECATION")
            m.devices.toList()
        }
        // our own virtual ports aren't devices to play from (Android doesn't expose a device's owning package)
        return all.filter {
            !(it.type == MidiDeviceInfo.TYPE_VIRTUAL && it.properties.getString(MidiDeviceInfo.PROPERTY_NAME) in OWN_PORTS)
        }
    }

    /** The instances' virtual port names (res/xml/fmutate_midi_*.xml). */
    private val OWN_PORTS = setOf("FMutate A")

    private fun state(): JSONObject {
        val midiArr = JSONArray()
        for (d in devices()) {
            val p = d.properties
            midiArr.put(
                JSONObject()
                    .put("id", d.id)
                    .put("name", p.getString(MidiDeviceInfo.PROPERTY_NAME)
                        ?: p.getString(MidiDeviceInfo.PROPERTY_PRODUCT) ?: "MIDI device ${d.id}")
                    .put("manufacturer", p.getString(MidiDeviceInfo.PROPERTY_MANUFACTURER) ?: "")
                    .put("type", when (d.type) {
                        MidiDeviceInfo.TYPE_USB -> "usb"
                        MidiDeviceInfo.TYPE_BLUETOOTH -> "bluetooth"
                        else -> "virtual"
                    })
                    .put("outputs", d.outputPortCount)
                    .put("inputs", d.inputPortCount)
                    .put("open", opened.containsKey(d.id)),
            )
        }
        val virtual = JSONArray().put(
            JSONObject().put("instance", 0).put("name", "FMutate A")
                .put("senders", if (senders[0] == true) 1 else 0).put("listeners", listeners[0] ?: 0),
        )
        val audioArr = JSONArray()
        audio?.getDevices(AudioManager.GET_DEVICES_OUTPUTS)?.forEach { a ->
            audioArr.put(
                JSONObject().put("id", a.id).put("type", audioType(a.type)).put("name", a.productName.toString()),
            )
        }
        val foundArr = JSONArray()
        @Suppress("MissingPermission")
        found.values.forEach { b ->
            foundArr.put(JSONObject().put("address", b.address).put("name", runCatching { b.name }.getOrNull() ?: b.address))
        }
        val bt = JSONObject()
            .put("scanning", scanning)
            .put("permission", if (!bleSupported()) "unsupported" else if (bleGranted()) "granted" else "unknown")
            .put("found", foundArr)
        return JSONObject().put("midi", midiArr).put("virtual", virtual).put("audio", audioArr).put("bluetooth", bt)
    }

    private fun push() {
        if (!ready) return
        try {
            nativeEvent(state().toString())
        } catch (e: Throwable) {
            Log.w(TAG, "push failed: $e")
        }
    }

    // ── Commands from the BEAM ─────────────────────────────────────────────

    private fun ok() = JSONObject().put("ok", true)
    private fun error(reason: String) = JSONObject().put("error", reason)

    /** fm1io call/1 (a dirty scheduler thread): a JSON command, a JSON answer. */
    @JvmStatic
    fun call(json: String): String {
        val req = JSONObject(json)
        val rep = when (req.optString("op")) {
            "state" -> state()
            "open" -> open(req.getInt("id"))
            "close" -> close(req.getInt("id"))
            "scan_bluetooth" -> scanBluetooth()
            "open_bluetooth" -> openBluetooth(req.getString("address"))
            else -> error("unknown_op")
        }
        return rep.toString()
    }
}
