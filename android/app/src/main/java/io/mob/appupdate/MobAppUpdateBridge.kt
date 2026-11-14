// mob_app_update plugin — Android bridge (PackageManager / PackageInstaller).
//
// The zig NIF priv/native/jni/mob_app_update_nif.zig calls the @JvmStatic
// methods below and exports the native thunks (nativeRegister,
// nativeDeliverInstall). MobPluginBootstrap.registerAll(this) calls register()
// at startup and then hands the Activity over (MobActivityAware).
//
// Answers cross JNI as UTF-8 JSON byte arrays; MobAppUpdate decodes them and
// makes every decision (package / versionCode / signer pre-check) in Elixir.
// Paths cross as UTF-8 byte arrays too: GetStringUTFChars / NewStringUTF speak
// modified UTF-8.
//
// install() never installs silently: the session asks for user action on
// API 31+ (USER_ACTION_REQUIRED) and every STATUS_PENDING_USER_ACTION starts
// the system confirmation screen. Android itself refuses an update signed by
// another key; the Elixir pre-check only reports it earlier and clearly.
package io.mob.appupdate

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.Uri
import android.os.Build
import android.provider.Settings
import java.io.File
import java.lang.ref.WeakReference
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import org.json.JSONArray
import org.json.JSONObject

object MobAppUpdateBridge : io.mob.plugin.MobActivityAware {
    @JvmStatic external fun nativeRegister()

    // {:mob_app_update, {:install, status}} to `pid`: status -1 (PENDING_USER_ACTION)
    // -> :pending_user_action, 0 (SUCCESS) -> :success, anything else ->
    // {:failure, status, message}.
    @JvmStatic external fun nativeDeliverInstall(pid: Long, status: Int, message: ByteArray?)

    // Return codes of openInstallSettings / install; mob_app_update_nif.zig maps them.
    private const val OK = 0
    private const val ERR_NOT_READY = 1
    private const val ERR_FAILED = 2

    // Downloads live in <cacheDir>/mob_app_update; emptied once per process.
    private const val DIR = "mob_app_update"

    @Volatile private var appContext: Context? = null
    private var activityRef: WeakReference<Activity>? = null
    private var receiverRegistered = false
    private var cleaned = false

