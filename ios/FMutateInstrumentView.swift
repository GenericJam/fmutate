// FMutateInstrumentView.swift: port of android/.../fmutate/InstrumentView.kt.
//
// The instrument surface: every control of a layout, drawn and played natively (HANDOFF §5–§8). Touch never
// waits for the BEAM: press feedback is painted on touch-down, and what the firmware should see goes out as
// compact events:
//
//   send("in", {t: "key", k, d}) | {t: "button", id, d} | {t: "encoder", id, clicks} | {t: "pot", v}
//            | {t: "midi", bytes: [..]}
//   send("menu"), send("pages"), send("edit"), send("page", {id}), send("use_classic")
//
// The firmware's screen and LEDs come from the engine's shared memory (FMFirmwareShm), not from props.
//
// Drawing is split into layers so a frame redraws only what changed: the controls (a backing-store view,
// re-rendered on presses, values and LEDs, and only in the rect of the control that changed), the playing
// controls (keys, pads, strings), the firmware screen (CALayers whose contents are each new engine frame: the GPU
// scales them), the Opling menu button (its own animation) and an overlay (fingers, bubbles, banner).
//
// iOS: a UIView subclass inside a UIViewRepresentable (docs/decisions/2026-11-13-ios-port.md §4). Compose's
// snapshot state invalidates the layer that read it; here every state change goes through a helper that marks
// the layer (and rect) it shows on. UITouch identity is the pointer id.
//
// Props: layout (JSON string), fb (path or null), master (0..1), bend (firmware takes pitch bend), phase
// (instance phase), quarantined, restarts, slow and speed (too slow, and the firmware's speed in %), hint (what is
// being done or can be, under "Too slow"; alone: dropouts a larger buffer would cure): the Opling's mood and the
// message in the firmware screen area (Starting…, Restarting…, Crashed twice · Run anyway, Too slow, Audio dropouts).

import UIKit
import SwiftUI
import CoreText

// MARK: - colours, shapes, text

func fmColor(_ argb: UInt32, alpha: CGFloat? = nil) -> CGColor {
    CGColor(srgbRed: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255,
            blue: CGFloat(argb & 0xFF) / 255, alpha: alpha ?? CGFloat(argb >> 24) / 255)
}

/// Compose's Color.hsl (hue 0..360, saturation and lightness 0..1).
func fmHSL(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat) -> CGColor {
    func f(_ n: CGFloat) -> CGFloat {
        let k = (n + h / 30).truncatingRemainder(dividingBy: 12)
        let a = s * min(l, 1 - l)
        return l - a * max(-1, min(k - 3, 9 - k, 1))
    }
    return CGColor(srgbRed: f(0), green: f(8), blue: f(4), alpha: 1)
}

enum FMC {
    static let bg = fmColor(0xFF14121A)
    static let raised = fmColor(0xFF221F2B)
    static let raisedHi = fmColor(0xFF2A2636)
    static let selected = fmColor(0xFF34304A)
    static let lineSoft = fmColor(0xFF2E2A3B)
    static let text = fmColor(0xFFF3EFF8)
    static let text2 = fmColor(0xFFC9C3D6)
    static let muted = fmColor(0xFFA9A3B8)
    static let faint = fmColor(0xFF6B6580)
    static let keyWhite = fmColor(0xFFECE7F2)
    static let keyBlack = fmColor(0xFF2A2633)
    static let keyLabelOnBlack = fmColor(0xFFB9B2C8)
    static let ledOff = fmColor(0xFF3A3548)
    static let ledOffOnWhite = fmColor(0xFFD3CCDD)
    static let fm = fmColor(0xFFC6F24E)
    static let fmDim = fmColor(0xFF7FA62A)
    static let fmTint = fmColor(0xFF4C5A2A)
    static let led = fmColor(0xFFFF9F2E)
    static let sliderFill = fmColor(0xFF3A3450)
    static let warn = fmColor(0xFFFFB547)
    static let dangerText = fmColor(0xFFFFB4A3)
    static let ink = fmColor(0xFF14121A)
    static let bezel = fmColor(0xFF0B0A0F)
    static let buttonFg = fmColor(0xFFE4DFEE)
    static let black = fmColor(0xFF000000)
    // Kotlin's `.copy(alpha = …)` variants, made once
    static let ledGlow = fmColor(0xFFFF9F2E, alpha: 0.45)
    static let ledHalo = fmColor(0xFFFF9F2E, alpha: 0.3)
    static let fingerRing = fmColor(0xFFC6F24E, alpha: 0.35)
    static let dim = fmColor(0xFF14121A, alpha: 0.55)

    static let coral = fmColor(0xFFFF9A7A)
    static let amber = fmColor(0xFFFFB547)
    static let sky = fmColor(0xFF8FD8FF)
    static let violet = fmColor(0xFFB9A2FF)

    static func pad(_ name: String) -> CGColor {
        switch name {
        case "coral": return coral
        case "amber": return amber
        case "sky": return sky
        case "violet": return violet
        default: return raised
        }
    }
}

func fmFillRoundRect(_ g: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ c: CGColor) {
    guard w > 0, h > 0 else { return }
    let rad = max(0, min(r, w / 2, h / 2))   // Compose clamps the radius; CGPath asserts on it
    g.setFillColor(c)
    g.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: rad, cornerHeight: rad, transform: nil))
    g.fillPath()
}

func fmStrokeRoundRect(_ g: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ c: CGColor,
                       _ width: CGFloat, dash: [CGFloat]? = nil) {
    guard w > 0, h > 0 else { return }
    let rad = max(0, min(r, w / 2, h / 2))
    g.saveGState()
    g.setStrokeColor(c)
    g.setLineWidth(width)
    if let dash { g.setLineDash(phase: 0, lengths: dash) }
    g.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: rad, cornerHeight: rad, transform: nil))
    g.strokePath()
    g.restoreGState()
}

func fmFillCircle(_ g: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ c: CGColor) {
    guard r > 0 else { return }
    g.setFillColor(c)
    g.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
}

func fmStrokeCircle(_ g: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ c: CGColor, _ width: CGFloat) {
    guard r > 0 else { return }
    g.setStrokeColor(c)
    g.setLineWidth(width)
    g.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
}

func fmLine(_ g: CGContext, _ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ c: CGColor, _ width: CGFloat,
            cap: CGLineCap = .butt) {
    g.setStrokeColor(c)
    g.setLineWidth(width)
    g.setLineCap(cap)
    g.move(to: CGPoint(x: x1, y: y1))
    g.addLine(to: CGPoint(x: x2, y: y2))
    g.strokePath()
    g.setLineCap(.butt)
}

/// Text on the instrument in fixed points (HANDOFF §11: fixed geometry, no dynamic type). Fonts are made once
/// per style and laid-out lines are cached, so redrawing a layer doesn't lay the same labels out again.
/// Android's MONOSPACE / SANS_SERIF are SF Mono / SF here (the system faces).
final class FMInk {
    enum Align { case center, left, right }

    private struct FontKey: Hashable { let size10: Int; let mono: Bool; let weight: Int }
    private struct LineKey: Hashable { let text: String; let font: FontKey }
    private struct Line { let line: CTLine; let width: CGFloat }

    private var fonts: [FontKey: (CTFont, CGFloat)] = [:]   // font and its baseline offset from a centre line
    private var lines: [LineKey: Line] = [:]

    private static func uiWeight(_ w: Int) -> UIFont.Weight {
        switch w {
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        default: return .heavy
        }
    }

    private func fontKey(_ size: CGFloat, _ mono: Bool, _ weight: Int) -> FontKey {
        FontKey(size10: Int((size * 10).rounded()), mono: mono, weight: weight)
    }

    private func font(_ k: FontKey) -> (CTFont, CGFloat) {
        if let f = fonts[k] { return f }
        let size = CGFloat(k.size10) / 10
        let ui = k.mono ? UIFont.monospacedSystemFont(ofSize: size, weight: FMInk.uiWeight(k.weight))
                        : UIFont.systemFont(ofSize: size, weight: FMInk.uiWeight(k.weight))
        let ct = ui as CTFont
        // Android centres on -(ascent + descent) / 2 of its font metrics: the same from CoreText's (both positive)
        let dy = (CTFontGetAscent(ct) - CTFontGetDescent(ct)) / 2
        let f = (ct, dy)
        fonts[k] = f
        return f
    }

    private func line(_ t: String, _ k: FontKey) -> Line {
        let key = LineKey(text: t, font: k)
        if let l = lines[key] { return l }
        if lines.count > 600 { lines.removeAll(keepingCapacity: true) }
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(k).0,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let ct = CTLineCreateWithAttributedString(NSAttributedString(string: t, attributes: attrs))
        let l = Line(line: ct, width: CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil)))
        lines[key] = l
        return l
    }

    func width(_ t: String, _ size: CGFloat, mono: Bool, weight: Int) -> CGFloat {
        t.isEmpty ? 0 : line(t, fontKey(size, mono, weight)).width
    }

    /// Text centred vertically on `cy`, aligned on `x`.
    func draw(_ g: CGContext, _ t: String, _ x: CGFloat, _ cy: CGFloat, _ size: CGFloat, _ color: CGColor,
              mono: Bool = false, weight: Int = 600, align: Align = .center) {
        if t.isEmpty { return }
        let k = fontKey(size, mono, weight)
        let l = line(t, k)
        let baseline = cy + font(k).1
        let x0: CGFloat
        switch align {
        case .center: x0 = x - l.width / 2
        case .left: x0 = x
        case .right: x0 = x - l.width
        }
        drawLine(g, l.line, x0, baseline, color)
    }

    /// Text with its baseline at `baseline`, starting at `x` (Android's drawText with Align.LEFT).
    func drawAtBaseline(_ g: CGContext, _ t: String, _ x: CGFloat, _ baseline: CGFloat, _ size: CGFloat, _ color: CGColor,
                        mono: Bool, weight: Int) {
        if t.isEmpty { return }
        drawLine(g, line(t, fontKey(size, mono, weight)).line, x, baseline, color)
    }

    private func drawLine(_ g: CGContext, _ l: CTLine, _ x: CGFloat, _ baseline: CGFloat, _ color: CGColor) {
        g.saveGState()
        g.setFillColor(color)
        g.textMatrix = CGAffineTransform(scaleX: 1, y: -1)   // UIKit's context is flipped
        g.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(l, g)
        g.restoreGState()
    }
}

// MARK: - haptics

/// Android's performHapticFeedback constants, played with UIKit's feedback generators.
enum FMHaptic { case clockTick, longPress, keyboardTap, virtualKey }

final class FMHaptics {
    private let selection = UISelectionFeedbackGenerator()
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let light = UIImpactFeedbackGenerator(style: .light)

    func prepare() {
        selection.prepare()
        light.prepare()
    }

