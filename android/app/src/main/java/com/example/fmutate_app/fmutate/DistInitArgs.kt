package com.example.fmutate_app.fmutate

import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * FMutate's distribution transport in the BEAM's init arguments: `$MOB_DATA_DIR/mob_init_args` (filesDir),
 * which Mob's launcher reads at every BEAM start (`mob_init_args.zig`, `Mob.InitArgs`).
 *
 * net_kernel opens its socket inside `Node.start/2`, before Elixir can call `allow/1`. `-proto_dist
 * fmutate_tcp` (`src/fmutate_tcp_dist.erl`) parks the acceptor until `FMutate.Dist` has installed the allow
 * list, and `-proto_dist` is only read at boot, so it has to be in the file before the very first launch:
 * written from Elixir it would only protect the next one. Release builds refuse to start distribution
 * without it (`FMutate.Dist`).
 *
 * The file is read and written as ISO-8859-1, one char per byte, so arguments that aren't ASCII come back
 * byte for byte and a string's length is its size on disk.
 */
object DistInitArgs {
    const val FILE_NAME = "mob_init_args"

    // the launcher's limits: the whole file in 1023 bytes, 63 arguments; past them it drops arguments
    const val MAX_BYTES = 1023
    const val MAX_ARGS = 63

    private val TRANSPORT = listOf("-proto_dist", "fmutate_tcp")

    /** What the launcher splits on (NUL too, so a stray one can't end the list). */
    private fun isSeparator(c: Char) = c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\u0000'

    /** The arguments the launcher reads from [text]. */
    fun tokens(text: String): List<String> {
        val tokens = mutableListOf<String>()
        var start = -1

        for (i in text.indices) {
            if (isSeparator(text[i])) {
                if (start >= 0) tokens += text.substring(start, i)
                start = -1
            } else if (start < 0) {
                start = i
            }
        }

        if (start >= 0) tokens += text.substring(start)
        return tokens
    }

    /**
     * The file's new contents: FMutate's transport first, then [existing]'s arguments without any other
     * `-proto_dist` (with its values: the arguments up to the next flag, as `init` reads them). Null when
     * that doesn't fit the launcher's limits, which would drop arguments.
     */
    fun withTransport(existing: String): String? {
        val tokens = tokens(existing)
        val args = TRANSPORT.toMutableList()
        var i = 0

        while (i < tokens.size) {
            if (tokens[i] == "-proto_dist") {
                i++
                while (i < tokens.size && !tokens[i].startsWith("-")) i++
            } else {
                args += tokens[i++]
            }
        }

        val contents = args.joinToString(separator = " ", postfix = "\n")
        return if (args.size <= MAX_ARGS && contents.length <= MAX_BYTES) contents else null
    }

    /**
     * Puts the transport in [dir]'s init arguments file, replacing it atomically (a launch never reads half
     * of it). False, with the file left as it was, when there is no room.
     */
    fun install(dir: File): Boolean {
        val target = File(dir, FILE_NAME)
        val existing = if (target.isFile) target.readText(Charsets.ISO_8859_1) else ""
        val contents = withTransport(existing) ?: return false
        if (contents == existing) return true

        val replacement = File(dir, "$FILE_NAME.new")

        try {
            replacement.writeText(contents, Charsets.ISO_8859_1)
            Files.move(
                replacement.toPath(),
                target.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
        } finally {
            replacement.delete()
        }

        return true
    }
}
