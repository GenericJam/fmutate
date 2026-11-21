// FMutateOrientation.swift: the instrument holds its layout's frame (Kotlin's requestedOrientation =
// SENSOR_LANDSCAPE / SENSOR_PORTRAIT in InstrumentView.kt): landscape either way round, or portrait, while the
// surface is on screen; the other screens follow the phone again.
//
// iOS: AppDelegate's -application:supportedInterfaceOrientationsForWindow: reports this mask ahead of Mob's own
// lock (Mob.Device.lock_orientation/1), and requestGeometryUpdate turns the scene at once. Letting go turns the
// scene to the way the phone is held: iOS rotates on a change of the phone's orientation only, so a phone held
// upright all along would otherwise leave the next screen in the instrument's landscape (Android's UNSPECIFIED
// re-reads the sensor by itself).

import UIKit

// The decisions (which mask, whether anything changes, which way to turn) are FMOrientationRule's, in
// FMutateOrientationRule.swift, tested on a Mac by ios/Tests.
enum FMOrientation {
    /// What the instrument holds; empty when nothing (the app then follows Mob's lock, or the phone).
    static var mask: FMOrientationMask = []
    private static weak var scene: UIWindowScene?

    /// Hold `landscape`'s frame (nil: let go) in `window`'s scene.
    static func hold(_ landscape: Bool?, _ window: UIWindow?) {
        if let s = window?.windowScene { scene = s }
        let s = scene
        guard let m = FMOrientationRule.hold(landscape, held: mask, hasScene: s != nil), let s else { return }
        // UIDevice reports the phone's orientation only while someone asked for its notifications
        if !UIDevice.current.isGeneratingDeviceOrientationNotifications {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
        mask = m
        for w in s.windows { w.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        let device = FMDeviceOrientation(rawValue: UIDevice.current.orientation.rawValue) ?? .unknown
        if let turn = FMOrientationRule.turn(m, device) {
            s.requestGeometryUpdate(.iOS(interfaceOrientations: UIInterfaceOrientationMask(rawValue: turn.rawValue))) { _ in }
        }
    }
}

/// For AppDelegate.m: the held mask, 0 when none.
@_cdecl("fmutate_orientation_mask")
public func fmutateOrientationMask() -> UInt { FMOrientation.mask.rawValue }
