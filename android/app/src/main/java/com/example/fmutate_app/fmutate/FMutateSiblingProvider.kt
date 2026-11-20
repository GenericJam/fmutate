package com.example.fmutate_app.fmutate

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.os.SystemClock
import java.io.File

/**
 * Hands sibling apps what they need to connect over Erlang distribution (protocol.md §5, §7): this app's node
 * name, its port and the sibling cookie, and takes their node name before they connect. Only for apps holding
 * `com.genericjam.fmutate.permission.SIBLING`, a signature permission: Android grants it only to apps signed
 * with FMutate's key.
 *
 *     query  content://com.genericjam.fmutate.siblings/node  →  one row: node, port, cookie, protocol
 *     call   content://com.genericjam.fmutate.siblings, "register", "<name>@127.0.0.1"
 *            →  Bundle "result": "ok" | "invalid" | "busy" | "rate_limited"
 *
 * FMutate.Dist writes the values to `files/dist/sibling` (`key=value` lines) at start; query only reads them.
 * A registered name is an empty file in `files/dist/requests`, which FMutate.Dist picks up (FMutate.Dist.Requests)
 * and lists in I/O as wanting to connect; FMutate's node refuses any name nobody registered or paired before it
 * reads it (the name of a connecting node would otherwise become an atom there, and any app can reach the
 * loopback port). The node is up only while FMutate runs (a sibling may need to launch it first).
 */
class FMutateSiblingProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun query(
        uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? {
        if (uri.lastPathSegment != "node") return null
        val ctx = context ?: return null
        val file = File(ctx.filesDir, "dist/sibling")
        if (!file.exists()) return null
        val values = file.readLines().mapNotNull { line ->
            val i = line.indexOf('=')
            if (i > 0) line.substring(0, i) to line.substring(i + 1) else null
        }.toMap()
        val columns = arrayOf("node", "port", "cookie", "protocol")
        return MatrixCursor(columns).apply { addRow(columns.map { values[it] ?: "" }.toTypedArray()) }
    }

    // call() isn't covered by the provider's readPermission: checked here.
    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
        if (method != "register") return null
        val ctx = context ?: return null
        ctx.enforceCallingPermission("${ctx.packageName}.permission.SIBLING", "register needs the SIBLING permission")
        return Bundle().apply { putString("result", register(ctx.filesDir, Binder.getCallingUid(), arg)) }
    }

    private fun register(files: File, uid: Int, name: String?): String {
        // the same rules as FMutate.Dist.Requests.valid?/1: a sibling's name on this phone, not an instance's
        if (name == null || !NAME.matches(name) || INSTANCE.containsMatchIn(name)) return "invalid"
        if (!allowed(uid)) return "rate_limited"
        val dir = File(files, "dist/requests")
        dir.mkdirs()
        val file = File(dir, name)
        if (file.exists()) return "ok"
        if ((dir.list()?.size ?: 0) >= MAX_PENDING) return "busy"
        file.createNewFile()
        return "ok"
    }

    // at most RATE registrations a minute per calling app
    private fun allowed(uid: Int): Boolean = synchronized(calls) {
        val now = SystemClock.elapsedRealtime()
        val recent = calls.getOrPut(uid) { ArrayDeque() }
        while (recent.isNotEmpty() && now - recent.first() > 60_000) recent.removeFirst()
        if (recent.size >= RATE) return false
        recent.addLast(now)
        true
    }

    private val calls = HashMap<Int, ArrayDeque<Long>>()

    override fun getType(uri: Uri): String = "vnd.android.cursor.item/vnd.com.genericjam.fmutate.node"
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0

    private companion object {
        val NAME = Regex("[a-z][a-z0-9_]{0,63}@127\\.0\\.0\\.1")
        val INSTANCE = Regex("^fmutate_[a-z]@")
        const val MAX_PENDING = 16
        const val RATE = 5
    }
}
