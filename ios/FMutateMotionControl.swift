import CoreMotion
import UIKit

// Motion controls ("type": "motion", FMutate.Motion): a port of MotionControl.kt. A tile the player holds (or
// latches on) while moving the phone; its gestures drive bindings like an XY pad's axes and a button's press:
//
//   x      tilt X (roll; the right edge going down moves the value up)       a value
//   y      tilt Y (pitch; the top edge coming up moves the value up)         a value
//   twist  turning the phone about the screen's normal (gyroscope; clockwise) a value
//   shake  a jolt of the phone (accelerometer)                                a press
//   near   something over the proximity sensor                                a press
//
// Sensors are read on the main queue, never through the BEAM, and only while a motion control is engaged.
// iOS: CMMotionManager's raw accelerometer and gyro at Android's SENSOR_DELAY_GAME (20 ms), so the maths below
// (gravity low-pass, shake jolt) runs on the same readings as Android's. Core Motion reports acceleration in g
// with the opposite sign (the pull of gravity, not the reaction Android reads), on the same device axes: readings
// are turned into Android's m/s² first. The proximity sensor is UIDevice's, which also blanks the screen while
// something is near (iOS gives no other way to read it).

/// The pure maths (MotionMath in Kotlin, unit-tested there in MotionMathTest; keep identical). Angles in degrees,
/// acceleration in m/s². Pitch bend's bytes are fmBendRaw.
enum FMMotionMath {
    static let G: Float = 9.80665
    /// Tilt around the engage orientation that moves nothing: a hand's tremor.
    static let DEAD_DEG: Float = 2
    /// Gravity low-pass (per reading at ~50 Hz): smooths the hand's jitter, follows a tilt within ~0.1 s.
    static let LOW_PASS: Float = 0.3
    /// No second shake within this long of the first: one jolt rings for a few readings.
    static let SHAKE_REFRACTORY_MS: Int64 = 250
    /// How long a shake holds a momentary press.
    static let SHAKE_PRESS_MS: Int64 = 120
    /// A value target moves by at least this much per send (a MIDI CC's step).
    static let STEP: Float = 1 / 128
    /// Gravity is trusted for tilt only while the phone accelerates less than this (g): a shake doesn't tilt.
    static let STEADY_G: Float = 0.35

    /// Shake thresholds: acceleration beyond gravity, in g.
    static func shakeThreshold(_ name: String) -> Float {
        switch name {
        case "gentle": return 0.6
        case "hard": return 2.0
        default: return 1.2
        }
    }

    /// Device axes to screen axes for a display rotation (Android's Surface.ROTATION_*, fmDisplayRotation): x to
    /// the screen's right, y to its top, whatever way the phone is turned.
    static func toScreen(_ rotation: Int, _ x: Float, _ y: Float) -> (Float, Float) {
        switch rotation {
        case 1: return (-y, x)
        case 2: return (-x, -y)
        case 3: return (y, -x)
        default: return (x, y)
        }
    }

    private static let DEG = Float(180.0 / Double.pi)

    /// Roll from gravity in screen axes: positive when the right edge goes down.
    static func roll(_ sx: Float, _ sy: Float, _ sz: Float) -> Float { atan2(-sx, (sy * sy + sz * sz).squareRoot()) * DEG }

    /// Pitch from gravity in screen axes: positive when the top edge comes up (towards the player).
    static func pitch(_ sy: Float, _ sz: Float) -> Float { atan2(sy, sz) * DEG }

