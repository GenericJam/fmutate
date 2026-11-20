// Strike position on a keyboard strip: a port of StrikeMath.kt (its doc has the why and the numbers). `front` is where
// the finger is on its key: 1 at the front edge (the bottom of a horizontal strip, nearest the player), 0 at the back.

import Foundation
import CoreGraphics

enum FMStrikeMath {
    /// How far below a front-edge strike a strike at velocity 1 plays, by its level alone (dB).
    static let levelRangeDb = 24.0

    /// Velocity from where a key is struck: `max` at its front edge, `min` at its back edge.
    static func velocity(_ front: CGFloat, _ min: Int, _ max: Int) -> Int {
        fmClamp(fmRound(CGFloat(min) + CGFloat(max - min) * front), 1, 127)
    }

    /// The level a note starts at (MIDI polyphonic aftertouch, firmwares with `caps.note_pressure`) from its strike
    /// velocity: 127 at velocity 127, then equal dB steps down to `levelRangeDb` below it at velocity 1.
    static func strikeLevel(_ vel: Int) -> Int {
        let db = -levelRangeDb * Double(127 - fmClamp(vel, 1, 127)) / 126
        return fmRound(CGFloat(127 * pow(10, db / 40)))
    }

    /// A held note's level from where the finger is now (`front`), relative to where it struck (`struck`, at level
    /// `strike`): the strike's level there, rising to 127 at the front edge and fading to silence at the back edge.
    static func heldLevel(_ front: CGFloat, _ struck: CGFloat, _ strike: Int) -> Int {
        if front >= struck && struck >= 1 { return strike }
        if front >= struck { return fmRound(CGFloat(strike) + CGFloat(127 - strike) * (front - struck) / (1 - struck)) }
        return fmRound(CGFloat(strike) * front / struck)
    }
}