    func perform(_ kind: FMHaptic) {
        switch kind {
        case .clockTick: selection.selectionChanged(); selection.prepare()
        case .longPress: medium.impactOccurred()
        case .keyboardTap, .virtualKey: light.impactOccurred(); light.prepare()
        }
    }
}

/// Milliseconds on a monotonic clock (Kotlin uses System.currentTimeMillis / uptimeMillis; only differences matter).
@inline(__always) func fmNowMs() -> Int64 { Int64(CACurrentMediaTime() * 1000) }

/// Runs `f` on the main queue after `ms` milliseconds (Kotlin's `scope.launch { delay(ms); … }`).
func fmAfter(_ ms: Int64, _ f: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(ms)), execute: f)
}

// MARK: - constants and small types

let FM_BUTTON_IDS = ["oct_down", "oct_up", "fx", "sel", "env", "lfo", "edit", "glo", "home", "save", "arp", "seq", "play", "rec"]
private let NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
func fmIsBlack(_ key: Int) -> Bool {
    switch (53 + key) % 12 { case 1, 3, 6, 8, 10: return true; default: return false }
}
private let KEY_NAMES: [String] = (0..<27).map { key in
    let n = 53 + key
    let name = NOTE_NAMES[n % 12]
    return name == "C" ? "C\(n / 12 - 1)" : name
}
private func noteName(_ key: Int) -> String { key >= 0 && key < 27 ? KEY_NAMES[key] : "" }

/// Controls drawn on the keys layer: they change on every note and key LED.
private let PLAYING_TYPES: Set<String> = ["keyboard", "pad_grid", "strum"]

private let FINE_HOLD_MS: Int64 = 400
private let LONG_PRESS_MS: Int64 = 500
private let EDIT_HOLD_MS: Int64 = 600
private let STILL_DP: CGFloat = 4
let FM_POT_RANGE_DP: CGFloat = 200
private let ARROW_DP: CGFloat = 36
/// The firmware's own pitch-bend range (OberVave's and ShineOn's BEND in every factory program).
private let FIRMWARE_BEND_ST: CGFloat = 2
/// How long after an engine runs its firmware takes to listen (OberVave's package ~2 s, the cartridge ~1.5 s).
private let FIRMWARE_BOOT_MS: Int64 = 2000

typealias FMPointer = ObjectIdentifier

/// What one finger is doing: it belongs to the control it first touched until it lifts (rule 1).
final class FMGrab {
    let pointer: FMPointer
    let control: FMControl?
    let start: CGPoint
    let t0: Int64
    var last: CGPoint
    var moved = false
    var fine = false
    var sub = -1                  // key / pad / string currently held by this finger
    var acc: CGFloat = 0          // encoder accumulation in dp
    var clicks = 0                // clicks sent during this grab (bubble, spring back)
    var startValues: [String: Float] = [:]
    var longFired = false
    var note = -1                 // velocity strips: the MIDI note this finger sounds (-1: a firmware key press)
    var vel = 0                   // and the velocity it struck with (a glissando keeps it)
    var cc7 = -1                  // the volume this finger's swell last sent
    var at = -1                   // the pressure (the held note's own level) this finger last sent
    var bendRaw = 8192            // the pitch bend this finger last sent

    init(_ pointer: FMPointer, _ control: FMControl?, _ start: CGPoint, _ t0: Int64) {
        self.pointer = pointer; self.control = control; self.start = start; self.t0 = t0; self.last = start
    }
}

/// A keyboard strip's key rects for one window of firmware keys in one rect.
private final class FMKeyGeometry {
    let window: ClosedRange<Int>
    let rect: FMGrid.Rect
    let keys: [(Int, FMGrid.Rect)]
    init(_ window: ClosedRange<Int>, _ rect: FMGrid.Rect, _ keys: [(Int, FMGrid.Rect)]) { self.window = window; self.rect = rect; self.keys = keys }
}

/// The surface's state. Kotlin keeps it in Compose snapshot state; here it is plain storage, changed only through
/// the surface's helpers, which mark the layer that shows it.
final class FMSurfaceState {
    var page = 0
    var pressed: [String: Bool] = [:]      // control id: buttons, knobs, sliders, menu
    var held: [String: Bool] = [:]         // "id#sub": keys, pads, strings (their own layer)
    var toggles: [String: Bool] = [:]
    var values: [String: Float] = [:]      // absolute targets ("pot:master", "cc:1:74")
    var kbOffset: [String: Int] = [:]      // keyboard window shift, in firmware keys
    var fingers: [FMPointer: CGPoint] = [:] // dp
    var bubbles: [String: String] = [:]    // control id -> text
    var encoderTurns: [String: Int] = [:]  // control id -> clicks since its grab started
    var ledButtons = 0, ledKeys = 0, ledGlow = 0
    var noteOct = 0                        // velocity strips' own octave (MIDI notes skip the firmware's)
    var bendOn = false                     // the surface's BEND toggle: keyboard strips bend
}

/// What the firmware screen area says about the instance: a title, an action (tap the screen) and a hint.
struct FMScreenMessage: Equatable {
    let title: String
    let color: CGColor
    var action = ""
    var hint = ""
}

private func screenMessage(_ phase: String, _ restarts: Int, _ slow: Bool, _ speed: Int, _ hint: String) -> FMScreenMessage? {
    switch phase {
    case "booting": return FMScreenMessage(title: restarts > 0 ? "Restarting…" : "Starting…", color: FMC.muted)
    case "crashed": return FMScreenMessage(title: restarts > 0 ? "Restarting…" : "Crashed", color: FMC.muted)
    case "safe_mode": return FMScreenMessage(title: "Crashed twice", color: FMC.muted, action: "Run anyway")
    case "not_installed": return FMScreenMessage(title: "Doesn't run here yet", color: FMC.warn)
    // (in-process: its firmware's loop hung and holds the cartridge, FMutate.Instance phase :hung)
    case "hung": return FMScreenMessage(title: "Stuck", color: FMC.warn, hint: "Restart the app to run it again")
    case "running":
        if slow { return FMScreenMessage(title: "Too slow · \(speed) % speed", color: FMC.warn, hint: hint) }
        if !hint.isEmpty { return FMScreenMessage(title: "Audio dropouts", color: FMC.warn, hint: hint) }
        return nil
    default: return nil
    }
}

private func ledFor(_ c: FMControl, _ st: FMSurfaceState) -> Bool {
    for b in c.bindings {
        switch b.to {
        case let .button(id):
            if let i = FM_BUTTON_IDS.firstIndex(of: id), (st.ledButtons >> i) & 1 == 1 { return true }
        case let .key(n):
            if n >= 0 && n < 63 && (st.ledKeys >> n) & 1 == 1 { return true }
        default: break
        }
    }
    return false
}

/// MIDI pitch bend (14 bit) for a value: 0.5 is the centre (8192). (MotionMath.bendRaw in Kotlin.)
func fmBendRaw(_ v: Float) -> Int { fmClamp(fmRound(8192 + (v - 0.5) * 2 * 8191), 0, 16383) }

private func sendValueBytes(_ t: FMTarget, _ v: Float, _ control: String) -> [String: Any]? {
    switch t {
    case .pot: return ["t": "pot", "v": Double(v), "c": control]
    case let .midi(type, channel, number, _, _, _):
        if type == "cc" {
            return ["t": "midi", "bytes": [0xB0 | (channel - 1), number, fmRound(v * 127)],
                    "c": control, "abs": t.absoluteKey ?? "", "v": Double(v)]
        } else if type == "pitch_bend" {
            let raw = fmBendRaw(v)
            return ["t": "midi", "bytes": [0xE0 | (channel - 1), raw & 0x7F, raw >> 7],
                    "c": control, "abs": t.absoluteKey ?? "", "v": Double(v)]
        }
        return nil
    default: return nil
    }
}

// MARK: - the view Mob mounts

/// Mob hands a fresh props map (and `send`) on every commit of the screen, including the two that follow each
/// input event; the surface unpacks it and does work only for what changed.
struct FMInstrumentRepresentable: UIViewRepresentable {
    let props: [String: Any]
    let send: MobNativeSend

    func makeUIView(context: Context) -> FMInstrumentSurface {
        let v = FMInstrumentSurface()
        v.update(props, send)
        return v
    }

    func updateUIView(_ v: FMInstrumentSurface, context: Context) {
        v.update(props, send)
    }

    static func dismantleUIView(_ v: FMInstrumentSurface, coordinator: ()) {
        v.dispose()
    }
}

/// A layer of the surface: a transparent view that redraws only when marked (setNeedsDisplay, whole or a rect).
final class FMLayerView: UIView {
    var paint: ((CGContext, CGRect) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        clearsContextBeforeDrawing = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        guard let g = UIGraphicsGetCurrentContext() else { return }
        paint?(g, rect)
    }
}

/// CADisplayLink retains its target: this breaks the cycle.
private final class FMWeakTick: NSObject {
    weak var owner: FMInstrumentSurface?
    init(_ owner: FMInstrumentSurface) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) { owner?.frameTick() }
}

final class FMInstrumentSurface: UIView {
    // ── props ──
    private var send: MobNativeSend?
    private var layoutJson: String?
    private(set) var layout: FMLayout?
    private var fbPath: String?
    private var bendOk = false
    private var oct0 = false
    private(set) var phase = ""
    private var quarantined = false
    private var restarts = 0
    private var slow = false
    private var speed = 0
    private var hint = ""
    private(set) var editing = false
    private var pageProp = ""
    private var addMenuJson: String?
    private var toastText = ""
    private var toastSeq: Int64 = 0
    private var mounted = false

    // ── state ──
    private(set) var state = FMSurfaceState()
    private var r7 = FMRule7()
    private let ink = FMInk()
    private let haptics = FMHaptics()
    private var toast = ""
    private var toastGen = 0
    private let edit = FMEditMode()
    private var addMenu: FMAddMenu?
    private var phaseGen = 0
    private var disposed = false
    // motion controls (FMutateMotionControl.swift); values the page doesn't show wait in heldBack (motionValue)
    private lazy var motion = FMMotionControls(sink: self)
    private let motionView = FMLayerView()
    private var motionShownKeys: Set<String> = []
    private var motionHeldBack: [String: Float] = [:]

    private var shm: FMFirmwareShm?
    private let screenScaler = FMScreenScaler()
    private var displayLink: CADisplayLink?
    private var screenLayers: [String: CALayer] = [:]
    private var screenFactor: [String: Int] = [:]
    private var lastLive = false

    // ── derived (recomputed by structureChanged) ──
    private var page: FMPage?
    private(set) var controls: [FMControl] = []
    private(set) var fitted: FMFitted?
    private var sizeDp = CGSize.zero
    private var restKeyLeds = false
    private var hasVelocityStrip = false
    private var fnButtons: [String] = []
    private var keyGeometry: [String: FMKeyGeometry] = [:]
    private var message: FMScreenMessage?