    /// a − b on a circle, in −180..180 (a pitch passing through upright doesn't jump a whole turn).
    static func angleDiff(_ a: Float, _ b: Float) -> Float {
        var d = (a - b).truncatingRemainder(dividingBy: 360)   // Kotlin's %
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    /// The movement past the dead zone: 0 inside ±dead, then from 0 on.
    static func deadZone(_ d: Float, _ dead: Float = DEAD_DEG) -> Float {
        abs(d) <= dead ? 0 : d - dead * (d > 0 ? 1 : d < 0 ? -1 : 0)
    }

    /// A value target's value: start at engage, its whole span over rangeDeg of movement.
    static func value(_ start: Float, _ deltaDeg: Float, _ rangeDeg: Float) -> Float {
        fmClamp(start + deadZone(deltaDeg) / rangeDeg, 0, 1)
    }

    /// Clicks an encoder should have had since engage: rangeDeg of movement is a potDp knob drag (the pot's full
    /// range), at ptPerClick dp per click.
    static func clicks(_ deltaDeg: Float, _ rangeDeg: Float, _ ptPerClick: Float, invert: Bool, potDp: Float = 200) -> Int {
        let n = fmKotlinToInt(deadZone(deltaDeg) / rangeDeg * potDp / ptPerClick)
        return invert ? -n : n
    }

    /// Whether a value moved enough to send: a whole STEP, or onto either end.
    static func worthSending(_ v: Float, _ last: Float) -> Bool {
        last.isNaN || abs(v - last) >= STEP || (v != last && (v == 0 || v == 1))
    }

    /// Acceleration beyond gravity, in g.
    static func jolt(_ x: Float, _ y: Float, _ z: Float) -> Float { abs((x * x + y * y + z * z).squareRoot() / G - 1) }
}

/// Kotlin's Float.toInt(): toward zero, NaN to 0, saturating at Int's (32-bit) ends instead of trapping.
private func fmKotlinToInt(_ x: Float) -> Int {
    if x.isNaN { return 0 }
    return Int(fmClamp(x, Float(Int32.min), Float(Int32.max)))
}

/// Turns jolts into shakes: above the threshold, at most one per refractory period.
final class FMShakeDetector {
    var threshold: Float
    private var last = Int64.min / 2

    init(_ threshold: Float) { self.threshold = threshold }

    func update(_ jolt: Float, _ nowMs: Int64) -> Bool {
        if jolt < threshold || nowMs - last < FMMotionMath.SHAKE_REFRACTORY_MS { return false }
        last = nowMs
        return true
    }
}

/// What a motion control does to the surface's targets (FMInstrumentSurface supplies these).
protocol FMMotionSink: AnyObject {
    /// Set an absolute target (pot, MIDI CC, pitch bend) to v; false when rule 7 refused it.
    func motionValue(_ c: FMControl, _ t: FMTarget, _ v: Float) -> Bool
    /// Send n encoder clicks to encoder `id`.
    func motionClicks(_ c: FMControl, _ id: String, _ n: Int)
    /// A press binding goes down or up.
    func fire(_ t: FMTarget, _ down: Bool)
    /// The current value of an absolute target, 0.5 if nobody set it.
    func motionCurrent(_ key: String) -> Float
    /// A motion control let go: values it held back from the surface's state can be shown now.
    func motionSettle()
}

/// One engaged motion control: its bindings in arrays, the orientation at engage, what it sent.
final class FMMotionEngagement {
    let c: FMControl
    let rotation: Int
    let on: FMMotionPresses                                  // presses: down now / toggled on
    let range: Float
    let gestures: [String]
    let targets: [FMTarget]
    let toggle: [Bool]
    let keys: [String?]
    var start: [Float]                                       // absolute targets: their value at engage
    var sent: [Float]                                        // and what it last sent (start: nothing moved yet)
    var clicks: [Int]                                        // encoders: clicks sent since engage
    let needsAccel: Bool
    let needsGyro: Bool
    let needsProx: Bool

    var gravity: (Float, Float, Float) = (0, 0, 0)
    var haveGravity = false
    var roll0: Float = 0
    var pitch0: Float = 0
    var roll: Float = 0
    var pitch: Float = 0
    var twist: Float = 0
    var gyroNs: Int64 = 0
    let shake: FMShakeDetector
    var shakeUpAt: Int64 = 0                                 // when a momentary shake press lets go
    var near = false

    init(_ c: FMControl, _ rotation: Int, _ on: FMMotionPresses) {
        self.c = c
        self.rotation = rotation
        self.on = on
        range = Float(c.motionRange)
        gestures = c.bindings.map(\.on)
        targets = c.bindings.map(\.to)
        toggle = c.bindings.map { $0.mode == "toggle" }
        keys = c.bindings.map(\.to.absoluteKey)
        start = Array(repeating: 0, count: c.bindings.count)
        sent = Array(repeating: 0, count: c.bindings.count)
        clicks = Array(repeating: 0, count: c.bindings.count)
        needsAccel = gestures.contains { $0 == "x" || $0 == "y" || $0 == "shake" }
        needsGyro = gestures.contains("twist")
        needsProx = gestures.contains("near")
        shake = FMShakeDetector(FMMotionMath.shakeThreshold(c.motionShake))
    }
}

/// A control's press bindings that are down or toggled on, kept across engagements (Kotlin's shared BooleanArray).
final class FMMotionPresses {
    let c: FMControl
    var on: [Bool]
    init(_ c: FMControl) { self.c = c; on = Array(repeating: false, count: c.bindings.count) }
}

/// The surface's motion controls: engages and disengages them, runs the sensors the engaged ones need and
/// nothing while none is, and turns readings into the sink's sends.
final class FMMotionControls {
    private weak var sink: FMMotionSink?
    /// A tile's dot moved: the surface redraws its motion layer (Kotlin bumps a Compose `frame`).
    var onFrame: (() -> Void)?

