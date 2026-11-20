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

enum FMOrientation {
    /// What the instrument holds; empty when nothing (the app then follows Mob's lock, or the phone).
    static var mask: UIInterfaceOrientationMask = []
    private static weak var scene: UIWindowScene?

    /// Hold `landscape`'s frame (nil: let go) in `window`'s scene.
    static func hold(_ landscape: Bool?, _ window: UIWindow?) {
        let m: UIInterfaceOrientationMask = landscape.map { $0 ? .landscape : .portrait } ?? []
        if let s = window?.windowScene { scene = s }
        guard m != mask, let scene else { return }
        // UIDevice reports the phone's orientation only while someone asked for its notifications
        if !UIDevice.current.isGeneratingDeviceOrientationNotifications {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
        mask = m
        for w in scene.windows { w.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        if let turn = m.isEmpty ? held(UIDevice.current.orientation) : m {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: turn)) { _ in }
        }
    }

    /// The interface orientation that puts the screen upright for the phone held as `o`; nil when flat or unknown
    /// (the scene then stays as it is until the phone turns). A device turned left shows the interface turned right.
    private static func held(_ o: UIDeviceOrientation) -> UIInterfaceOrientationMask? {
        switch o {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default: return nil
        }
    }
}

/// For AppDelegate.m: the held mask, 0 when none.
@_cdecl("fmutate_orientation_mask")
public func fmutateOrientationMask() -> UInt { FMOrientation.mask.rawValue }