    // ── touch ──
    private var grabs: [FMPointer: FMGrab] = [:]

    // ── layers, bottom to top ──
    private let controlsView = FMLayerView()
    private let keysView = FMLayerView()
    private let screenPixelsView = UIView()
    private let screenMsgView = FMLayerView()
    private let menuView = FMOplingView()
    private let overlayView = FMLayerView()
    private let editUnderView = FMLayerView()   // edit mode's grid, under the controls
    private let editOverView = FMLayerView()    // edit mode's selection, drag, pill, menu and the toast, over everything

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = .clear
        screenPixelsView.isUserInteractionEnabled = false
        screenPixelsView.backgroundColor = .clear
        for v in [controlsView, keysView, screenPixelsView, screenMsgView, menuView, overlayView] { addSubview(v) }
        controlsView.paint = { [unowned self] g, r in self.drawControls(g, r) }
        keysView.paint = { [unowned self] g, r in self.drawPlaying(g, r) }
        screenMsgView.paint = { [unowned self] g, r in self.drawScreenMessages(g, r) }
        menuView.pressed = { [unowned self] in
            self.controls.first(where: { $0.type == "menu" }).map { self.state.pressed[$0.id] == true } ?? false
        }
        overlayView.paint = { [unowned self] g, r in self.drawOverlay(g, r) }
        insertSubview(editUnderView, at: 0)
        addSubview(editOverView)
        editUnderView.paint = { [unowned self] g, r in self.drawEditUnder(g, r) }
        editOverView.paint = { [unowned self] g, r in self.drawEditOver(g, r) }
        r7.ownerChanged = { [weak self] in self?.controlsView.setNeedsDisplay() }
        setUpMotion()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: props

    func update(_ props: [String: Any], _ send: @escaping MobNativeSend) {
        self.send = send
        if disposed { return }
        func str(_ k: String) -> String? { props[k] as? String }
        func bool(_ k: String) -> Bool { (props[k] as? NSNumber)?.boolValue == true }
        func num(_ k: String) -> NSNumber? { props[k] as? NSNumber }

        let first = !mounted
        mounted = true
        var structure = false
        var screenText = false

        // layout: a JSON string; a new layout id is a new surface state (Kotlin: remember(layout.id))
        let lj = str("layout")
        var layoutJsonChanged = false
        if lj != layoutJson {
            layoutJson = lj
            layoutJsonChanged = true
            edit.layoutChanged()
            let next = lj.flatMap(FMLayout.parse)
            if next?.id != layout?.id || next == nil {
                if layout != nil { disposeState() }
                state = FMSurfaceState()
                // Kotlin: remember(layout.id) { Rule7() }
                r7 = FMRule7()
                r7.ownerChanged = { [weak self] in self?.controlsView.setNeedsDisplay() }
            }
            layout = next
            keyGeometry.removeAll()
            structure = true
        }

        let newFb = str("fb")
        let newPhase = str("phase") ?? ""
        let newRestarts = num("restarts")?.intValue ?? 0
        let newSlow = bool("slow")
        let newSpeed = num("speed")?.intValue ?? 0
        let newHint = str("hint") ?? ""
        let newQuarantined = bool("quarantined")
        let newEditing = bool("editing")
        let newPageProp = str("page") ?? ""
        let newAddMenu = str("add_menu")
        let newToast = str("toast") ?? ""
        let newToastSeq = num("toast_seq")?.int64Value ?? 0
        let master = num("master")?.floatValue ?? -1
        bendOk = bool("bend")
        oct0 = bool("oct0")

        if newPhase != phase || newRestarts != restarts || newSlow != slow || newSpeed != speed || newHint != hint {
            screenText = true
        }
        let phaseChanged = first || newPhase != phase
        phase = newPhase; restarts = newRestarts; slow = newSlow; speed = newSpeed; hint = newHint
        quarantined = newQuarantined
        menuView.inputs(phase, quarantined, restarts, slow)
        let editingChanged = first || newEditing != editing
        if newEditing != editing { editing = newEditing; structure = true }
        if editingChanged && !editing { edit.reset() }
        let pageChanged = newPageProp != pageProp
        pageProp = newPageProp
        if newAddMenu != addMenuJson { addMenuJson = newAddMenu; addMenu = FMAddMenu.parse(newAddMenu); editOverView.setNeedsDisplay() }
        let toastChanged = first || newToastSeq != toastSeq
        toastSeq = newToastSeq
        toastText = newToast

        guard let layout else {
            // Kotlin returns from the composable: nothing drawn, nothing playable
            controls = []; fitted = nil; page = nil
            invalidateAll()
            return
        }

        // seed the pot from the instance once
        if master >= 0 && state.values["pot:master"] == nil { state.values["pot:master"] = master; controlsView.setNeedsDisplay() }

        // ── pages, toasts ──
        if layoutJsonChanged || pageChanged {
            if let i = layout.pages.firstIndex(where: { $0.id == pageProp }), i != state.page { state.page = i; structure = true }
        }
        if toastChanged {
            toast = toastText
            if edit.layoutChanged() { structure = true } // a refused edit comes back as a toast: drop its proposal
            toastGen += 1
            let gen = toastGen
            editOverView.setNeedsDisplay()
            fmAfter(2500) { [weak self] in
                guard let self, self.toastGen == gen else { return }
                self.toast = ""
                self.editOverView.setNeedsDisplay()
            }
        }

        // the layout's frame never rotates while playing (HANDOFF §5), and the instrument takes the whole screen.
        // iOS: Kotlin locks the orientation and hides the system bars here; on iOS the parent does both from
        // Elixir (Mob.Device.lock_orientation/1), not this view.

        // the firmware's screen and LEDs, once per display frame
        if first || newFb != fbPath {
            fbPath = newFb
            shm = newFb.flatMap { FMFirmwareShm(path: $0) }
            if shm == nil {
                // no screen file (safe mode, booting, stopped): no LEDs either, not the last engine's
                if state.ledButtons != 0 || state.ledKeys != 0 || state.ledGlow != 0 {
                    state.ledButtons = 0; state.ledKeys = 0; state.ledGlow = 0
                    controlsView.setNeedsDisplay()
                    keysView.setNeedsDisplay()
                }
            }
            updateDisplayLink()
            screenText = true
            updateScreenContents(force: true)
        }

        if structure { structureChanged() }
        if screenText {
            message = screenMessage(phase, restarts, slow, speed, hint)
            screenMsgView.setNeedsDisplay()
        }

        // controls stop sending input in edit mode: lift whatever was held when it began
        if editingChanged && editing {
            for id in Array(grabs.keys) { letGo(id) }
            motionAllOff()
        }

        if phaseChanged { phaseEffect() }
    }

    /// Once a new engine's firmware is up (its own boot takes ~1.5-2 s after the engine runs): toggles again, and
    /// strike-velocity strips' octave and the firmware's put in step at 0 (OCT− and OCT+ together, where the
    /// firmware does that). Toggled bindings (a sustain toggle, say) live in the firmware: a new engine (restart,
    /// firmware switch) starts without them, so they're sent again once it runs.
    private func phaseEffect() {
        phaseGen += 1
        let gen = phaseGen
        guard phase == "running" else { return }
        fmAfter(FIRMWARE_BOOT_MS) { [weak self] in
            guard let self, !self.disposed, self.phaseGen == gen else { return }
            for t in self.toggled() { self.fire(t, true) }
            if self.hasVelocityStrip && self.oct0 {
                self.input(["t": "button", "id": "oct_down", "d": true])
                self.input(["t": "button", "id": "oct_up", "d": true])
                fmAfter(60) { [weak self] in
                    guard let self, !self.disposed, self.phaseGen == gen else { return }
                    self.input(["t": "button", "id": "oct_down", "d": false])
                    self.input(["t": "button", "id": "oct_up", "d": false])
                    self.state.noteOct = 0
                    self.keysView.setNeedsDisplay()
                }
            }
        }
    }

    private func toggled() -> [FMTarget] {
        controls.flatMap { c in
            state.toggles[c.id] == true ? c.bindings.filter { $0.mode == "toggle" }.map(\.to) : []
        }
    }

    /// The surface goes (Kotlin's DisposableEffect(state) onDispose).
    func dispose() {
        if disposed { return }
        disposeState()
        disposed = true
        FMOrientation.hold(nil, window)
        displayLink?.invalidate()
        displayLink = nil
        shm = nil
    }

    private func disposeState() {
        // fingers still down when the surface goes (a sheet over it, another screen): let go of what they hold
        for id in Array(grabs.keys) { letGo(id) }
        for t in toggled() { fire(t, false) }
        motion.close()
        // a swell leaves the firmware's volume where the last finger was: full again
        if hasVelocityStrip { input(["t": "midi", "bytes": [0xB0, 7, 127]]) }
    }

    // MARK: structure (layout, page, size, mode)

