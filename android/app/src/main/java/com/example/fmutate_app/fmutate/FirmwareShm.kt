package com.example.fmutate_app.fmutate

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import java.io.Closeable
import java.io.RandomAccessFile
import java.nio.ByteOrder
import java.nio.MappedByteBuffer
import java.nio.channels.FileChannel

/**
 * Reads an engine's `<prefix>.fb` (docs/engine_protocol.md): the firmware's 240×240 RGB565 screen and its
 * LEDs, straight from shared memory, so neither ever passes through the BEAM. `poll()` once per display frame.
 */
class FirmwareShm(path: String) : Closeable {
    companion object {
        const val W = 240
        const val H = 240
        const val PIXELS = 8
        const val TRAILER = 8 + W * H * 2
        const val BYTES = TRAILER + 16
        const val MAGIC = 0x464D3146
    }

    private val file = RandomAccessFile(path, "r")
    private val buf: MappedByteBuffer =
        file.channel.map(FileChannel.MapMode.READ_ONLY, 0, minOf(file.length(), BYTES.toLong()))
    private val hasTrailer = file.length() >= BYTES
    private val pixels = buf.duplicate().apply { position(minOf(capacity(), PIXELS)); limit(minOf(capacity(), PIXELS + W * H * 2)) }.slice()
    private var seq = Int.MIN_VALUE

    init {
        buf.order(ByteOrder.LITTLE_ENDIAN)
    }

    val valid: Boolean get() = buf.capacity() >= TRAILER && buf.getInt(0) == MAGIC

    /** The screen as last copied; replaced in place by poll(). */
    val bitmap: Bitmap = Bitmap.createBitmap(W, H, Bitmap.Config.RGB_565)

    /**
     * Copies a new frame into [bitmap] only if the engine's frame counter moved since the last copy (no
     * allocation). True when the pixels changed.
     */
    fun poll(): Boolean {
        if (!valid) return false
        val s = buf.getInt(4)
        if (s == seq) return false
        // Android's RGB_565 is the same little-endian 5-6-5 the engine writes: a straight copy
        pixels.rewind()
        bitmap.copyPixelsFromBuffer(pixels)
        seq = s
        return true
    }

    val ledButtons: Int get() = if (hasTrailer) buf.getInt(TRAILER) else 0
    val ledKeys: Int get() = if (hasTrailer) buf.getInt(TRAILER + 4) else 0
    val glowKeys: Int get() = if (hasTrailer) buf.getInt(TRAILER + 8) else 0

    override fun close() {
        file.close()
    }
}

/**
 * Sharp scaling for a firmware screen drawn at a size that isn't a whole multiple of 240: the frame is first
 * blown up nearest-neighbour to the next whole multiple (this), then drawn bilinear down to the target. Every
 * firmware pixel comes out the same size (no doubled rows or columns, as plain nearest-neighbour gives), and
 * edges soften by at most one device pixel. One buffer per factor, reused: no allocation per frame.
 */
class ScreenScaler(private val src: Bitmap) {
    private var factor = 0
    private var canvas: Canvas? = null
    private var image: ImageBitmap? = null
    private val nearest = Paint().apply { isFilterBitmap = false }
    private val dst = Rect()

    /** The current frame of [src] at ×[k] (nearest-neighbour). Call when drawing a new frame. */
    fun prescaled(k: Int): ImageBitmap {
        if (k != factor) {
            val big = Bitmap.createBitmap(src.width * k, src.height * k, Bitmap.Config.RGB_565)
            canvas = Canvas(big)
            image = big.asImageBitmap()
            dst.set(0, 0, big.width, big.height)
            factor = k
        }
        canvas!!.drawBitmap(src, null, dst, nearest)
        return image!!
    }
}