    // made on first use: the simulator has no accelerometer or gyro (isAccelerometerAvailable false)
    private lazy var manager: CMMotionManager = {
        let m = CMMotionManager()
        m.accelerometerUpdateInterval = 0.02                   // SENSOR_DELAY_GAME
        m.gyroUpdateInterval = 0.02
        return m
    }()
    private var engaged: [FMMotionEngagement] = []
    private var presses: [String: FMMotionPresses] = [:]
    private var registered = 0                                 // bit 0 accel, 1 gyro, 2 proximity
    private var proxObserver: NSObjectProtocol?

    init(sink: FMMotionSink) { self.sink = sink }

    var hasAccel: Bool { manager.isAccelerometerAvailable }

    private func find(_ id: String) -> FMMotionEngagement? { engaged.first { $0.c.id == id } }

    func isEngaged(_ id: String) -> Bool { find(id) != nil }

    var engagedIds: [String] { engaged.map(\.c.id) }

    /// The dot of an engaged tile: tilt X and Y in −1..1 of its range (0, 0 when not engaged).
    func dotX(_ id: String) -> Float {
        guard let e = find(id) else { return 0 }
        return fmClamp(FMMotionMath.angleDiff(e.roll, e.roll0) / e.range, -1, 1)
    }

    func dotY(_ id: String) -> Float {
        guard let e = find(id) else { return 0 }
        return fmClamp(FMMotionMath.angleDiff(e.pitch, e.pitch0) / e.range, -1, 1)
    }

    func engage(_ c: FMControl, _ rotation: Int) {
        if find(c.id) != nil { return }
        let on: FMMotionPresses
        if let p = presses[c.id], p.c == c { on = p } else { on = FMMotionPresses(c); presses[c.id] = on }
        let e = FMMotionEngagement(c, rotation, on)
        if let s = sink {
            for i in e.keys.indices { if let k = e.keys[i] { e.start[i] = s.motionCurrent(k); e.sent[i] = e.start[i] } }
        }
        engaged.append(e)
        reregister()
    }

    /// Let go: momentary presses up, values stay or spring back (as the XY pad's on_release).
    func disengage(_ id: String) {
        guard let k = engaged.firstIndex(where: { $0.c.id == id }) else { return }
        let e = engaged.remove(at: k)
        if let s = sink {
            for i in e.targets.indices {
                let t = e.targets[i]
                let g = e.gestures[i]
                if g == "shake" || g == "near" {
                    if e.on.on[i] && !e.toggle[i] { e.on.on[i] = false; s.fire(t, false) }
                } else if e.c.motionSpringBack {
                    if case let .encoder(eid, _, _) = t { if e.clicks[i] != 0 { s.motionClicks(e.c, eid, -e.clicks[i]) } }
                    else if e.sent[i] != e.start[i] { _ = s.motionValue(e.c, t, e.start[i]) }
                }
            }
            s.motionSettle()
        }
        reregister()
        onFrame?()
    }

    private func reregister() {
        var want = 0
        for e in engaged {
            if e.needsAccel || e.needsGyro { want |= 1 }           // twist alone still shows the dot's tilt
            if e.needsGyro { want |= 2 }
            if e.needsProx { want |= 4 }
        }
        if want == registered { return }
        let m = manager
        if want & 1 == 0 { if m.isAccelerometerActive { m.stopAccelerometerUpdates() } }
        else if registered & 1 == 0 && m.isAccelerometerAvailable {
            m.startAccelerometerUpdates(to: .main) { [weak self] d, _ in
                guard let self, let d else { return }
                // Core Motion: g, gravity's pull; Android: m/s², the reaction to it
                let a = d.acceleration
                let G = Double(FMMotionMath.G)
                self.reading(.accel(Float(-a.x * G), Float(-a.y * G), Float(-a.z * G)), d.timestamp)
            }
        }
        if want & 2 == 0 { if m.isGyroActive { m.stopGyroUpdates() } }
        else if registered & 2 == 0 && m.isGyroAvailable {
            m.startGyroUpdates(to: .main) { [weak self] d, _ in
                guard let self, let d else { return }
                // same axes and sense as Android's TYPE_GYROSCOPE (rad/s, counter-clockwise positive)
                self.reading(.gyro(Float(d.rotationRate.z)), d.timestamp)
            }
        }
        if want & 4 == 0 { stopProximity() } else if registered & 4 == 0 { startProximity() }
        registered = want
    }