    // Session copies (up to the APK's size) run off the BEAM scheduler and the
    // UI thread, one at a time.
    private val worker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "mob_app_update").apply { isDaemon = true }
    }

    private class Pending(val pid: Long, val apk: File)

    private val sessions = ConcurrentHashMap<Int, Pending>()

    // Below API 33 a runtime-registered receiver is exported, so any app could
    // send it a fake PENDING_USER_ACTION carrying its own EXTRA_INTENT for us
    // to start. Only our PendingIntent (held by the system installer) carries
    // this per-process secret; a broadcast without it is ignored.
    private const val EXTRA_TOKEN = "io.mob.appupdate.TOKEN"
    private val token: String = ByteArray(16).also { SecureRandom().nextBytes(it) }
        .joinToString("") { "%02x".format(it) }

    @JvmStatic
    fun register() {
        nativeRegister()
    }

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
        val ctx = activity.applicationContext
        appContext = ctx
        synchronized(this) {
            if (cleaned) return
            cleaned = true
        }
        // A download or an install the previous process didn't finish (an
        // update that succeeded kills the process before it can clean up).
        worker.execute { File(ctx.cacheDir, DIR).listFiles()?.forEach { it.delete() } }
    }

    // The installed package as JSON, plus the download directory; null before
    // the Activity arrives.
    @JvmStatic
    fun info(): ByteArray? {
        val ctx = appContext ?: return null
        val pi = installedInfo(ctx.packageManager, ctx.packageName)
        val dir = File(ctx.cacheDir, DIR)
        dir.mkdirs()
        return describe(pi).put("download_dir", dir.absolutePath).toString().toByteArray(Charsets.UTF_8)
    }

    @JvmStatic
    fun canRequestInstalls(): Boolean = appContext?.packageManager?.canRequestPackageInstalls() ?: false

    // The "Install unknown apps" switch for this app.
    @JvmStatic
    fun openInstallSettings(): Int {
        val activity = activityRef?.get()
        val ctx: Context = activity ?: appContext ?: return ERR_NOT_READY
        val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + ctx.packageName))
        if (activity == null) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            ctx.startActivity(intent)
            OK
        } catch (e: Exception) {
            ERR_FAILED
        }
    }

    // The APK at `path` as JSON (same shape as info() without download_dir), or
    // {"error": "invalid_apk"} when PackageManager can't parse it; null before
    // the Activity arrives.
    @JvmStatic
    fun inspect(path: ByteArray): ByteArray? {
        val ctx = appContext ?: return null
        val file = String(path, Charsets.UTF_8)
        val pm = ctx.packageManager
        var pi = archiveInfo(pm, file, PackageManager.GET_SIGNING_CERTIFICATES)
        if (pi != null && pi.signingInfo == null) {
            pi = archiveInfo(pm, file, @Suppress("DEPRECATION") PackageManager.GET_SIGNATURES) ?: pi
        }
        val json = if (pi == null) JSONObject().put("error", "invalid_apk") else describe(pi)
        return json.toString().toByteArray(Charsets.UTF_8)
    }

    // Copies the APK into a PackageInstaller session and commits it; the
    // outcome goes to `pid` (nativeDeliverInstall).
    @JvmStatic
    fun install(pid: Long, path: ByteArray): Int {
        val ctx = appContext ?: return ERR_NOT_READY
        val apk = File(String(path, Charsets.UTF_8))
        return try {
            ensureReceiver(ctx)
            worker.execute { commitSession(ctx, pid, apk) }
            OK
        } catch (e: Exception) {
            ERR_FAILED
        }
    }

    private fun commitSession(ctx: Context, pid: Long, apk: File) {
        val installer = ctx.packageManager.packageInstaller
        var sessionId = -1
        try {
            val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
            params.setAppPackageName(ctx.packageName)
            params.setSize(apk.length())
            if (Build.VERSION.SDK_INT >= 31) {
                params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
            }
            sessionId = installer.createSession(params)
            installer.openSession(sessionId).use { session ->
                apk.inputStream().use { input ->
                    session.openWrite("base.apk", 0, apk.length()).use { out ->
                        input.copyTo(out, 1 shl 16)
                        session.fsync(out)
                    }
                }
                sessions[sessionId] = Pending(pid, apk)
                // Explicit (setPackage) so FLAG_MUTABLE is allowed on API 34+;
                // mutable so the installer can add its status extras.
                val status = Intent(statusAction(ctx)).setPackage(ctx.packageName).putExtra(EXTRA_TOKEN, token)
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                val sender = PendingIntent.getBroadcast(ctx, sessionId, status, flags).intentSender
                session.commit(sender)
            }
        } catch (e: Exception) {
            if (sessionId != -1) {
                sessions.remove(sessionId)
                try {
                    installer.abandonSession(sessionId)
                } catch (_: Exception) {
                }
            }
            apk.delete()
            val message = e.message ?: e.javaClass.name
            nativeDeliverInstall(pid, PackageInstaller.STATUS_FAILURE, message.toByteArray(Charsets.UTF_8))
        }
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.getStringExtra(EXTRA_TOKEN) != token) return
            val id = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
            val pending = sessions[id] ?: return
            val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
            if (status != PackageInstaller.STATUS_PENDING_USER_ACTION) {
                finish(id, pending, status, intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE))
                return
            }
            val confirm = confirmationIntent(intent)
            if (confirm == null) {
                abandon(context, id)
                finish(id, pending, PackageInstaller.STATUS_FAILURE, "no confirmation intent")
                return
            }
            try {
                context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                nativeDeliverInstall(pending.pid, status, null)
            } catch (e: Exception) {
                abandon(context, id)
                finish(id, pending, PackageInstaller.STATUS_FAILURE, e.message ?: e.javaClass.name)
            }
        }
    }

    private fun finish(id: Int, pending: Pending, status: Int, message: String?) {
        sessions.remove(id)
        pending.apk.delete()
        nativeDeliverInstall(pending.pid, status, (message ?: "").toByteArray(Charsets.UTF_8))
    }

    private fun abandon(ctx: Context, id: Int) {
        try {
            ctx.packageManager.packageInstaller.abandonSession(id)
        } catch (_: Exception) {
        }
    }

    private fun confirmationIntent(intent: Intent): Intent? =
        if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_INTENT)
        }

    private fun statusAction(ctx: Context) = ctx.packageName + ".mob_app_update.INSTALL_STATUS"

    private fun ensureReceiver(ctx: Context) {
        synchronized(this) {
            if (receiverRegistered) return
            val filter = IntentFilter(statusAction(ctx))
            if (Build.VERSION.SDK_INT >= 33) {
                ctx.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                ctx.registerReceiver(receiver, filter)
            }
            receiverRegistered = true
        }
    }

    private fun installedInfo(pm: PackageManager, pkg: String): PackageInfo =
        if (Build.VERSION.SDK_INT >= 33) {
            pm.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(PackageManager.GET_SIGNING_CERTIFICATES.toLong()))
        } else {
            pm.getPackageInfo(pkg, PackageManager.GET_SIGNING_CERTIFICATES)
        }

    private fun archiveInfo(pm: PackageManager, path: String, flags: Int): PackageInfo? =
        if (Build.VERSION.SDK_INT >= 33) {
            pm.getPackageArchiveInfo(path, PackageManager.PackageInfoFlags.of(flags.toLong()))
        } else {
            pm.getPackageArchiveInfo(path, flags)
        }

    // signers: the current signing certificates (SHA-256 of each, hex);
    // signer_history: the rotation lineage a single signer proves (oldest
    // first), empty for multiple signers.
    private fun describe(pi: PackageInfo): JSONObject {
        val json = JSONObject()
            .put("package", pi.packageName)
            .put("version_code", pi.longVersionCode)
            .put("version_name", pi.versionName ?: "")
        val si = pi.signingInfo
        if (si != null) {
            val multiple = si.hasMultipleSigners()
            json.put("multiple_signers", multiple)
                .put("signers", digests(si.apkContentsSigners))
                .put("signer_history", if (multiple) JSONArray() else digests(si.signingCertificateHistory))
        } else {
            @Suppress("DEPRECATION")
            val sigs = pi.signatures
            json.put("multiple_signers", (sigs?.size ?: 0) > 1)
                .put("signers", digests(sigs))
                .put("signer_history", JSONArray())
        }
        return json
    }

    private fun digests(sigs: Array<Signature>?): JSONArray {
        val out = JSONArray()
        sigs?.forEach { sig ->
            val digest = MessageDigest.getInstance("SHA-256").digest(sig.toByteArray())
            out.put(digest.joinToString("") { "%02x".format(it) })
        }
        return out
    }
}
