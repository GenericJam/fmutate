package com.example.fmutate_app.fmutate

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * What the next BEAM launch gets from `mob_init_args` once FMutate has put its transport in: the launcher
 * (`mob_init_args.zig`) splits on space, tab, CR, LF and NUL, keeps 63 arguments and 1023 bytes, and drops
 * the rest. A file past those limits would lose arguments, so it is left as it was.
 */
class DistInitArgsTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val transport = listOf("-proto_dist", "fmutate_tcp")

    private fun launched(contents: String?) = DistInitArgs.tokens(contents!!)

    @Test
    fun noFileGetsOnlyTheTransport() {
        assertEquals(transport, launched(DistInitArgs.withTransport("")))

        val dir = tmp.newFolder()
        assertTrue(DistInitArgs.install(dir))
        assertEquals(transport, DistInitArgs.tokens(File(dir, DistInitArgs.FILE_NAME).readText()))
    }

    @Test
    fun otherArgumentsKeepTheirOrderWhateverSeparatesThem() {
        val existing = "  -ssl_dist_optfile /data/x.conf\t-kernel\r\nnet_ticktime 20\u0000-extra_flag\n"
        assertEquals(
            transport + listOf("-ssl_dist_optfile", "/data/x.conf", "-kernel", "net_ticktime", "20", "-extra_flag"),
            launched(DistInitArgs.withTransport(existing)),
        )
    }

    @Test
    fun everyOtherProtoDistGoesWithItsValues() {
        // init reads a flag's values up to the next flag: `-proto_dist a b` would be [["a", "b"]], and two
        // -proto_dist flags would be two lists, neither of which FMutate.Dist accepts
        assertEquals(
            transport + listOf("-setcookie", "c", "-name", "x@127.0.0.1"),
            launched(
                DistInitArgs.withTransport(
                    "-proto_dist inet_tls extra -setcookie c -proto_dist inet6_tcp -name x@127.0.0.1",
                ),
            ),
        )
        assertEquals(transport, launched(DistInitArgs.withTransport("-proto_dist fmutate_tcp -proto_dist fmutate_tcp")))
    }

    @Test
    fun aDanglingProtoDistIsDroppedWithoutTakingTheNextFlag() {
        assertEquals(transport + listOf("-a"), launched(DistInitArgs.withTransport("-a -proto_dist")))
        assertEquals(transport + listOf("-name", "x"), launched(DistInitArgs.withTransport("-proto_dist -name x")))
    }

    @Test
    fun sixtyThreeArgumentsFitSixtyFourDoNot() {
        val fits = (1..61).joinToString(" ") { "-a$it" }
        assertEquals(63, launched(DistInitArgs.withTransport(fits)).size)

        val over = (1..62).joinToString(" ") { "-a$it" }
        assertNull(DistInitArgs.withTransport(over))
        // an old transport doesn't count: it is replaced, not added to
        assertEquals(63, launched(DistInitArgs.withTransport("-proto_dist inet_tls $fits")).size)
    }

    @Test
    fun a1023ByteFileFitsA1024ByteOneDoesNot() {
        // "-proto_dist fmutate_tcp" + " " + token + "\n"
        val fits = DistInitArgs.withTransport("-" + "x".repeat(997))
        assertEquals(1023, fits!!.length)

        assertNull(DistInitArgs.withTransport("-" + "x".repeat(998)))
    }

    @Test
    fun aFileWithNoRoomIsLeftAsItWas() {
        val dir = tmp.newFolder()
        val file = File(dir, DistInitArgs.FILE_NAME)
        val old = (1..62).joinToString(" ") { "-a$it" }.toByteArray()
        file.writeBytes(old)

        assertFalse(DistInitArgs.install(dir))
        assertArrayEquals(old, file.readBytes())
        assertEquals(listOf(DistInitArgs.FILE_NAME), dir.list()!!.toList())
    }

    @Test
    fun installingKeepsOtherArgumentsByteForByteAndIsDoneOnce() {
        val dir = tmp.newFolder()
        val file = File(dir, DistInitArgs.FILE_NAME)
        // é in UTF-8, and a byte that isn't UTF-8 at all
        val path = byteArrayOf('/'.code.toByte(), 0xC3.toByte(), 0xA9.toByte(), 0xFF.toByte())
        file.writeBytes("-proto_dist inet_tls -ssl_dist_optfile ".toByteArray() + path + "\n".toByteArray())

        assertTrue(DistInitArgs.install(dir))
        val expected = "-proto_dist fmutate_tcp -ssl_dist_optfile ".toByteArray() + path + "\n".toByteArray()
        assertArrayEquals(expected, file.readBytes())
        assertEquals(listOf(DistInitArgs.FILE_NAME), dir.list()!!.toList())

        // already in place: not rewritten
        file.setLastModified(1_000_000L)
        assertTrue(DistInitArgs.install(dir))
        assertEquals(1_000_000L, file.lastModified())
        assertArrayEquals(expected, file.readBytes())
    }
}