    private func startProximity() {
        let dev = UIDevice.current
        dev.isProximityMonitoringEnabled = true
        if !dev.isProximityMonitoringEnabled { return }          // no sensor (iPad, simulator)
        proxObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.proximityStateDidChangeNotification, object: dev, queue: .main
        ) { [weak self] _ in self?.reading(.near(UIDevice.current.proximityState), 0) }
    }

    private func stopProximity() {
        if let o = proxObserver { NotificationCenter.default.removeObserver(o) }
        proxObserver = nil
        UIDevice.current.isProximityMonitoringEnabled = false
    }

    private enum Reading { case accel(Float, Float, Float), gyro(Float), near(Bool) }

    /// onSensorChanged: `timestamp` is Core Motion's (seconds since boot, Android's is ns).
    private func reading(_ r: Reading, _ timestamp: TimeInterval) {
        if engaged.isEmpty { return }
        guard let s = sink else { return }
        let nowMs = Int64(timestamp * 1000)
        var moved = false
        for e in engaged {
            switch r {
            case let .accel(x, y, z): moved = accelerometer(e, s, x, y, z, nowMs) || moved
            case let .gyro(wz): gyroscope(e, s, wz, Int64(timestamp * 1e9))
            case let .near(n): proximity(e, s, n)
            }
        }
        if moved { onFrame?() }
    }

    private func accelerometer(_ e: FMMotionEngagement, _ s: FMMotionSink, _ x: Float, _ y: Float, _ z: Float, _ nowMs: Int64) -> Bool {
        // shake: the raw jolt, before smoothing
        let jolt = FMMotionMath.jolt(x, y, z)
        if e.needsAccel {
            let shook = e.shake.update(jolt, nowMs)
            for i in e.gestures.indices where e.gestures[i] == "shake" {
                if shook {
                    if e.toggle[i] { e.on.on[i].toggle(); s.fire(e.targets[i], e.on.on[i]) }
                    else if !e.on.on[i] { e.on.on[i] = true; s.fire(e.targets[i], true); e.shakeUpAt = nowMs + FMMotionMath.SHAKE_PRESS_MS }
                } else if e.on.on[i] && !e.toggle[i] && nowMs >= e.shakeUpAt { e.on.on[i] = false; s.fire(e.targets[i], false) }
            }
        }
        if e.haveGravity && jolt > FMMotionMath.STEADY_G { return false }
        if !e.haveGravity {
            e.gravity = (x, y, z)
        } else {
            let L = FMMotionMath.LOW_PASS
            e.gravity.0 += L * (x - e.gravity.0); e.gravity.1 += L * (y - e.gravity.1); e.gravity.2 += L * (z - e.gravity.2)
        }
        let (sx, sy) = FMMotionMath.toScreen(e.rotation, e.gravity.0, e.gravity.1)
        let oldRoll = e.roll
        let oldPitch = e.pitch
        e.roll = FMMotionMath.roll(sx, sy, e.gravity.2)
        e.pitch = FMMotionMath.pitch(sy, e.gravity.2)
        if !e.haveGravity {
            e.haveGravity = true
            e.roll0 = e.roll
            e.pitch0 = e.pitch
            return true
        }
        axes(e, s, "x", FMMotionMath.angleDiff(e.roll, e.roll0))
        axes(e, s, "y", FMMotionMath.angleDiff(e.pitch, e.pitch0))
        return abs(e.roll - oldRoll) > 0.2 || abs(e.pitch - oldPitch) > 0.2
    }

    private func gyroscope(_ e: FMMotionEngagement, _ s: FMMotionSink, _ wz: Float, _ ns: Int64) {
        if e.gyroNs != 0 {
            let dt = Float(ns - e.gyroNs) / 1e9
            // z points out of the screen: a clockwise turn (seen from the front) is a negative rate
            if dt >= 0 && dt <= 0.5 { e.twist -= wz * dt * (180 / Float.pi) }
            axes(e, s, "twist", e.twist)
        }
        e.gyroNs = ns
    }

