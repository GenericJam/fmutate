// FMutateOrientation.swift: the instrument holds its layout's frame (Kotlin's requestedOrientation =
// SENSOR_LANDSCAPE / SENSOR_PORTRAIT in InstrumentView.kt): landscape either way round, or portrait, while the
// surface is in a window; the other screens follow the phone again.
//
// iOS: AppDelegate's -application:supportedInterfaceOrientationsForWindow: reports this mask ahead of Mob's own
// lock (Mob.Device.lock_orientation/1), and requestGeometryUpdate turns the scene at once.

import UIKit

enum FMOrientation {
    /// What the instrument holds; empty when nothing (the app then follows Mob's lock, or the phone).
    static var mask: UIInterfaceOrientationMask = []
    private static weak var scene: UIWindowScene?

    /// Hold `landscape`'s frame (nil: let go) in `window`'s scene.
    static func hold(_ landscape: Bool?, _ window: UIWindow?) {
        let m: UIInterfaceOrientationMask = landscape.map { $0 ? .landscape : .portrait } ?? []
        if let s = window?.windowScene { scene = s }
        guard m != mask, let scene else { return }
        mask = m
        for w in scene.windows { w.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        if !m.isEmpty { scene.requestGeometryUpdate(.iOS(interfaceOrientations: m)) { _ in } }
    }
}

/// For AppDelegate.m: the held mask, 0 when none.
@_cdecl("fmutate_orientation_mask")
public func fmutateOrientationMask() -> UInt { FMOrientation.mask.rawValue }