    override func layoutSubviews() {
        super.layoutSubviews()
        for v in [controlsView, keysView, screenPixelsView, screenMsgView, overlayView, editUnderView, editOverView] { v.frame = bounds }
        if bounds.size != sizeDp {
            sizeDp = bounds.size
            structureChanged()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDisplayLink()
        if window != nil { haptics.prepare() }
        FMOrientation.hold(window != nil && !disposed ? layout?.landscape : nil, window)
    }

    private func structureChanged() {
        guard let layout, !layout.pages.isEmpty else {
            page = nil; controls = []; fitted = nil
            invalidateAll()
            return
        }
        let p = layout.pages[fmClamp(state.page, 0, layout.pages.count - 1)]
        page = p
        controls = layout.dock + p.controls
        if window != nil && !disposed { FMOrientation.hold(layout.landscape, window) }
        let w = sizeDp.width, h = sizeDp.height
        fitted = w <= 0 ? nil : (editing ? fmEditFit(layout, p, w, h) : fmFit(layout, p, w, h))
        // a button or knob bound to a firmware key lights with that key's LED: then the controls layer follows key LEDs too
        restKeyLeds = controls.contains { c in !PLAYING_TYPES.contains(c.type) && c.bindings.contains { $0.to.isKey } }
        // velocity strips on this layout (they play MIDI notes, so the firmware's OCT doesn't reach them: they keep
        // their own octave, moved by the same OCT presses, which still go to the firmware too)
        hasVelocityStrip = (layout.dock + layout.pages.flatMap(\.controls)).contains { $0.type == "keyboard" && $0.strikeVelocity }
        // controls that press a firmware button other than OCT: while one is held, keys are a layer of the
        // firmware's (SAVE + key, …), so velocity strips send key presses again
        fnButtons = controls.filter { c in
            c.type != "motion" && c.bindings.contains { b in
                if let id = b.to.buttonId { return id != "oct_down" && id != "oct_up" }
                return false
            }
        }.map(\.id)
        layoutScreenLayers()
        if let m = controls.first(where: { $0.type == "menu" }), let r = rectOf(m) {
            menuView.frame = r.cg
            menuView.isHidden = false
        } else {
            menuView.isHidden = true
        }
        motionStructureChanged()
        invalidateAll()
    }

    private func invalidateAll() {
        for v in [controlsView, keysView, screenMsgView, menuView, overlayView, editUnderView, editOverView] { v.setNeedsDisplay() }
    }

    /// A control's rect: in edit mode its proposed cell (FMEditMode.override), and none while it is being dragged
    /// (Kotlin skips `edit.hidden` controls in every layer; here a nil rect does that for every layer at once).
    func rectOf(_ c: FMControl) -> FMGrid.Rect? {
        if edit.hidden(c.id) { return nil }
        guard let f = fitted, let cell = edit.override(c.id) ?? f.placement.cells[c.id] else { return nil }
        return f.grid.rect(cell)
    }

    // MARK: invalidation helpers (what Compose's snapshot reads do on Android)

    private func dirtyControl(_ id: String) {
        if let c = controls.first(where: { $0.id == id }), let r = rectOf(c) {
            controlsView.setNeedsDisplay(r.cg.insetBy(dx: -4, dy: -4))
        }
    }

    private func dirtyPlaying(_ id: String) {
        if let c = controls.first(where: { $0.id == id }), let r = rectOf(c) {
            keysView.setNeedsDisplay(r.cg.insetBy(dx: -4, dy: -4))
        }
    }

    private func dirtyBubble(_ id: String) {
        if let c = controls.first(where: { $0.id == id }), let r = rectOf(c) {
            overlayView.setNeedsDisplay(r.cg.insetBy(dx: -64, dy: -28))
        }
    }

    private func setPressed(_ id: String, _ on: Bool) {
        if on { state.pressed[id] = true } else if state.pressed.removeValue(forKey: id) == nil { return }
        dirtyControl(id)
        if controls.contains(where: { $0.id == id && $0.type == "menu" }) { menuView.setNeedsDisplay() }
    }

    private func setHeld(_ key: String, _ on: Bool) {
        if on { state.held[key] = true } else if state.held.removeValue(forKey: key) == nil { return }
        if let i = key.firstIndex(of: "#") { dirtyPlaying(String(key[..<i])) }
        heldChanged()
    }

    /// Notes held changed: the Opling bobs.
    private func heldChanged() { menuView.notes(state.held.count) }

    private func putValue(_ key: String, _ v: Float) {
        state.values[key] = v
        for c in controls where c.bindings.contains(where: { $0.to.absoluteKey == key }) { dirtyControl(c.id) }
    }

    private func setBubble(_ id: String, _ t: String?) {
        if let t { state.bubbles[id] = t } else if state.bubbles.removeValue(forKey: id) == nil { return }
        dirtyBubble(id)
    }

    private func setEncoderTurns(_ id: String, _ n: Int?) {
        if let n { state.encoderTurns[id] = n } else { state.encoderTurns.removeValue(forKey: id) }
        dirtyControl(id)
    }

    private func setFinger(_ id: FMPointer, _ p: CGPoint?) {
        let old = state.fingers[id]
        if let p { state.fingers[id] = p } else { state.fingers.removeValue(forKey: id) }
        for q in [old, p] { if let q { overlayView.setNeedsDisplay(CGRect(x: q.x - 22, y: q.y - 22, width: 44, height: 44)) } }
    }

    private func setKbOffset(_ id: String, _ n: Int) {
        if state.kbOffset[id] == n { return }
        state.kbOffset[id] = n
        dirtyPlaying(id)
    }

    // MARK: sends

    private func haptic(_ k: FMHaptic) { haptics.perform(k) }
    private func emit(_ event: String, _ payload: [String: Any] = [:]) { send?(event, payload) }
    private func input(_ payload: [String: Any]) { emit("in", payload) }

    private func goPage(_ ref: String) {
        guard let layout, !layout.pages.isEmpty else { return }
        let n = layout.pages.count
        let i: Int
        switch ref {
        case "next": i = (state.page + 1) % n
        case "prev": i = (state.page - 1 + n) % n
        default: i = layout.pages.firstIndex { $0.id == ref } ?? state.page
        }
        if i != state.page {
            state.page = i
            emit("page", ["id": layout.pages[i].id])
            structureChanged()
        }
    }

    /// Press or release a discrete target (keys, buttons, notes, page).
    func fire(_ t: FMTarget, _ down: Bool) {
        switch t {
        case let .key(n): input(["t": "key", "k": n, "d": down])
        case let .button(id):
            input(["t": "button", "id": id, "d": down])
            if down && hasVelocityStrip && (id == "oct_down" || id == "oct_up") {
                state.noteOct = fmClamp(state.noteOct + (id == "oct_down" ? -1 : 1), -2, 2)
                keysView.setNeedsDisplay()
            }
        case let .midi(type, channel, number, _, on, off):
            switch type {
            case "note":
                input(["t": "midi", "bytes": [(down ? 0x90 : 0x80) | (channel - 1), number, down ? 100 : 0]])
            // a CC on a button: its `on` value while pressed (or toggled on); on release its `off` value, or the
            // value a knob/slider of this layout last set for that CC (so a long-release toggle gives it back)
            case "cc":
                let v = down ? on : (t.absoluteKey.flatMap { state.values[$0] }.map { fmRound($0 * 127) } ?? off)
                input(["t": "midi", "bytes": [0xB0 | (channel - 1), number, fmClamp(v, 0, 127)]])
            default: break
            }
        case let .action(id): if id == "bend" { state.bendOn = down }
        case let .page(ref): if down { goPage(ref) }
        case let .encoder(id, _, invert): if down { input(["t": "encoder", "id": id, "clicks": invert ? -1 : 1]) }
        case .pot: break
        }
    }

    private func tap(_ t: FMTarget) {
        fire(t, true)
        fire(t, false)
    }

    /// Swell: MIDI CC7 (the firmware's volume, every sounding note) follows the held finger front/back.
    private func swellTo(_ g: FMGrab, _ v: Int) {
        if v == g.cc7 { return }
        g.cc7 = v
        input(["t": "midi", "bytes": [0xB0, 7, fmClamp(v, 0, 127)]])
    }

    /// Pressure: the held note's own level (MIDI polyphonic aftertouch), for firmwares that take it.
    private func pressureTo(_ g: FMGrab, _ v: Int) {
        if g.note < 0 || v == g.at { return }
        g.at = v
        input(["t": "midi", "bytes": [0xA0, g.note, fmClamp(v, 0, 127)]])
    }

    /// A keyboard strip's key down: a velocity strip plays a MIDI note (FM-1 key 0 = F3 = MIDI 53, plus its own
    /// octave) at the finger's velocity; otherwise, or while a firmware function button is held, a firmware key.
    private func keyOn(_ c: FMControl, _ g: FMGrab, _ k: Int) {
        let layerHeld = fnButtons.contains { state.pressed[$0] == true }
        if c.strikeVelocity && !layerHeld {
            g.note = fmClamp(53 + k + 12 * state.noteOct, 0, 127)
            g.at = -1
            input(["t": "midi", "bytes": [0x90, g.note, fmClamp(g.vel, 1, 127)]])
            if c.velSwell && !c.velPressure && g.cc7 < 0 { swellTo(g, g.vel) }
        } else {
            g.note = -1
            fire(.key(k), true)
        }
    }

    private func keyOff(_ g: FMGrab, _ k: Int) {
        if g.note >= 0 { input(["t": "midi", "bytes": [0x80, g.note, 0]]) } else { fire(.key(k), false) }
        g.note = -1
    }

    /// Keyboard strips bend instead of glissando: their own glide setting, or the surface's BEND toggle.
    private func bends(_ c: FMControl) -> Bool { (c.wobble || state.bendOn) && bendOk }

    /// Press bindings of a button-like thing (a button, a single key, a pad).
    private func pressBindings(_ key: String, _ bindings: [FMBinding], _ down: Bool) {
        for b in bindings where b.on == "press" {
            if b.mode == "toggle" {
                if down {
                    let on = !(state.toggles[key] ?? false)
                    state.toggles[key] = on
                    dirtyControl(key)
                    fire(b.to, on)
                }
            } else {
                fire(b.to, down)
            }
        }
        if key.contains("#") { setHeld(key, down) } else { setPressed(key, down) }
    }

    private func sendValue(_ c: FMControl, _ t: FMTarget, _ v: Float) {
        if let p = sendValueBytes(t, v, c.id) { input(p) }
    }

    /// A relative move of `d` dp on a value control (knob, slider, xy axis).
    private func turn(_ c: FMControl, _ g: FMGrab, _ b: FMBinding, _ d: CGFloat) {
        let f: CGFloat = g.fine ? 0.25 : 1
        switch b.to {
        case let .encoder(id, pt, invert):
            guard pt > 0 else { return }
            g.acc += d * f * (invert ? -1 : 1)
            let n = Int(g.acc / pt)
            if n != 0 {
                g.acc -= CGFloat(n) * pt
                g.clicks += n
                setEncoderTurns(c.id, (state.encoderTurns[c.id] ?? 0) + n)
                input(["t": "encoder", "id": id, "clicks": n, "c": c.id])
                haptic(.clockTick)
                setBubble(c.id, (g.clicks > 0 ? "+" : "") + "\(g.clicks)" + (g.fine ? " · fine" : ""))
            }
        default:
            guard let key = b.to.absoluteKey else { return }
            let old = state.values[key] ?? 0.5
            let v = fmClamp(old + Float(d * f / FM_POT_RANGE_DP), 0, 1)
            if v != old {
                if v == 0 || v == 1 { haptic(.clockTick) }
                if !r7.accept(key, c.id, v, old) { return }
                putValue(key, v)
                sendValue(c, b.to, v)
                setBubble(c.id, "\(fmRound(v * 100))" + (g.fine ? " · fine" : ""))
            }
        }
    }

    private func setValue(_ c: FMControl, _ t: FMTarget, _ v: Float) {
        guard let key = t.absoluteKey else { return }
        if !r7.accept(key, c.id, v, state.values[key]) { return }
        putValue(key, v)
        sendValue(c, t, v)
    }

    // MARK: keyboard geometry

    /// The visible firmware keys of a strip.
    private func window(_ c: FMControl) -> ClosedRange<Int> {
        let n = max(c.toKey - c.fromKey, 0)
        let start = fmClamp(c.fromKey + (state.kbOffset[c.id] ?? 0), 0, 26 - n)
        return start...(start + n)
    }

    /// Per strip: its key rects for the last window and rect (rebuilt only after an octave shift or a refit).
    private func keyboardKeys(_ c: FMControl, _ r0: FMGrid.Rect) -> [(Int, FMGrid.Rect)] {
        let keys = window(c)
        let r = fmKeysRect(c, r0)
        if let g = keyGeometry[c.id], g.window == keys, g.rect == r { return g.keys }
        let arrows: CGFloat = c.octaveArrows && !fmHasRail(c) ? ARROW_DP : 0
        let len = (c.vertical ? r.h : r.w) - 2 * arrows
        let across = c.vertical ? r.w : r.h
        let whites = keys.filter { !fmIsBlack($0) }
        if whites.isEmpty { return [] }
        let ww = len / CGFloat(whites.count)
        var out: [(Int, FMGrid.Rect)] = []
        // along: position from the low end; mapped to x (horizontal) or from the bottom (vertical)
        func rectAlong(_ a: CGFloat, _ l: CGFloat, _ depth: CGFloat) -> FMGrid.Rect {
            c.vertical ? FMGrid.Rect(x: r.x + r.w - depth, y: r.y + r.h - arrows - a - l, w: depth, h: l)
                       : FMGrid.Rect(x: r.x + arrows + a, y: r.y, w: l, h: depth)
        }
        var i = 0
        for k in keys where !fmIsBlack(k) {
            out.append((k, rectAlong(CGFloat(i) * ww, ww - 2, across)))
            i += 1
        }
        i = 0
        for k in keys {
            if !fmIsBlack(k) { i += 1; continue }
            let bw = ww * 0.62
            out.append((k, rectAlong(CGFloat(i) * ww - bw / 2, bw, across * 0.6)))
        }
        keyGeometry[c.id] = FMKeyGeometry(keys, r, out)
        return out
    }

    private func keyAt(_ c: FMControl, _ r: FMGrid.Rect, _ p: CGPoint) -> Int? {
        let keys = keyboardKeys(c, r)
        // black keys sit on top
        if let k = keys.last(where: { fmIsBlack($0.0) && $0.1.contains(p.x, p.y) }) { return k.0 }
        return keys.first(where: { !fmIsBlack($0.0) && $0.1.contains(p.x, p.y) })?.0
    }

    /// Where on key [k] the finger is: 1 at its front edge (away from the black keys), 0 at its back edge.
    private func frontAt(_ c: FMControl, _ r: FMGrid.Rect, _ k: Int, _ p: CGPoint) -> CGFloat {
        guard let kr = keyboardKeys(c, r).first(where: { $0.0 == k })?.1, kr.w > 0, kr.h > 0 else { return 1 }
        // horizontal strips: black keys at the top, the front is the bottom; vertical: black keys on the right
        return fmClamp(c.vertical ? 1 - (p.x - kr.x) / kr.w : (p.y - kr.y) / kr.h, 0, 1)
    }

    /// Velocity from where key [k] is struck: velMax at its front edge, velMin at its back.
    private func strikeVelocity(_ c: FMControl, _ r: FMGrid.Rect, _ k: Int, _ p: CGPoint) -> Int {
        fmClamp(fmRound(CGFloat(c.velMin) + CGFloat(c.velMax - c.velMin) * frontAt(c, r, k, p)), 1, 127)
    }

    /// A held note's level from where the finger is now: full at the key's front edge, silent at its back edge.
    private func levelAt(_ c: FMControl, _ r: FMGrid.Rect, _ k: Int, _ p: CGPoint) -> Int { fmRound(127 * frontAt(c, r, k, p)) }

    private func arrowAt(_ c: FMControl, _ r: FMGrid.Rect, _ p: CGPoint) -> Int {
        if !c.octaveArrows || fmHasRail(c) { return 0 }
        let low = c.vertical ? p.y > r.y + r.h - ARROW_DP : p.x < r.x + ARROW_DP
        let high = c.vertical ? p.y < r.y + ARROW_DP : p.x > r.x + r.w - ARROW_DP
        return low ? -1 : high ? 1 : 0
    }

    private func shiftOctave(_ c: FMControl, _ dir: Int) {
        let n = c.toKey - c.fromKey
        let cur = state.kbOffset[c.id] ?? 0
        let next = cur + 12 * dir
        if c.fromKey + next >= 0 && c.fromKey + next <= 26 - n {
            setKbOffset(c.id, next)
            haptic(.keyboardTap)
        } else {
            // past either end: the firmware's own OCT− / OCT+ (HANDOFF §8)
            tap(.button(dir < 0 ? "oct_down" : "oct_up"))
        }
    }

    private func padAt(_ c: FMControl, _ r: FMGrid.Rect, _ p: CGPoint) -> Int? {
        if !r.contains(p.x, p.y) || c.padCols < 1 || c.padRows < 1 { return nil }
        let col = fmClamp(Int((p.x - r.x) / r.w * CGFloat(c.padCols)), 0, c.padCols - 1)
        let row = fmClamp(Int((p.y - r.y) / r.h * CGFloat(c.padRows)), 0, c.padRows - 1)
        let i = row * c.padCols + col
        return i < c.pads.count ? i : nil
    }

    private func stringAt(_ c: FMControl, _ r: FMGrid.Rect, _ p: CGPoint) -> Int? {
        if c.strings.isEmpty || !r.contains(p.x, p.y) { return nil }
        return fmClamp(Int((r.y + r.h - p.y) / r.h * CGFloat(c.strings.count)), 0, c.strings.count - 1)
    }

    /// Bend: half a key width of sideways slide is the strip's full bend (bendRange semitones, a quarter tone by
    /// default), so the finger never leaves its key. MIDI pitch bend is relative to the firmware's own bend range,
    /// taken as ±2 semitones (OberVave's and ShineOn's factory programs).
    private func bend(_ c: FMControl, _ g: FMGrab, _ r: FMGrid.Rect, _ p: CGPoint) {
        let keys = keyboardKeys(c, r)
        guard let wk = keys.first(where: { !fmIsBlack($0.0) })?.1 else { return }
        let ww = c.vertical ? wk.h : wk.w
        guard ww > 0 else { return }
        let along = c.vertical ? g.start.y - p.y : p.x - g.start.x
        let v = fmClamp(along / (ww / 2), -1, 1) * min(c.bendRange / FIRMWARE_BEND_ST, 1)
        let raw = fmClamp(fmRound(8192 + v * 8191), 0, 16383)
        if raw == g.bendRaw { return }
        g.bendRaw = raw
        input(["t": "midi", "bytes": [0xE0, raw & 0x7F, raw >> 7]])
    }

    // MARK: touch

    private func down(_ id: FMPointer, _ p: CGPoint, _ now: Int64) {
        if !editing && fitted?.placement.fits == false && p.y < 30 && abs(p.x - sizeDp.width / 2) < 160 {
            emit("use_classic")
            return
        }
        let c = controls.last { rectOf($0)?.contains(p.x, p.y) == true }
        let g = FMGrab(id, c, p, now)
        grabs[id] = g
        setFinger(id, p)
        guard let c, let r = rectOf(c) else {
            fmAfter(EDIT_HOLD_MS) { [weak self] in
                guard let self, self.grabs[id] === g, !g.moved else { return }
                self.haptic(.longPress)
                self.emit("edit")
            }
            return
        }
        switch c.type {
        case "menu":
            setPressed(c.id, true)
            fmAfter(EDIT_HOLD_MS) { [weak self] in
                guard let self, self.grabs[id] === g, !g.moved else { return }
                g.longFired = true
                self.haptic(.longPress)
                self.emit("pages")
            }
        case "button", "key", "label":
            if c.type == "label" && c.bindings.isEmpty { return }
            pressBindings(c.id, c.bindings, true)
            if let lb = c.binding("long_press") {
                fmAfter(LONG_PRESS_MS) { [weak self] in
                    guard let self, self.grabs[id] === g else { return }
                    g.longFired = true
                    self.haptic(.longPress)
                    self.tap(lb.to)
                }
            }
        case "pad_grid":
            if let i = padAt(c, r, p) { g.sub = i; pressBindings("\(c.id)#\(i)", c.pads[i].bindings, true) }
        case "keyboard":
            if fmRailHit(c, r, p.x, p.y) {
                g.sub = FM_RAIL_GRAB
                setKbOffset(c.id, fmRailStart(r, p.y, c.toKey - c.fromKey) - c.fromKey)
                return
            }
            let arrow = arrowAt(c, r, p)
            if arrow != 0 { shiftOctave(c, arrow); return }
            if let k = keyAt(c, r, p) {
                g.sub = k
                g.vel = strikeVelocity(c, r, k, p)
                setHeld("\(c.id)#\(k)", true)
                keyOn(c, g, k)
                if c.velPressure { pressureTo(g, levelAt(c, r, k, p)) }
            }
        case "strum":
            if let s = stringAt(c, r, p) { g.sub = s; setHeld("\(c.id)#\(s)", true); fire(.key(c.strings[s]), true) }
        case "page_switcher":
            guard let layout, !layout.pages.isEmpty else { return }
            let n = layout.pages.count
            let i = fmClamp(Int((p.x - r.x) / r.w * CGFloat(n)), 0, n - 1)
            goPage(layout.pages[i].id)
        // a motion control: hold engages while the finger is on it, latch toggles on a tap
        case "motion":
            if c.motionLatch && motion.isEngaged(c.id) { motionOff(c.id) } else { motionOn(c) }
        case "knob", "slider", "xy_pad":
            setPressed(c.id, true)
            setEncoderTurns(c.id, 0)
            var sv: [String: Float] = [:]
            for b in c.bindings { if let k = b.to.absoluteKey { sv[k] = state.values[k] ?? 0.5 } }
            g.startValues = sv
            // jump-to-position: MIDI CC sliders only (rule 5)
            if c.type == "slider", let b = c.binding("value"), b.to.isJumpMidi {
                let v = c.sliderVertical ? 1 - (p.y - r.y) / r.h : (p.x - r.x) / r.w
                setValue(c, b.to, Float(fmClamp(v, 0, 1)))
            }
            fmAfter(FINE_HOLD_MS) { [weak self] in
                guard let self, self.grabs[id] === g, !g.moved else { return }
                g.fine = true
                self.haptic(.clockTick)
                self.setBubble(c.id, "fine")
            }
        default: break
        }
    }

    private func move(_ id: FMPointer, _ p: CGPoint) {
        guard let g = grabs[id] else { return }
        let dx = p.x - g.last.x, dy = p.y - g.last.y
        if !g.moved && hypot(p.x - g.start.x, p.y - g.start.y) > STILL_DP { g.moved = true }
        g.last = p
        setFinger(id, p)
        guard let c = g.control, let r = rectOf(c) else { return }
        switch c.type {
        case "pad_grid":
            let i = padAt(c, r, p)
            if i != g.sub {
                if g.sub >= 0 && g.sub < c.pads.count { pressBindings("\(c.id)#\(g.sub)", c.pads[g.sub].bindings, false) }
                g.sub = i ?? -1
                if let i { pressBindings("\(c.id)#\(i)", c.pads[i].bindings, true) }
            }
        case "keyboard":
            if g.sub == FM_RAIL_GRAB { setKbOffset(c.id, fmRailStart(r, p.y, c.toKey - c.fromKey) - c.fromKey); return }
            if g.sub < 0 { return }
            if g.note >= 0 {
                if c.velPressure { pressureTo(g, levelAt(c, r, g.sub, p)) }
                else if c.velSwell { swellTo(g, strikeVelocity(c, r, g.sub, p)) }
            }
            if bends(c) { bend(c, g, r, p); return }
            if let k = keyAt(c, r, p), k != g.sub {
                setHeld("\(c.id)#\(g.sub)", false)
                keyOff(g, g.sub)
                g.sub = k
                setHeld("\(c.id)#\(k)", true)
                keyOn(c, g, k)
                if c.velPressure { pressureTo(g, levelAt(c, r, k, p)) }
            }
        case "strum":
            let s = stringAt(c, r, p)
            if s != g.sub {
                if g.sub >= 0 { setHeld("\(c.id)#\(g.sub)", false); fire(.key(c.strings[g.sub]), false) }
                g.sub = s ?? -1
                if let s { setHeld("\(c.id)#\(s)", true); fire(.key(c.strings[s]), true) }
            }
        case "knob":
            if let b = c.binding("value") { turn(c, g, b, dx - dy) }
        case "slider":
            if let b = c.binding("value") {
                if !b.to.isJumpMidi { turn(c, g, b, c.sliderVertical ? -dy : dx) }
                else {
                    let v = c.sliderVertical ? 1 - (p.y - r.y) / r.h : (p.x - r.x) / r.w
                    setValue(c, b.to, Float(fmClamp(v, 0, 1)))
                }
            }
        case "xy_pad":
            if let b = c.binding("x") { turn(c, g, b, dx) }
            if let b = c.binding("y") { turn(c, g, b, -dy) }
        default: break
        }
    }

    private func up(_ id: FMPointer) {
        guard let g = grabs.removeValue(forKey: id) else { return }
        setFinger(id, nil)
        guard let c = g.control else { return }
        switch c.type {
        case "menu":
            setPressed(c.id, false)
            if !g.longFired { emit("menu") }
        case "button", "key", "label":
            pressBindings(c.id, c.bindings, false)
        case "pad_grid":
            if g.sub >= 0 && g.sub < c.pads.count { pressBindings("\(c.id)#\(g.sub)", c.pads[g.sub].bindings, false) }
        case "keyboard":
            if g.sub >= 0 {
                setHeld("\(c.id)#\(g.sub)", false)
                keyOff(g, g.sub)
                if bends(c) { input(["t": "midi", "bytes": [0xE0, 0, 64]]) }
            }
        case "strum":
            if g.sub >= 0 { setHeld("\(c.id)#\(g.sub)", false); fire(.key(c.strings[g.sub]), false) }
        case "knob", "slider", "xy_pad":
            setPressed(c.id, false)
            setBubble(c.id, nil)
            setEncoderTurns(c.id, nil)
            if c.type == "xy_pad" && c.springBack {
                for b in c.bindings {
                    switch b.to {
                    case let .encoder(eid, _, _):
                        if g.clicks != 0 { input(["t": "encoder", "id": eid, "clicks": -g.clicks]) }
                    default:
                        if let k = b.to.absoluteKey, let v = g.startValues[k] { setValue(c, b.to, v) }
                    }
                }
            }
        case "motion":
            if !c.motionLatch { motionOff(c.id) }
        case "screen":
            if !g.moved && phase == "safe_mode" { haptic(.virtualKey); emit("run_anyway") }
        default: break
        }
    }

    /// Release a finger that didn't lift normally: its control lets go, but a tap (the creature's menu) doesn't fire.
    private func letGo(_ id: FMPointer) {
        grabs[id]?.longFired = true
        up(id)
    }

    // The pointer loop: UIKit delivers touches by phase. Each event is also checked for fingers the surface lost:
    // every finger still down is in `event.allTouches`; a grab whose touch isn't never saw its lift (a cancelled
    // gesture, a missed up): let go of it rather than hold a key or button forever.

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { pointerEvent(touches, event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { pointerEvent(touches, event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { pointerEvent(touches, event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { pointerEvent(touches, event) }

    private func pointerEvent(_ touches: Set<UITouch>, _ event: UIEvent?) {
        let now = fmNowMs()
        var cancelled: [FMPointer] = []
        for t in touches {
            let id = ObjectIdentifier(t)
            let p = t.location(in: self)
            // edit mode takes the touches; a cancelled finger lifts there (Compose reports it as an up)
            if editing {
                if let ctx = editCtx() {
                    switch t.phase {
                    case .began: edit.down(ctx, id, p)
                    case .moved: edit.move(ctx, id, p, now)
                    case .ended, .cancelled: edit.up(ctx, id, p)
                    default: break
                    }
                }
                continue
            }
            switch t.phase {
            case .began: down(id, p, now)
            case .moved: move(id, p)
            case .ended: up(id)
            case .cancelled: cancelled.append(id)
            default: break
            }
        }
        // the system took these fingers away (Kotlin: a pointer missing from the event): let go, and say so
        var stale = cancelled.filter { grabs[$0] != nil }
        if !grabs.isEmpty {
            var down = Set<FMPointer>()
            for t in event?.allTouches ?? touches where t.phase != .ended && t.phase != .cancelled { down.insert(ObjectIdentifier(t)) }
            for k in grabs.keys where !down.contains(k) && !stale.contains(k) { stale.append(k) }
        }
        if !stale.isEmpty {
            let what = stale.compactMap { grabs[$0]?.control?.id }
            for k in stale { letGo(k) }
            emit("diag", ["stale_fingers": stale.count, "controls": what.joined(separator: ",")])
        }
        for id in cancelled { setFinger(id, nil) }
    }

    // MARK: the firmware screen

    private func updateDisplayLink() {
        let want = shm != nil && window != nil && !disposed
        if want && displayLink == nil {
            let link = CADisplayLink(target: FMWeakTick(self), selector: #selector(FMWeakTick.tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !want, let link = displayLink {
            link.invalidate()
            displayLink = nil
        }
    }

    /// Once per display frame while there is a screen file: a new engine frame, changed LEDs.
    func frameTick() {
        guard let shm else { return }
        if shm.poll() { updateScreenContents(force: false) }
        let live = shm.valid
        if live != lastLive { lastLive = live; screenMsgView.setNeedsDisplay(); updateScreenContents(force: true) }
        let b = shm.ledButtons, k = shm.ledKeys, gl = shm.glowKeys
        if b != state.ledButtons || k != state.ledKeys || gl != state.ledGlow {
            let buttonsChanged = b != state.ledButtons
            let keysChanged = k != state.ledKeys || gl != state.ledGlow
            state.ledButtons = b; state.ledKeys = k; state.ledGlow = gl
            if buttonsChanged || (restKeyLeds && keysChanged) { controlsView.setNeedsDisplay() }
            if keysChanged { keysView.setNeedsDisplay() }
        }
    }

    private var displayScale: CGFloat {
        let s = traitCollection.displayScale
        return s > 0 ? s : 3
    }

    /// One CALayer per screen control, at its pixel-exact box; the GPU scales the frame into it.
    private func layoutScreenLayers() {
        let screens = controls.filter { $0.type == "screen" }
        let ids = Set(screens.map(\.id))
        for (id, l) in screenLayers where !ids.contains(id) { l.removeFromSuperlayer(); screenLayers[id] = nil; screenFactor[id] = nil }
        let d = displayScale
        for c in screens {
            let l = screenLayers[c.id] ?? {
                let l = CALayer()
                l.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "frame": NSNull()]
                l.isOpaque = true
                l.contentsGravity = .resize
                screenPixelsView.layer.addSublayer(l)
                screenLayers[c.id] = l
                return l
            }()
            // no rect (being dragged in edit mode): drop the layer, since updateScreenContents shows every layer
            guard let r = rectOf(c) else { l.removeFromSuperlayer(); screenLayers[c.id] = nil; screenFactor[c.id] = nil; continue }
            let b = FMDraw.screenBox(r, c.screenScale, d)
            l.frame = CGRect(x: (b.x * d).rounded() / d, y: (b.y * d).rounded() / d,
                             width: CGFloat(b.sidePx) / d, height: CGFloat(b.sidePx) / d)
            let exact = b.sidePx % 240 == 0
            // a whole multiple: nearest-neighbour straight; smaller than 240: bilinear down; between: sharp scaling
            let k = (exact || b.sidePx < 240) ? 1 : (b.sidePx + 239) / 240
            l.magnificationFilter = exact ? .nearest : .linear
            l.minificationFilter = exact ? .nearest : .linear
            if screenFactor[c.id] != k { screenFactor[c.id] = k; l.contents = nil }
        }
        updateScreenContents(force: true)
    }

    private func updateScreenContents(force: Bool) {
        let live = shm?.valid == true
        let image = live ? shm?.image : nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, l) in screenLayers {
            guard let image else { l.contents = nil; l.isHidden = true; continue }
            l.isHidden = false
            let k = screenFactor[id] ?? 1
            l.contents = k == 1 ? image : screenScaler.prescaled(k, image)
        }
        CATransaction.commit()
    }

    // MARK: drawing

    /// The controls but the playing ones (buttons, knobs, labels): redrawn on presses, values and button LEDs.
    private func drawControls(_ g: CGContext, _ dirty: CGRect) {
        if !editing {
            g.setFillColor(FMC.bg)
            g.fill(dirty)
        }
        guard fitted != nil, let layout else { return }
        let dr = FMDraw(g: g, d: displayScale, ink: ink)
        for c in controls {
            guard let r = rectOf(c), r.cg.insetBy(dx: -6, dy: -6).intersects(dirty) else { continue }
            switch c.type {
            case "button", "key": dr.button(c, r, state, ledFor(c, state))
            case "knob": dr.knob(c, r, state)
            case "slider": dr.slider(c, r, state)
            case "xy_pad": dr.xy(c, r, state)
            case "motion": dr.motion(c, r, state, motion.hasAccel)
            case "screen": dr.screenBezel(r, c.screenScale)
            case "label": dr.label(c, r)
            case "page_switcher": dr.switcher(c, r, layout, state.page)
            default: break
            }
            if r7.stale(c) { fmDimOver(g, r) }
        }
    }

    /// Keys, pads, strings: they change on every note and key LED.
    private func drawPlaying(_ g: CGContext, _ dirty: CGRect) {
        guard fitted != nil else { return }
        let dr = FMDraw(g: g, d: displayScale, ink: ink)
        for c in controls {
            guard let r = rectOf(c), r.cg.insetBy(dx: -6, dy: -6).intersects(dirty) else { continue }
            switch c.type {
            case "pad_grid": dr.pads(c, r, state)
            case "keyboard":
                var cc = c
                if fmHasRail(c) { cc.octaveArrows = false }
                dr.keyboard(cc, r, state, keyboardKeys(c, r))
                if fmHasRail(c) { fmDrawRail(g, r, window(c)) }
            case "strum": dr.strum(c, r, state)
            default: break
            }
        }
    }

    /// The instance's state (starting, restarting, safe mode, too slow) is a message inside the screen area.
    private func drawScreenMessages(_ g: CGContext, _ dirty: CGRect) {
        guard let m = message, fitted != nil else { return }
        let live = shm?.valid == true
        let dr = FMDraw(g: g, d: displayScale, ink: ink)
        for c in controls where c.type == "screen" {
            if let r = rectOf(c) { dr.screenMessage(r, c.screenScale, m, live) }
        }
    }

    /// Fingers, value bubbles and the banner: redrawn on every finger move without touching the controls.
    private func drawOverlay(_ g: CGContext, _ dirty: CGRect) {
        guard let f = fitted else { return }
        let dr = FMDraw(g: g, d: displayScale, ink: ink)
        for (id, t) in state.bubbles {
            if let c = controls.first(where: { $0.id == id }), let r = rectOf(c) { dr.bubbleFor(c, r, t) }
        }
        for (_, p) in state.fingers { dr.finger(p) }
        if !f.placement.fits && !editing { dr.banner("Doesn't fit this phone · tap for Classic", bounds.width) }
    }

    // MARK: edit mode (FMutateEditMode.swift)

    private func editCtx() -> FMEditCtx? {
        guard let layout, let page, let f = fitted else { return nil }
        return FMEditCtx(
            layout: layout, page: page, pageIndex: layout.pages.firstIndex { $0.id == page.id } ?? -1, grid: f.grid,
            wDp: sizeDp.width, hDp: sizeDp.height, addMenu: addMenu,
            emit: { [weak self] e, p in self?.emit(e, p) },
            setPage: { [weak self] i in self?.goPage(layout.pages[i].id) },
            haptic: { [weak self] k in self?.haptic(k) },
            frame: { [weak self] in self?.editOverView.setNeedsDisplay() },
            placed: { [weak self] in self?.structureChanged() }
        )
    }

    private func drawEditUnder(_ g: CGContext, _ dirty: CGRect) {
        if editing, let ctx = editCtx() { edit.drawUnder(g, ctx, editUnderView.bounds) }
    }

    private func drawEditOver(_ g: CGContext, _ dirty: CGRect) {
        if editing, let ctx = editCtx() { edit.drawOver(g, ctx) }
        fmDrawToast(g, ink, toast, bounds.width, bounds.height)
    }
}

// MARK: - motion controls (FMutateMotionControl.swift): sensors only while one is engaged; sends go the usual ways

extension FMInstrumentSurface: FMMotionSink {
    /// The dots' layer, just above the firmware screen's (Kotlin's motion Canvas), redrawn per reading.
    private func setUpMotion() {
        insertSubview(motionView, aboveSubview: screenMsgView)
        motionView.paint = { [unowned self] g, r in self.drawMotion(g, r) }
        motion.onFrame = { [weak self] in self?.dirtyMotion() }
        // the app going to the background lets go of all of them (a latch would keep the sensors on)
        NotificationCenter.default.addObserver(self, selector: #selector(motionBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    @objc private func motionBackground() { motionAllOff() }

    /// From structureChanged: a page change (or a new layout) lets go of motion controls no longer shown.
    private func motionStructureChanged() {
        motionView.frame = bounds
        // values a knob or slider on this page shows go into the surface's state as they move (that layer must
        // show them); the others (a pitch bend, a CC nothing here shows) wait in motionHeldBack until the motion
        // control lets go, or every reading would redraw the controls layer
        motionShownKeys = Set(controls.filter { $0.type == "knob" || $0.type == "slider" }.flatMap { $0.bindings.compactMap(\.to.absoluteKey) })
        let ids = Set(controls.filter { $0.type == "motion" }.map(\.id))
        // Kotlin's retain(ids), plus the pressed look, which Kotlin leaves on
        for id in motion.engagedIds where !ids.contains(id) { motionOff(id) }
        motionView.setNeedsDisplay()
    }

    private func motionOn(_ c: FMControl) {
        setPressed(c.id, true)
        motion.engage(c, fmDisplayRotation(self))
    }

    private func motionOff(_ id: String) {
        motion.disengage(id)
        setPressed(id, false)
    }

    private func motionAllOff() {
        for c in controls where c.type == "motion" && motion.isEngaged(c.id) { motionOff(c.id) }
    }

    private func dirtyMotion() {
        for c in controls where c.type == "motion" {
            if let r = rectOf(c) { motionView.setNeedsDisplay(r.cg.insetBy(dx: -4, dy: -4)) }
        }
    }

    private func drawMotion(_ g: CGContext, _ dirty: CGRect) {
        guard fitted != nil else { return }
        let dr = FMDraw(g: g, d: displayScale, ink: ink)
        for c in controls where c.type == "motion" {
            guard let r = rectOf(c), r.cg.insetBy(dx: -4, dy: -4).intersects(dirty) else { continue }
            dr.motionDot(r, motion.dotX(c.id), motion.dotY(c.id), motion.isEngaged(c.id))
        }
    }

    func motionValue(_ c: FMControl, _ t: FMTarget, _ v: Float) -> Bool {
        guard let key = t.absoluteKey else { return false }
        if !r7.accept(key, c.id, v, motionHeldBack[key] ?? state.values[key]) { return false }
        if motionShownKeys.contains(key) { putValue(key, v) } else { motionHeldBack[key] = v }
        sendValue(c, t, v)
        return true
    }

    func motionClicks(_ c: FMControl, _ id: String, _ n: Int) {
        input(["t": "encoder", "id": id, "clicks": n, "c": c.id])
    }

    func motionCurrent(_ key: String) -> Float { motionHeldBack[key] ?? state.values[key] ?? 0.5 }

    func motionSettle() {
        for (k, v) in motionHeldBack { putValue(k, v) }
        motionHeldBack.removeAll()
    }
}

// MARK: - drawing primitives (Kotlin's Draw class; coordinates are points, so no density multiply)

struct FMDraw {
    let g: CGContext
    let d: CGFloat          // device pixels per point (the firmware screen is placed on whole device pixels)
    let ink: FMInk

    private func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ color: CGColor) {
        fmFillRoundRect(g, x, y, w, h, r, color)
    }

    func text(_ t: String, _ cx: CGFloat, _ cy: CGFloat, _ size: CGFloat, _ color: CGColor, mono: Bool = false, weight: Int = 600) {
        ink.draw(g, t, cx, cy, size, color, mono: mono, weight: weight)
    }

    func button(_ c: FMControl, _ r: FMGrid.Rect, _ st: FMSurfaceState, _ lit: Bool) {
        let pressed = st.pressed[c.id] == true
        let on = st.toggles[c.id] == true
        let y = pressed ? r.y + 2 : r.y
        let bg = pressed ? FMC.fm : on ? FMC.selected : c.color != "default" ? FMC.pad(c.color) : FMC.raised
        rr(r.x, y, r.w, r.h, 10, bg)
        text(c.label, r.cx, y + r.h / 2, 11, (pressed || c.color != "default") ? FMC.ink : FMC.buttonFg)
        fmFillCircle(g, r.x + r.w - 10, y + 10, 3, lit ? FMC.led : pressed ? FMC.fmDim : FMC.ledOff)
    }

    func knob(_ c: FMControl, _ r: FMGrid.Rect, _ st: FMSurfaceState) {
        let b = c.binding("value")
        let active = st.pressed[c.id] == true
        let labelH: CGFloat = 14
        let size = min(56, min(r.w, r.h - labelH))
        let k = size / 56
        let cx = r.cx
        let cy = r.y + (r.h - labelH) / 2
        func pt(_ deg: CGFloat, _ rad: CGFloat) -> CGPoint {
            CGPoint(x: cx + rad * k * cos(deg * .pi / 180), y: cy + rad * k * sin(deg * .pi / 180))
        }
        if case .encoder = b?.to {
            let turns = st.encoderTurns[c.id] ?? 0
            for i in 0..<16 {
                let lit = active && turns != 0 && i < min(16, abs(turns))
                let p = pt(-90 + CGFloat(i) * 22.5, 24.5)
                fmFillCircle(g, p.x, p.y, 1.7 * k, lit ? FMC.fm : FMC.ledOff)
            }
            fmFillCircle(g, cx, cy, 16 * k, active ? FMC.sliderFill : FMC.raisedHi)
            let p = pt(-90 + CGFloat(turns) * 22.5, 10)
            fmFillCircle(g, p.x, p.y, 2.6 * k, FMC.text)
        } else {
            let v = CGFloat(b?.to.absoluteKey.flatMap { st.values[$0] } ?? 0.5)
            func arc(_ sweep: CGFloat, _ color: CGColor) {
                g.saveGState()
                g.setStrokeColor(color)
                g.setLineWidth(4 * k)
                g.setLineCap(.round)
                // Compose's angles run clockwise from 3 o'clock; so do CG's in UIKit's flipped context
                g.addArc(center: CGPoint(x: cx, y: cy), radius: 22 * k, startAngle: 135 * .pi / 180,
                         endAngle: (135 + sweep) * .pi / 180, clockwise: false)
                g.strokePath()
                g.restoreGState()
            }
            arc(270, FMC.lineSoft)
            if v > 0.002 { arc(270 * v, FMC.fm) }
            fmFillCircle(g, cx, cy, 15 * k, FMC.raisedHi)
            let p = pt(135 + 270 * v, 10)
            fmFillCircle(g, p.x, p.y, 2.6 * k, FMC.text)
        }
        text(c.label, cx, r.y + r.h - labelH / 2, 10, active ? FMC.fm : FMC.muted, mono: true)
    }

    /// A control's value bubble (overlay layer): above a knob's dial, above sliders and XY pads.
    func bubbleFor(_ c: FMControl, _ r: FMGrid.Rect, _ t: String) {
        if c.type == "knob" {
            let k = min(56, min(r.w, r.h - 14)) / 56
            bubble(t, r.cx, r.y + (r.h - 14) / 2 - 34 * k)
        } else {
            bubble(t, r.cx, r.y - 4)
        }
    }

    private func bubble(_ t: String, _ cx: CGFloat, _ cy: CGFloat) {
        let w = ink.width(t, 10, mono: true, weight: 700) + 12
        rr(cx - w / 2, cy - 9, w, 18, 6, FMC.fm)
        text(t, cx, cy, 10, FMC.ink, mono: true, weight: 700)
    }

    func slider(_ c: FMControl, _ r: FMGrid.Rect, _ st: FMSurfaceState) {
        let b = c.binding("value")
        let active = st.pressed[c.id] == true
        rr(r.x, r.y, r.w, r.h, 14, FMC.raised)
        if let vf = b?.to.absoluteKey.flatMap({ st.values[$0] }) {
            let v = CGFloat(vf)
            if c.sliderVertical { rr(r.x, r.y + r.h * (1 - v), r.w, r.h * v, 14, active ? FMC.fmTint : FMC.sliderFill) }
            else { rr(r.x, r.y, r.w * v, r.h, 14, active ? FMC.fmTint : FMC.sliderFill) }
        } else if active {
            rr(r.x, r.y, r.w, r.h, 14, FMC.fmTint)
        }
        text(c.label, r.cx, c.sliderVertical ? r.y + r.h - 12 : r.cy, 10, active ? FMC.fm : FMC.muted, mono: true)
    }

    func xy(_ c: FMControl, _ r: FMGrid.Rect, _ st: FMSurfaceState) {
        let active = st.pressed[c.id] == true
        rr(r.x, r.y, r.w, r.h, 12, active ? FMC.fmTint : FMC.raised)
        fmLine(g, r.cx, r.y + 8, r.cx, r.y + r.h - 8, FMC.lineSoft, 1)
        fmLine(g, r.x + 8, r.cy, r.x + r.w - 8, r.cy, FMC.lineSoft, 1)
        text(c.label, r.cx, r.y + 12, 10, FMC.muted, mono: true)
    }

    func pads(_ c: FMControl, _ r: FMGrid.Rect, _ st: FMSurfaceState) {
        guard c.padCols > 0, c.padRows > 0 else { return }
        let gap: CGFloat = 6
        let pw = (r.w - CGFloat(c.padCols - 1) * gap) / CGFloat(c.padCols)
        let ph = (r.h - CGFloat(c.padRows - 1) * gap) / CGFloat(c.padRows)
        for (i, pad) in c.pads.enumerated() {
            let col = i % c.padCols
            let row = i / c.padCols
            if row >= c.padRows { break }
            let pressed = st.held["\(c.id)#\(i)"] == true
            let x = r.x + CGFloat(col) * (pw + gap)
            let y = r.y + CGFloat(row) * (ph + gap) + (pressed ? 2 : 0)
            let base = pad.color == "default" ? FMC.raised : FMC.pad(pad.color)
            rr(x, y, pw, ph, 12, pressed ? FMC.fm : base)
            text(pad.label, x + pw / 2, y + ph / 2, 11, (pressed || pad.color != "default") ? FMC.ink : FMC.buttonFg)
        }
    }

    func keyboard(_ c: FMControl, _ r: FMGrid.Rect, _ st: FMSurfaceState, _ keys: [(Int, FMGrid.Rect)]) {
        for (k, kr) in keys {
            let pressed = st.held["\(c.id)#\(k)"] == true
            let lit = (st.ledKeys >> k) & 1 == 1
            let glow = (st.ledGlow >> k) & 1 == 1
            let dy: CGFloat = pressed ? 2 : 0
            if !fmIsBlack(k) {
                let color = pressed ? FMC.fm : c.pitchColors ? pitch(53 + k, 0.62) : FMC.keyWhite
                rr(kr.x, kr.y + dy, kr.w, kr.h, 6, color)
                let ledC = lit ? FMC.led : pressed ? FMC.fmDim : glow ? FMC.ledGlow : FMC.ledOffOnWhite
                if lit { fmFillCircle(g, kr.cx, kr.y + dy + 12, 8, FMC.ledHalo) }
                fmFillCircle(g, kr.cx, kr.y + dy + 12, 3, ledC)
                if kr.w > 22 { text(noteName(k), kr.cx, kr.y + kr.h - 12 + dy, 10, FMC.faint, mono: true) }
            } else {
                rr(kr.x - 1, kr.y - 1, kr.w + 2, kr.h + 2, 7, FMC.bg)
                let color = pressed ? FMC.fm : c.pitchColors ? pitch(53 + k, 0.47) : FMC.keyBlack
                rr(kr.x, kr.y + dy, kr.w, kr.h, 6, color)
                let ledC = lit ? FMC.led : pressed ? FMC.fmDim : glow ? FMC.ledGlow : FMC.ledOff
                fmFillCircle(g, kr.cx, kr.y + dy + 10, 3, ledC)
            }
        }
        // a velocity strip's own octave (its MIDI notes skip the firmware's), shown when it isn't 0
        if c.strikeVelocity && st.noteOct != 0 {
            let t = "OCT " + (st.noteOct > 0 ? "+" : "") + "\(st.noteOct)"
            let x = r.x + 8 + (c.octaveArrows && !c.vertical ? ARROW_DP : 0)
            let y = c.vertical ? r.y + r.h - 34 : r.y + r.h * 0.62
            rr(x, y, 52, 20, 10, FMC.selected)
            text(t, x + 26, y + 10, 10, FMC.fm, mono: true)
        }
        if c.octaveArrows {
            let a = ARROW_DP
            if c.vertical {
                rr(r.x, r.y + r.h - a + 4, r.w, a - 4, 10, FMC.raised); text("▼", r.cx, r.y + r.h - a / 2, 12, FMC.text2)
                rr(r.x, r.y, r.w, a - 4, 10, FMC.raised); text("▲", r.cx, r.y + a / 2 - 2, 12, FMC.text2)
            } else {
                rr(r.x, r.y, a - 4, r.h, 10, FMC.raised); text("◀", r.x + a / 2 - 2, r.cy, 12, FMC.text2)
                rr(r.x + r.w - a + 4, r.y, a - 4, r.h, 10, FMC.raised); text("▶", r.x + r.w - a / 2 + 2, r.cy, 12, FMC.text2)
            }
        }
    }

    func strum(_ c: FMControl, _ r: FMGrid.Rect, _ st: FMSurfaceState) {
        rr(r.x, r.y, r.w, r.h, 12, FMC.raised)
        let n = c.strings.count
        for i in 0..<n {
            let y = r.y + r.h - (CGFloat(i) + 0.5) * r.h / CGFloat(n)
            let pressed = st.held["\(c.id)#\(i)"] == true
            fmLine(g, r.x + 8, y, r.x + r.w - 8, y, pressed ? FMC.fm : FMC.text2, pressed ? 3 : 1.5)
        }
    }

    /// Where the firmware screen goes in a control: the largest square that fits inside the bezel (scale 0,
    /// "fill"), or pixel-exact, the largest whole multiple of 240 device pixels up to scale (1..4).
    struct ScreenBox { let x: CGFloat, y: CGFloat, side: CGFloat, sidePx: Int }

    static func screenBox(_ r: FMGrid.Rect, _ scale: Int, _ d: CGFloat) -> ScreenBox {
        let bezel: CGFloat = 6
        let availPx = max(Int((min(r.w - 2 * bezel, r.h - 2 * bezel) * d).rounded(.down)), 1)
        let sidePx = (1...4).contains(scale) ? 240 * min(max(availPx / 240, 1), scale) : availPx
        let side = CGFloat(sidePx) / d
        return ScreenBox(x: r.cx - side / 2, y: r.cy - side / 2, side: side, sidePx: sidePx)
    }

    func screenBezel(_ r: FMGrid.Rect, _ scale: Int) {
        let b = FMDraw.screenBox(r, scale, d)
        rr(b.x - 6, b.y - 6, b.side + 12, b.side + 12, 12, FMC.bezel)
        g.setFillColor(FMC.black)
        g.fill(CGRect(x: b.x, y: b.y, width: b.side, height: b.side))
    }

    /// Text at most maxW dp wide: size dp, smaller (down to 8) when it doesn't fit.
    private func fitSize(_ t: String, _ size: CGFloat, _ maxW: CGFloat, _ mono: Bool, _ weight: Int) -> CGFloat {
        var sz = size
        while sz > 8 && ink.width(t, sz, mono: mono, weight: weight) > maxW { sz -= 1 }
        return sz
    }

    /// The instance's state inside the screen area (flat skin): centred on the dark screen while the firmware isn't
    /// showing; a strip along the bottom over its pixels when it is (too slow).
    func screenMessage(_ r: FMGrid.Rect, _ scale: Int, _ m: FMScreenMessage, _ live: Bool) {
        let b = FMDraw.screenBox(r, scale, d)
        let maxW = b.side - 12
        let cx = b.x + b.side / 2
        if live {
            let h: CGFloat = m.hint.isEmpty ? 22 : 36
            rr(b.x + 4, b.y + b.side - h - 4, b.side - 8, h, 8, FMC.raised)
            let y = b.y + b.side - h - 4
            text(m.title, cx, y + 11, fitSize(m.title, 11, maxW, true, 700), m.color, mono: true, weight: 700)
            if !m.hint.isEmpty { text(m.hint, cx, y + 26, fitSize(m.hint, 10, maxW, false, 600), FMC.muted) }
            return
        }
        let cy = b.y + b.side / 2
        if m.action.isEmpty {
            text(m.title, cx, cy, fitSize(m.title, 12, maxW, true, 600), m.color, mono: true)
            return
        }
        // "Crashed twice · Run anyway": the action in the quarantine colour (Flat-Library)
        let sep = " · "
        let line = m.title + sep + m.action
        let size = fitSize(line, 12, maxW, true, 600)
        let w = ink.width(line, size, mono: true, weight: 600)
        let wTitle = ink.width(m.title + sep, size, mono: true, weight: 600)
        let x0 = cx - w / 2
        text(m.title + sep, x0 + wTitle / 2, cy, size, m.color, mono: true)
        text(m.action, x0 + wTitle + (w - wTitle) / 2, cy, size, FMC.dangerText, mono: true)
    }

    func label(_ c: FMControl, _ r: FMGrid.Rect) { text(c.label, r.cx, r.cy, 11, FMC.muted, mono: true) }

    func switcher(_ c: FMControl, _ r: FMGrid.Rect, _ layout: FMLayout, _ page: Int) {
        let n = layout.pages.count
        guard n > 0 else { return }
        let w = r.w / CGFloat(n)
        for (i, p) in layout.pages.enumerated() {
            let x = r.x + CGFloat(i) * w
            if c.switcherDots {
                fmFillCircle(g, x + w / 2, r.cy, 4, i == page ? FMC.fm : FMC.ledOff)
            } else {
                rr(x + 2, r.cy - 14, w - 4, 28, 14, i == page ? FMC.selected : FMC.raised)
                text(p.name, x + w / 2, r.cy, 11, i == page ? FMC.fm : FMC.text2)
            }
        }
    }

    func finger(_ p: CGPoint) { fmStrokeCircle(g, p.x, p.y, 18, FMC.fingerRing, 2) }

    func banner(_ t: String, _ width: CGFloat) {
        let w = ink.width(t, 12, mono: false, weight: 600) + 24
        let cx = width / 2
        rr(cx - w / 2, 4, w, 24, 12, FMC.warn)
        text(t, cx, 16, 12, FMC.ink)
    }

    /// FMutate.Style.pitch_color/1: hue 0..300 across the 88 keys.
    func pitch(_ midi: Int, _ lightness: CGFloat) -> CGColor { fmPitchColor(midi, lightness) }
}
