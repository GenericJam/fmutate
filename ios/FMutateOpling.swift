// FMutateOpling.swift: port of android/.../fmutate/Opling.kt.
//
// The Opling (docs/design/creature.md): a small creature made of FM operators, here as the menu button of every
// layout (HANDOFF §4). Plain primitives only (HANDOFF §11): rounded rects, circles and one stroked curl; no
// gradients, no rotation; animation only moves and scales.
//
// Moods FMutate can see (creature.md "Moods"): idle (blinks every 3–6 s, pupils follow tilt), playing (bobs on
// each note, ticks either side), booting (eggshell), crashed (pupils crossed, three amber dots circling),
// safe mode (asleep, "zZ"), too slow (out of breath: pupils down, mouth open, a sweat drop, two puffs; still, so an
// overloaded phone draws no extra frames). The pose only changes when something moves, so a still Opling costs no
// frames.
//
// iOS: the surface's menu layer is this view. Compose's frame loop (withFrameMillis while moving, else a wait
// woken by new inputs) is a CADisplayLink that runs only while something moves and a one-shot main-queue wait
// until the next blink otherwise; the view redraws only when the pose changed. Tilt is CoreMotion's gravity (the
// accelerometer where there's no device motion), read only while the view is on screen.

import UIKit
import CoreMotion

/// Ops per column (carrier at the bottom), the head column, and "twins": one eye on each of the first two columns.
struct FMOplingForm {
    let cols: [Int]
    let head: Int
    let split: Bool
    let maxOps: Int

    /// Unit size (s = 1), padding for the antenna included.
    let width: CGFloat
    let height: CGFloat

    init(_ cols: [Int], head: Int, split: Bool = false) {
        self.cols = cols
        self.head = head
        self.split = split
        maxOps = cols.max() ?? 1
        width = CGFloat(cols.count) * OP_W + CGFloat(cols.count - 1) * OP_COL_GAP
        height = OP_PAD_TOP + CGFloat(maxOps) * (OP_H + OP_GAP) + OP_FOOT_H
    }

    func colX(_ ci: Int) -> CGFloat { CGFloat(ci) * (OP_W + OP_COL_GAP) }
    func colTop(_ ci: Int) -> CGFloat { OP_PAD_TOP + CGFloat(maxOps - cols[ci]) * (OP_H + OP_GAP) }

    /// The firmwares don't report their algorithm yet, so the menu button is always the twins.
    static let twins = FMOplingForm([2, 2], head: 0, split: true)
}

enum FMOplingMood: Int { case idle, play, hatch, dizzy, sleep, breath }

// anatomy, s = 1 (creature.md)
private let OP_W: CGFloat = 22
private let OP_H: CGFloat = 14
private let OP_R: CGFloat = 4
private let OP_GAP: CGFloat = 2.5
private let OP_COL_GAP: CGFloat = 3
private let OP_PAD_TOP: CGFloat = 11
private let OP_FOOT_W: CGFloat = 6
private let OP_FOOT_H: CGFloat = 3.2
private let OP_FOOT_R: CGFloat = 1.6
private let OP_EYE_D: CGFloat = 8
private let OP_PUPIL_D: CGFloat = 3.8
private let OP_EYE_ROOM = (OP_EYE_D - OP_PUPIL_D) / 2

// lime tint
private let OP_BODY = fmColor(0xFFC6F24E)
private let OP_CARRIER = fmColor(0xFF93CF32)
private let OP_FEET = fmColor(0xFF5E8F1A)
private let OP_ANTENNA = fmColor(0xFFA98BFF)
private let OP_EYE = fmColor(0xFFFFFFFF)
private let OP_PUPIL = fmColor(0xFF17141F)
private let OP_TICK = fmColor(0xFFA9A3B8)
private let OP_TICK_60 = fmColor(0xFFA9A3B8, alpha: 0.6)
private let OP_TICK_40 = fmColor(0xFFA9A3B8, alpha: 0.4)
private let OP_WARM = fmColor(0xFFFFB547)
private let OP_SHELL = fmColor(0xFFF3EBD6)
private let OP_SHELL_EDGE = fmColor(0xFFCDBF9C)
private let OP_SWEAT = fmColor(0xFF8FD8FF)

