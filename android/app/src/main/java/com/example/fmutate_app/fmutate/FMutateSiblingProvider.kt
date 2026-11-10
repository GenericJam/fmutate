package com.example.fmutate_app.fmutate

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import java.io.File

/**
 * Hands sibling apps what they need to connect over Erlang distribution (protocol.md §5): this app's node
 * name, its port and the sibling cookie. Readable only by apps holding
 * `com.genericjam.fmutate.permission.SIBLING`, a signature permission: Android grants it only to apps signed
 * with FMutate's key, so the signing certificate is checked before the cookie is handed over.
 *
 *     content://com.genericjam.fmutate.siblings/node  →  one row: node, port, cookie, protocol
 *
 * FMutate.Dist writes the values to `files/dist/sibling` (`key=value` lines) at start; this only reads them.
 * The node is up only while FMutate runs (a sibling may need to launch it first).
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

    override fun getType(uri: Uri): String = "vnd.android.cursor.item/vnd.com.genericjam.fmutate.node"
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
}
