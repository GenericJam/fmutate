package com.example.fmutate_app.fmutate

import android.app.Activity
import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.lang.ref.WeakReference

/**
 * The phone's audio outputs for FMutate.IO (HANDOFF §10), bridged to the BEAM by the `fm1io` NIF
 * (c_src/fm1io.c, Elixir FMutate.IONif): the list is pushed whole as JSON ([nativeEvent]) whenever it
 * changes, and [call] answers `{"op": "state"}` and `{"op": "quit"}` (the notification's Quit). MIDI is the
 * mob_midi plugin's (FMutate.IO, FMutate.MIDI); what learned MIDI controls show on the instrument comes in
 * through [surface].
 *
 * [init] runs from MainActivity.onCreate, [activityDestroyed] from its onDestroy.
 */
object FMutateIO {
    private const val TAG = "FMutateIO"

    @JvmStatic private external fun nativeInit()
    @JvmStatic private external fun nativeEvent(json: String)

    @Volatile private var ready = false
    private val main = Handler(Looper.getMainLooper())
    private var audio: AudioManager? = null
    @Volatile private var activityRef: WeakReference<Activity>? = null
    // main thread only
    private var quitting = false

    /** From MainActivity.onCreate (main thread). Safe to call again when the activity is recreated. */
    fun init(activity: Activity) {
        activityRef = WeakReference(activity)
        if (ready) return
        audio = activity.applicationContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        audio?.registerAudioDeviceCallback(audioCallback, main)
        nativeInit()
        ready = true
        push()
    }

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

    private fun state(): JSONObject {
        val audioArr = JSONArray()
        audio?.getDevices(AudioManager.GET_DEVICES_OUTPUTS)?.forEach { a ->
            audioArr.put(
                JSONObject().put("id", a.id).put("type", audioType(a.type)).put("name", a.productName.toString()),
            )
        }
        return JSONObject().put("audio", audioArr)
    }

    private fun push() {
        if (!ready) return
        try {
            nativeEvent(state().toString())
        } catch (e: Throwable) {
            Log.w(TAG, "push failed: $e")
        }
    }

    /** fm1io call/1 (a dirty scheduler thread): a JSON command, a JSON answer. */
    @JvmStatic
    fun call(json: String): String {
        val rep = when (JSONObject(json).optString("op")) {
            "state" -> state()
            "quit" -> {
                main.post { quit() }
                JSONObject().put("ok", true)
            }
            else -> JSONObject().put("error", "unknown_op")
        }
        return rep.toString()
    }

    /**
     * The notification's Quit (FMutate.Background, once the engines have ended and the audio output is closed):
     * finish the activity and remove its task from Recents, then end the process once the activity is destroyed.
     * The BEAM can't start twice in one process (MainActivity), so the process goes with the activity; nothing
     * restarts it (the keep-alive service has stopped, and it is START_NOT_STICKY). An activity Android has
     * already destroyed in the background: the process ends now.
     */
    private fun quit() {
        if (quitting) return
        quitting = true
        val activity = activityRef?.get()
        if (activity == null || activity.isDestroyed) {
            endProcess()
            return
        }
        activity.finishAndRemoveTask()
        // (onDestroy comes within a frame or two; don't depend on it)
        main.postDelayed({ endProcess() }, 2_000)
    }

    /** From MainActivity.onDestroy. */
    fun activityDestroyed() {
        if (quitting) endProcess()
    }

    private fun endProcess() {
        Log.i(TAG, "quit: ending the process")
        Process.killProcess(Process.myPid())
    }

    /** fm1io surface/1 (a dirty scheduler thread): what learned MIDI controls show ([MidiSurface]). */
    @JvmStatic
    fun surface(text: String) = MidiSurface.offer(text)
}