    private func proximity(_ e: FMMotionEngagement, _ s: FMMotionSink, _ near: Bool) {
        if near == e.near { return }
        e.near = near
        for i in e.gestures.indices where e.gestures[i] == "near" {
            if e.toggle[i] { if near { e.on.on[i].toggle(); s.fire(e.targets[i], e.on.on[i]) } }
            else { e.on.on[i] = near; s.fire(e.targets[i], near) }
        }
    }

    /// One axis moved delta degrees from engage: its value bindings follow.
    private func axes(_ e: FMMotionEngagement, _ s: FMMotionSink, _ gesture: String, _ delta: Float) {
        for i in e.gestures.indices where e.gestures[i] == gesture {
            let t = e.targets[i]
            if case let .encoder(id, pt, invert) = t {
                let want = FMMotionMath.clicks(delta, e.range, Float(pt), invert: invert)
                let n = want - e.clicks[i]
                if n != 0 { e.clicks[i] = want; s.motionClicks(e.c, id, n) }
            } else {
                if e.keys[i] == nil { continue }
                let v = FMMotionMath.value(e.start[i], delta, e.range)
                if FMMotionMath.worthSending(v, e.sent[i]) && s.motionValue(e.c, t, v) { e.sent[i] = v }
            }
        }
    }

    /// The surface is going: stop listening, let go of presses (toggled ones too).
    func close() {
        let s = sink
        for p in presses.values { for i in p.on.indices where p.on[i] { s?.fire(p.c.bindings[i].to, false) } }
        presses.removeAll()
        engaged.removeAll()
        if registered & 1 != 0 { manager.stopAccelerometerUpdates() }
        if registered & 2 != 0 { manager.stopGyroUpdates() }
        if registered & 4 != 0 { stopProximity() }
        registered = 0
        s?.motionSettle()
    }
}

/// Android's Surface.ROTATION_* for the interface orientation of the scene a view is on: ROTATION_90 is the
/// device's top on the screen's left, which is UIKit's landscapeRight (home side on the right).
func fmDisplayRotation(_ view: UIView) -> Int {
    switch view.window?.windowScene?.interfaceOrientation {
    case .landscapeRight: return 1
    case .portraitUpsideDown: return 2
    case .landscapeLeft: return 3
    default: return 0
    }
}

// MARK: drawing

extension FMDraw {
    /// A motion control's ring (its tilt dot is on the motion layer, motionDot): lime while engaged.
    func motion(_ c: FMControl, _ r: FMGrid.Rect, _ st: FMSurfaceState, _ sensor: Bool) {
        let active = st.pressed[c.id] == true
        fmFillRoundRect(g, r.x, r.y, r.w, r.h, 12, active ? FMC.fmTint : FMC.raised)
        let cx = r.cx
        let cy = fmMotionRingY(r)
        fmStrokeCircle(g, cx, cy, fmMotionRingRadius(r), active ? FMC.fm : FMC.lineSoft, 2)
        fmLine(g, cx - 4, cy, cx + 4, cy, FMC.lineSoft, 1)
        fmLine(g, cx, cy - 4, cx, cy + 4, FMC.lineSoft, 1)
        let label = !sensor ? "no sensor" : c.label
        text(label, r.cx, r.y + r.h - 9, 10, active ? FMC.fm : sensor ? FMC.muted : FMC.faint, mono: true)
        if c.motionLatch && r.h >= 80 { text("LATCH", r.x + 22, r.y + 10, 8, active ? FMC.fm : FMC.faint, mono: true) }
    }

    /// A motion control's tilt: a dot inside its ring, at the edge for a whole range of tilt.
    func motionDot(_ r: FMGrid.Rect, _ x: Float, _ y: Float, _ engaged: Bool) {
        let rad = fmMotionRingRadius(r)
        fmFillCircle(g, r.cx + CGFloat(x) * rad, fmMotionRingY(r) - CGFloat(y) * rad, 5, engaged ? FMC.fm : FMC.faint)
    }
}

// a motion control's ring inside its cells (dp), above the label
private func fmMotionRingY(_ r: FMGrid.Rect) -> CGFloat { r.y + (r.h - 18) / 2 + 2 }
private func fmMotionRingRadius(_ r: FMGrid.Rect) -> CGFloat { max(min(r.w, r.h - 18) / 2 - 8, 6) }
