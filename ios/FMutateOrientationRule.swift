// FMutateOrientationRule.swift: FMOrientation's decisions (FMutateOrientation.swift has the why), free of UIKit so
// ios/Tests runs them on a Mac. The types mirror UIKit's raw values: FMOrientationMask is
// UIInterfaceOrientationMask's, FMDeviceOrientation is UIDeviceOrientation's.

/// UIInterfaceOrientationMask, by raw value (1 << UIInterfaceOrientation).
struct FMOrientationMask: OptionSet, Equatable {
    let rawValue: UInt
    static let portrait = FMOrientationMask(rawValue: 1 << 1)
    static let portraitUpsideDown = FMOrientationMask(rawValue: 1 << 2)
    static let landscapeRight = FMOrientationMask(rawValue: 1 << 3)
    static let landscapeLeft = FMOrientationMask(rawValue: 1 << 4)
    static let landscape: FMOrientationMask = [.landscapeLeft, .landscapeRight]
}

/// UIDeviceOrientation, by raw value.
enum FMDeviceOrientation: Int {
    case unknown, portrait, portraitUpsideDown, landscapeLeft, landscapeRight, faceUp, faceDown
}

enum FMOrientationRule {
    /// The mask to hold for `landscape` (nil: let go, empty), or nil to do nothing: the mask held now (`held`) is
    /// already that, or there is no scene to turn yet.
    static func hold(_ landscape: Bool?, held: FMOrientationMask, hasScene: Bool) -> FMOrientationMask? {
        let m: FMOrientationMask = landscape.map { $0 ? .landscape : .portrait } ?? []
        return m != held && hasScene ? m : nil
    }

    /// The interface orientation to turn the scene to once `mask` is held: the mask itself, or on letting go (empty)
    /// the one upright for the phone held as `device` (`upright`).
    static func turn(_ mask: FMOrientationMask, _ device: FMDeviceOrientation) -> FMOrientationMask? {
        mask.isEmpty ? upright(device) : mask
    }

    /// The interface orientation that puts the screen upright for the phone held as `o`; nil when flat or unknown
    /// (the scene then stays as it is until the phone turns). A device turned left shows the interface turned right.
    static func upright(_ o: FMDeviceOrientation) -> FMOrientationMask? {
        switch o {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        case .unknown, .faceUp, .faceDown: return nil
        }
    }
}
