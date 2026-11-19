// FMutateFirmwareShm.swift: port of android/.../fmutate/FirmwareShm.kt.

import Foundation
import CoreGraphics
import Accelerate

/// Reads an engine's `<prefix>.fb` (docs/engine_protocol.md): the firmware's 240×240 RGB565 screen and its
/// LEDs, straight from shared memory (mmap, read-only), so neither ever passes through the BEAM. `poll()` once per
/// display frame.
///
/// iOS: Android's Bitmap takes RGB_565 as is; CoreGraphics has no 5-6-5 format, so a new frame is converted to
/// 32-bit BGRX (vImage) into one reusable buffer, and only when `seq` moved. The CGImage made from it is the one
/// allocation per new frame (CoreGraphics copies the pixels into it).
final class FMFirmwareShm {
    static let W = 240
    static let H = 240
    static let PIXELS = 8
    static let TRAILER = 8 + W * H * 2
    static let BYTES = TRAILER + 16
    static let MAGIC: UInt32 = 0x464D3146

    private let fd: Int32
    private let base: UnsafeMutableRawPointer
    private let length: Int
    private let hasTrailer: Bool
    private var seq: UInt32 = 0
    private var seenAny = false

    /// Reusable 32-bit frame (BGRA in memory) and the bitmap context over it.
    private let rgba: UnsafeMutableRawPointer
    private let context: CGContext

    /// The screen as last converted; replaced by poll() when a new frame arrived.
    private(set) var image: CGImage?

    init?(path: String) {
        let fd = open(path, O_RDONLY)
        if fd < 0 { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { close(fd); return nil }
        let len = min(Int(st.st_size), FMFirmwareShm.BYTES)
        guard let p = mmap(nil, len, PROT_READ, MAP_SHARED, fd, 0), p != MAP_FAILED else { close(fd); return nil }
        let rowBytes = FMFirmwareShm.W * 4
        let buf = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * FMFirmwareShm.H, alignment: 16)
        guard let ctx = CGContext(
            data: buf, width: FMFirmwareShm.W, height: FMFirmwareShm.H, bitsPerComponent: 8, bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            buf.deallocate(); munmap(p, len); close(fd); return nil
        }
        self.fd = fd
        self.base = p
        self.length = len
        self.hasTrailer = Int(st.st_size) >= FMFirmwareShm.BYTES
        self.rgba = buf
        self.context = ctx
    }

    deinit {
        munmap(base, length)
        close(fd)
        rgba.deallocate()
    }

    @inline(__always) private func u32(_ off: Int) -> UInt32 {
        UInt32(littleEndian: base.loadUnaligned(fromByteOffset: off, as: UInt32.self))
    }

    var valid: Bool { length >= FMFirmwareShm.TRAILER && u32(0) == FMFirmwareShm.MAGIC }

    /// Converts a new frame into [image] only if the engine's frame counter moved since the last copy. True when
    /// the pixels changed.
    func poll() -> Bool {
        if !valid { return false }
        let s = u32(4)
        if seenAny && s == seq { return false }
        var src = vImage_Buffer(data: base + FMFirmwareShm.PIXELS, height: vImagePixelCount(FMFirmwareShm.H),
                                width: vImagePixelCount(FMFirmwareShm.W), rowBytes: FMFirmwareShm.W * 2)
        var dst = vImage_Buffer(data: rgba, height: vImagePixelCount(FMFirmwareShm.H),
                                width: vImagePixelCount(FMFirmwareShm.W), rowBytes: FMFirmwareShm.W * 4)
        // the engine writes RGB565 little-endian, vImage's RGB565 is host order (arm64: little-endian)
        _ = vImageConvert_RGB565toBGRA8888(255, &src, &dst, vImage_Flags(kvImageNoFlags))
        image = context.makeImage()
        seq = s
        seenAny = true
        return true
    }

    var ledButtons: Int { hasTrailer ? Int(u32(FMFirmwareShm.TRAILER)) : 0 }
    var ledKeys: Int { hasTrailer ? Int(u32(FMFirmwareShm.TRAILER + 4)) : 0 }
    var glowKeys: Int { hasTrailer ? Int(u32(FMFirmwareShm.TRAILER + 8)) : 0 }
}

/// Sharp scaling for a firmware screen drawn at a size that isn't a whole multiple of 240: the frame is first
/// blown up nearest-neighbour to the next whole multiple (this), then drawn bilinear down to the target (the
/// screen layer's `.linear` minification filter). Every firmware pixel comes out the same size (no doubled rows or
/// columns, as plain nearest-neighbour gives), and edges soften by at most one device pixel. One context per
/// factor, reused.
final class FMScreenScaler {
    private var factor = 0
    private var context: CGContext?

    /// [src] at ×[k] (nearest-neighbour). Call when drawing a new frame.
    func prescaled(_ k: Int, _ src: CGImage) -> CGImage? {
        if k != factor || context == nil {
            let side = FMFirmwareShm.W * k
            context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
            context?.interpolationQuality = .none
            factor = k
        }
        guard let ctx = context else { return nil }
        let side = CGFloat(FMFirmwareShm.W * k)
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }
}