// the menu button (Flat-Instrument board): a 48 pt raised circle, the Opling at 0.62
private let OP_BUTTON = fmColor(0xFF221F2B)
private let OP_BUTTON_PRESSED = fmColor(0xFF34304A)
private let OP_BUTTON_PT: CGFloat = 48
private let OP_BUTTON_SCALE: CGFloat = 0.62

// animation (creature.md "Animation")
private let OP_BLINK_MS: Int64 = 90
private let OP_BOB_MS: Int64 = 360
private let OP_BOB_STAGGER_MS: Int64 = 30
private let OP_PUPIL_TAU_MS: CGFloat = 40        // ~120 ms settle
private let OP_ORBIT_MS: Int64 = 900
private let OP_DIZZY_MS: Int64 = 2500            // a crash restarts at once: stay dizzy a moment so it shows
private let OP_PLAY_LINGER_MS: Int64 = 1200      // still "playing" this long after the last note lifts
private let OP_TILT_FULL: CGFloat = 0.35         // g change (high-passed) that looks all the way

/// The antenna curl in its 9 × 11 box (Creature board).
private let OP_CURL: CGPath = {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 2, y: 11))
    p.addCurve(to: CGPoint(x: 5.5, y: 2), control1: CGPoint(x: 2, y: 6), control2: CGPoint(x: 2, y: 2))
    p.addCurve(to: CGPoint(x: 5.8, y: 5.6), control1: CGPoint(x: 8, y: 2), control2: CGPoint(x: 8.2, y: 5.5))
    p.addCurve(to: CGPoint(x: 5.4, y: 3.9), control1: CGPoint(x: 4.3, y: 5.7), control2: CGPoint(x: 4.3, y: 3.9))
    return p
}()

/// CADisplayLink retains its target: this breaks the cycle.
private final class FMOplingTick: NSObject {
    weak var owner: FMOplingView?
    init(_ owner: FMOplingView) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) { owner?.tick() }
}

/// The menu button: the Opling in a 48 pt circle, centred in the view (the menu control's cell). Pressed moves
/// 2 pt (HANDOFF §11). Kotlin's OplingMenuButton + OplingAnim + TiltEffect + OplingPainter in one view: it is the
/// surface's menu layer and draws nothing else.
final class FMOplingView: UIView {
    /// Whether the menu control is held (read on each draw; the surface marks this view on press changes).
    var pressed: () -> Bool = { false }

    private let form = FMOplingForm.twins
    private let ink = FMInk()

    // inputs
    private var phase = ""
    private var quarantined = false
    private var slow = false
    private var restarts: Int?          // nil until the first props (Kotlin: remember { OplingAnim(restarts) })
    private var held = 0
    private var beatAt = Int64.min / 2
    private var lastNoteAt = Int64.min / 2
    private var dizzyUntil: Int64 = 0
    private var tiltX: CGFloat = 0
    private var tiltY: CGFloat = 0

    // pose
    private var mood = FMOplingMood.idle
    private var blink: CGFloat = 1
    private var lookX: CGFloat = 0
    private var lookY: CGFloat = 0
    private var drop = [CGFloat](repeating: 0, count: 6)
    private var orbit: CGFloat = 0
    private var blinkAt: Int64 = 0
    private var last: Int64 = 0
    private var signature: Int64 = 0

    // clock: animating on the display link, or waiting (a generation cancels the pending wait)
    private var active = false
    private var link: CADisplayLink?
    private var waitGen = 0

