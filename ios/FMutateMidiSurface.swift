// FMutateMidiSurface.swift: port of android/.../fmutate/MidiSurface.kt.
//
// What learned MIDI controls show on the instrument surface (MIDI learn). FMutate.MIDI applies a learned hardware
// control's bindings in Elixir (the firmware gets its inputs from there) and hands the surface only what it must
// show, as text lines (FMutate.MIDI.Controls.surface_text): c_src/fm1surface.c's `surface/1` NIF calls
// fm1_surface_offer on a BEAM scheduler thread, which queues them here; the surface drains the queue on the main
// thread (one drain for everything queued meanwhile), so the screen's Elixir process never hears of it.
//
//     p <key> <0|1>                  a learned press went down / up (key: control id, or "<id>#<pad>")
//     t <key> <0|1>                  its toggle is now off / on
//     v <control> <target> <value>   absolute target (FMTarget.absoluteKey) moved to value (0..1) by control
//     e <control> <clicks>           encoder clicks sent for a knob / slider / XY pad
//     h <key> <0|1>                  an automapped pad holds the FM-1 button this control is bound to: lit only
//     o <-1|1>                       an automapped pad pressed OCT− / OCT+ (velocity strips' own octave follows)

import Foundation

enum FMMidiShow: Equatable {
    case press(String, Bool)
    case toggle(String, Bool)
    case value(control: String, target: String, Float)
    case clicks(String, Int)
    case shine(String, Bool)
    case octave(Int)

    /// The lines of one batch; malformed lines are skipped.
    static func parse(_ text: String) -> [FMMidiShow] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch f.first {
            case "p": return f.count == 3 ? .press(f[1], f[2] == "1") : nil
            case "t": return f.count == 3 ? .toggle(f[1], f[2] == "1") : nil
            case "v": return f.count == 4 ? Float(f[3]).map { .value(control: f[1], target: f[2], min(max($0, 0), 1)) } : nil
            case "e": return f.count == 3 ? Int(f[2]).map { .clicks(f[1], $0) } : nil
            case "h": return f.count == 3 ? .shine(f[1], f[2] == "1") : nil
            case "o": return f.count == 2 ? Int(f[1]).map { .octave(min(max($0, -1), 1)) } : nil
            default: return nil
            }
        }
    }
}

/// The surface that shows learned MIDI controls (the instrument surface on screen, if any).
protocol FMMidiShower: AnyObject {
    func showMidi(_ shows: [FMMidiShow])
}

final class FMMidiSurface {
    static let shared = FMMidiSurface()

    // batches nobody drained (no surface shown) are dropped past this many, oldest first
    private static let keep = 256

    private let lock = NSLock()
    private var queue: [String] = []
    private var scheduled = false
    /// (main thread only)
    weak var shower: FMMidiShower?

    /// From fm1_surface_offer (any thread).
    func offer(_ text: String) {
        lock.lock()
        queue.append(text)
        if queue.count > Self.keep { queue.removeFirst(queue.count - Self.keep) }
        let wake = !scheduled
        scheduled = true
        lock.unlock()
        if wake { DispatchQueue.main.async { self.deliver() } }
    }

    /// Everything queued, in order.
    func drain() -> [FMMidiShow] {
        lock.lock()
        let texts = queue
        queue.removeAll()
        scheduled = false
        lock.unlock()
        return texts.flatMap(FMMidiShow.parse)
    }

    /// A new surface starts from what it is told from now on.
    func clear() {
        lock.lock()
        queue.removeAll()
        lock.unlock()
    }

    private func deliver() {
        let shows = drain()
        if !shows.isEmpty { shower?.showMidi(shows) }
    }
}

@_cdecl("fm1_surface_offer")
public func fm1_surface_offer(_ text: UnsafePointer<UInt8>?, _ n: Int) {
    guard let text, n > 0 else { return }
    FMMidiSurface.shared.offer(String(decoding: UnsafeBufferPointer(start: text, count: n), as: UTF8.self))
}