    // tilt
    private var motion: CMMotionManager?
    private var baseX = CGFloat.nan
    private var baseY: CGFloat = 0
    private var lastT: Int64 = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        clearsContextBeforeDrawing = true
        // the app stays running in the background while audio plays: the clock and the tilt stop there
        inBackground = UIApplication.shared.applicationState == .background
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(enteredBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(enteringForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Kotlin's composable lives while the menu shows: here the clock and the tilt run while the view is on screen
    override var isHidden: Bool { didSet { updateActive() } }
    private var inBackground = false

    @objc private func enteredBackground() { inBackground = true; updateActive() }
    @objc private func enteringForeground() { inBackground = false; updateActive() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateActive()
    }

    // MARK: inputs

    func inputs(_ phase: String, _ quarantined: Bool, _ restarts: Int, _ slow: Bool) {
        let now = fmNowMs()
        if let r = self.restarts, restarts > r { dizzyUntil = now + OP_DIZZY_MS }
        self.restarts = restarts
        self.phase = phase
        self.quarantined = quarantined
        self.slow = slow
        wake()
    }

    /// The notes held on the surface: a new one is a beat.
    func notes(_ n: Int) {
        let now = fmNowMs()
        if n > held { beatAt = now }
        if n == 0 && held > 0 { lastNoteAt = now }
        held = n
        wake()
    }

    // MARK: clock

    private func updateActive() {
        let on = window != nil && !isHidden && !inBackground
        if on == active { return }
        active = on
        if on {
            startTilt()
            tick()
        } else {
            link?.invalidate()
            link = nil
            waitGen += 1
            stopTilt()
        }
    }

    /// Something changed: step now, unless the display link steps on the next frame anyway.
    private func wake() {
        if link == nil { tick() }
    }

    fileprivate func tick() {
        guard active else { return }
        let wait = step(fmNowMs())
        waitGen += 1
        if wait <= 0 {
            if link == nil {
                let l = CADisplayLink(target: FMOplingTick(self), selector: #selector(FMOplingTick.tick(_:)))
                l.add(to: .main, forMode: .common)
                link = l
            }
            return
        }
        link?.invalidate()
        link = nil
        guard wait < Int64.max else { return }
        let gen = waitGen
        fmAfter(wait) { [weak self] in
            guard let self, self.waitGen == gen else { return }
            self.tick()
        }
    }

    /// Advances the pose to `now`; returns how long nothing will move (0: animate the next frame).
    private func step(_ now: Int64) -> Int64 {
        let dt = CGFloat(min(max(now - last, 0), 50))
        last = now
        if phase == "safe_mode" || quarantined { mood = .sleep }
        else if phase == "crashed" || now < dizzyUntil { mood = .dizzy }
        else if phase == "booting" { mood = .hatch }
        else if slow { mood = .breath }
        else if held > 0 || now - lastNoteAt < OP_PLAY_LINGER_MS { mood = .play }
        else { mood = .idle }
        var wait = Int64.max
        if mood == .dizzy { wait = min(wait, dizzyUntil - now) }
        if mood == .play && held == 0 { wait = min(wait, lastNoteAt + OP_PLAY_LINGER_MS - now) }

        // blink: eye height 100 % → 20 % → 100 % over 90 ms, every 3–6 s
        blink = 1
        if mood == .idle || mood == .play || mood == .hatch || mood == .breath {
            if blinkAt == 0 { blinkAt = now + nextBlink() }
            let u = now - blinkAt
            if u < 0 {
                wait = min(wait, -u)
            } else if u < OP_BLINK_MS {
                blink = 1 - 0.8 * (1 - abs(2 * CGFloat(u) / CGFloat(OP_BLINK_MS) - 1))
                wait = 0
            } else {
                blinkAt = now + nextBlink()
                wait = min(wait, blinkAt - now)
            }
        } else {
            blinkAt = 0
        }

        // pupils: sprung towards the tilt (looking up from the eggshell)
        let follow = mood == .idle || mood == .play
        let tx = follow ? tiltX : 0
        let ty = follow ? tiltY : mood == .hatch ? -1 : mood == .breath ? 1 : 0
        let k = 1 - exp(-dt / OP_PUPIL_TAU_MS)
        lookX += (tx - lookX) * k
        lookY += (ty - lookY) * k
        if abs(tx - lookX) > 0.02 || abs(ty - lookY) > 0.02 { wait = 0 } else { lookX = tx; lookY = ty }

        // bob: on each note every column drops 4 % of the body height and springs back, 30 ms apart
        let bobbing = mood == .play && now - beatAt < OP_BOB_MS + OP_BOB_STAGGER_MS * Int64(form.cols.count)
        for ci in form.cols.indices {
            let u = now - beatAt - OP_BOB_STAGGER_MS * Int64(ci)
            if bobbing && u >= 0 && u < OP_BOB_MS {
                let uf = CGFloat(u)
                drop[ci] = 0.04 * form.height * exp(-uf / 90) * cos(2 * .pi * uf / 300)
            } else {
                drop[ci] = 0
            }
        }
        if bobbing { wait = 0 }

        if mood == .dizzy {
            wait = 0
            orbit = CGFloat(now % OP_ORBIT_MS) / CGFloat(OP_ORBIT_MS)
        } else {
            orbit = 0
        }

        // redraw only when what's drawn changed
        var sig = Int64(mood.rawValue)
        func mix(_ v: CGFloat) { sig = sig &* 31 &+ Int64(v.rounded()) }
        mix(blink * 20)
        mix(lookX * 16)
        mix(lookY * 16)
        for ci in form.cols.indices { mix(drop[ci] * 10) }
        mix(orbit * 64)
        if sig != signature {
            signature = sig
            setNeedsDisplay()
        }
        return wait
    }

    private func nextBlink() -> Int64 { 3000 + Int64.random(in: 0..<3000) }

    // MARK: tilt

    /// Pupils follow tilt: gravity, high-passed (changes in tilt, not how the phone is held), in screen axes.
    private func startTilt() {
        let m = motion ?? CMMotionManager()
        motion = m
        baseX = .nan
        // ~SENSOR_DELAY_UI
        if m.isDeviceMotionAvailable {
            m.deviceMotionUpdateInterval = 1.0 / 16
            m.startDeviceMotionUpdates(to: .main) { [weak self] dm, _ in
                guard let self, let dm else { return }
                self.gravity(dm.gravity.x, dm.gravity.y, dm.timestamp)
            }
        } else if m.isAccelerometerAvailable {
            m.accelerometerUpdateInterval = 1.0 / 16
            m.startAccelerometerUpdates(to: .main) { [weak self] a, _ in
                guard let self, let a else { return }
                self.gravity(a.acceleration.x, a.acceleration.y, a.timestamp)
            }
        }
    }

    private func stopTilt() {
        motion?.stopDeviceMotionUpdates()
        motion?.stopAccelerometerUpdates()
    }

    private func gravity(_ x: Double, _ y: Double, _ timestamp: TimeInterval) {
        // CoreMotion's gravity points down, in g, device axes x right and y up → "downhill" in screen axes
        // (x right, y down), turned with the interface
        let nx = CGFloat(x), ny = CGFloat(-y)
        let gx: CGFloat, gy: CGFloat
        switch window?.windowScene?.interfaceOrientation {
        case .landscapeLeft?: (gx, gy) = (-ny, nx)          // home side left: the device's top is on the right
        case .landscapeRight?: (gx, gy) = (ny, -nx)
        case .portraitUpsideDown?: (gx, gy) = (-nx, -ny)
        default: (gx, gy) = (nx, ny)
        }
        let t = Int64(timestamp * 1000)
        if baseX.isNaN { baseX = gx; baseY = gy; lastT = t }
        let k = 1 - exp(-CGFloat(min(max(t - lastT, 0), 200)) / 1500)
        lastT = t
        baseX += (gx - baseX) * k
        baseY += (gy - baseY) * k
        var lx = (gx - baseX) / OP_TILT_FULL
        var ly = (gy - baseY) / OP_TILT_FULL
        let len = hypot(lx, ly)
        if len > 1 { lx /= len; ly /= len }
        if abs(lx - tiltX) > 0.06 || abs(ly - tiltY) > 0.06 {
            tiltX = lx
            tiltY = ly
            wake()
        }
    }

    // MARK: drawing

    override func draw(_ rect: CGRect) {
        guard let g = UIGraphicsGetCurrentContext() else { return }
        let w = bounds.width, h = bounds.height
        let down = pressed()
        let side = min(OP_BUTTON_PT, min(w, h))
        let cx = w / 2
        let cy = h / 2 + (down ? 2 : 0)
        fmFillCircle(g, cx, cy, side / 2, down ? OP_BUTTON_PRESSED : OP_BUTTON)
        let s = side / OP_BUTTON_PT * OP_BUTTON_SCALE
        paint(g, cx - form.width * s / 2, cy - form.height * s / 2, s)
    }

    /// Draws the Opling with its top-left (antenna padding included) at (left, top), `s` points per unit.
    private func paint(_ g: CGContext, _ left: CGFloat, _ top: CGFloat, _ s: CGFloat) {
        func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ c: CGColor) {
            fmFillRoundRect(g, left + x * s, top + y * s, w * s, h * s, r * s, c)
        }
        func dot(_ x: CGFloat, _ y: CGFloat, _ dia: CGFloat, _ c: CGColor) {
            fmFillCircle(g, left + x * s, top + y * s, dia / 2 * s, c)
        }

        let headTop = form.colTop(form.head) + drop[form.head]
        let headX = form.colX(form.head)

        for ci in form.cols.indices {
            let cnt = form.cols[ci]
            let x = form.colX(ci)
            let y0 = form.colTop(ci) + drop[ci]
            for i in 0..<cnt {
                rr(x, y0 + CGFloat(i) * (OP_H + OP_GAP), OP_W, OP_H, OP_R, i == cnt - 1 ? OP_CARRIER : OP_BODY)
            }
            let fy = y0 + CGFloat(cnt) * (OP_H + OP_GAP)
            rr(x + 3, fy, OP_FOOT_W, OP_FOOT_H, OP_FOOT_R, OP_FEET)
            rr(x + OP_W - 3 - OP_FOOT_W, fy, OP_FOOT_W, OP_FOOT_H, OP_FOOT_R, OP_FEET)
            // eyes on the head op, or one on each of the first two columns (twins)
            if form.split && ci < 2 {
                eye(g, left, top, s, x + (ci == 0 ? OP_W * 0.3 : OP_W * 0.7), y0, ci == 0)
            } else if !form.split && ci == form.head {
                eye(g, left, top, s, x + OP_W * 0.3, y0, true)
                eye(g, left, top, s, x + OP_W * 0.7, y0, false)
            }
        }
        // antenna: the feedback loop, on the head op
        g.saveGState()
        g.translateBy(x: left + (headX + OP_W * 0.56) * s, y: top + (headTop - 10.5) * s)
        g.scaleBy(x: s, y: s)
        g.addPath(OP_CURL)
        g.setStrokeColor(OP_ANTENNA)
        g.setLineWidth(1.7)
        g.setLineCap(.round)
        g.setLineJoin(.round)
        g.strokePath()
        g.restoreGState()

        let w = form.width
        let h = form.height
        switch mood {
        case .play:
            rr(-5, h * 0.32, 1.6, 6, 0.8, OP_TICK)
            rr(-8.5, h * 0.38, 1.6, 4, 0.8, OP_TICK)
            rr(w + 3.4, h * 0.32, 1.6, 6, 0.8, OP_TICK)
            rr(w + 6.9, h * 0.38, 1.6, 4, 0.8, OP_TICK)
        case .dizzy:
            // three amber dots circling above the head (they move; nothing rotates)
            for i in 0..<3 {
                let t = 2 * .pi * (orbit + CGFloat(i) / 3) - .pi / 2
                dot(headX + OP_W * 0.5 + OP_W * 0.35 * cos(t), headTop - 5.5 + 2.5 * sin(t), 2.6, OP_WARM)
            }
        case .sleep:
            let zx = left + (headX + OP_W + 1) * s
            let base = top + (headTop - 11 + 9 * 0.85) * s
            ink.drawAtBaseline(g, "z", zx, base, 6 * s, OP_TICK, mono: true, weight: 700)
            ink.drawAtBaseline(g, "Z", zx + ink.width("z", 6 * s, mono: true, weight: 700), base, 9 * s, OP_TICK,
                               mono: true, weight: 700)
        case .hatch:
            // zig-zag eggshell over the lower 58 % of the body (100 × 60 box, stretched)
            let bx = left - 3 * s
            let by = top + h * 0.42 * s
            let sx = (w + 6) * s / 100
            let sy = (h * 0.58 + 1) * s / 60
            let shell = CGMutablePath()
            shell.move(to: CGPoint(x: bx, y: by + 14 * sy))
            for i in 1...10 {
                shell.addLine(to: CGPoint(x: bx + CGFloat(10 * i) * sx, y: by + (i % 2 == 1 ? 3 : 14) * sy))
            }
            shell.addLine(to: CGPoint(x: bx + 100 * sx, y: by + 42 * sy))
            shell.addQuadCurve(to: CGPoint(x: bx + 82 * sx, y: by + 60 * sy), control: CGPoint(x: bx + 100 * sx, y: by + 60 * sy))
            shell.addLine(to: CGPoint(x: bx + 18 * sx, y: by + 60 * sy))
            shell.addQuadCurve(to: CGPoint(x: bx, y: by + 42 * sy), control: CGPoint(x: bx, y: by + 60 * sy))
            shell.closeSubpath()
            g.addPath(shell)
            g.setFillColor(OP_SHELL)
            g.fillPath()
            g.addPath(shell)
            g.setStrokeColor(OP_SHELL_EDGE)
            g.setLineWidth(1.5)
            g.strokePath()
        case .breath:
            // out of breath (Creature board "breath"): mouth open on the head op, a sweat drop beside it, two puffs
            rr(headX + OP_W / 2 - 2.25, headTop + OP_H - 3 - 1.6, 4.5, 3, 1.5, OP_PUPIL)
            rr(headX + OP_W + 1.5, headTop + 0.5, 3, 4.4, 1.5, OP_SWEAT)
            dot(headX - 4, headTop + 9, 2.4, OP_TICK_60)
            dot(headX - 7.5, headTop + 7, 1.8, OP_TICK_40)
        case .idle:
            break
        }
    }

    /// One eye centred at (cx, opTop + 2): white, pokes 2 above the op; pupil sprung inside it.
    private func eye(_ g: CGContext, _ left: CGFloat, _ top: CGFloat, _ s: CGFloat, _ cx: CGFloat, _ opTop: CGFloat,
                     _ isLeft: Bool) {
        let ex = left + (cx - OP_EYE_D / 2) * s
        if mood == .sleep {
            // closed: a thin dark bar
            fmFillRoundRect(g, ex, top + (opTop + 2) * s, OP_EYE_D * s, 1.6 * s, 1 * s, OP_PUPIL)
            return
        }
        let eh = OP_EYE_D * blink
        let ecy = opTop + 2
        // Kotlin's round rect with half-width × half-height corners: an ellipse
        g.setFillColor(OP_EYE)
        g.fillEllipse(in: CGRect(x: ex, y: top + (ecy - eh / 2) * s, width: OP_EYE_D * s, height: eh * s))
        // crashed: pupils crossed inward
        let dizzy = mood == .dizzy
        let lx: CGFloat = dizzy ? (isLeft ? 1 : -1) : lookX
        let ly: CGFloat = dizzy ? 0.4 : lookY
        let px = cx + lx * OP_EYE_ROOM * 0.85
        let py = ecy + ly * OP_EYE_ROOM * 0.85 * blink
        let ph = OP_PUPIL_D * blink
        g.setFillColor(OP_PUPIL)
        g.fillEllipse(in: CGRect(x: left + (px - OP_PUPIL_D / 2) * s, y: top + (py - ph / 2) * s,
                                 width: OP_PUPIL_D * s, height: ph * s))
    }
}
