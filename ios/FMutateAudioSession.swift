// FMutateAudioSession.swift — the iOS audio session for c_src/fm1audio.c's RemoteIO output.
//
// AVAudioSession is an Objective-C API; the mixer NIF is C. These @_cdecl functions are what it calls:
// fm1_session_activate sets the session up (playback, so the ring/silent switch doesn't mute it and it keeps
// playing in the background with UIBackgroundModes audio; mixing with other apps, as Android's AAudio stream
// plays beside other apps; a 5 ms IO buffer) and reports interruptions, route changes that change the rate and
// media-services resets back to the mixer, which reopens its unit after them.

import AVFAudio
import AudioToolbox
import Foundation

public typealias FM1SessionEvent = @convention(c) (Int32) -> Void

// Activation runs on the mixer's threads (a NIF, its helper), notifications arrive on the poster's thread: the
// state is read and written under `lock`, and the callback is called outside it (it may activate again).
private final class FM1Session {
    static let shared = FM1Session()
    private let lock = NSLock()
    private var onEvent: FM1SessionEvent?
    private var observing = false
    private var rate: Double = 0

    func activated(rate: Double, onEvent: FM1SessionEvent?) {
        lock.lock()
        self.onEvent = onEvent
        self.rate = rate
        let first = !observing
        observing = true
        lock.unlock()
        if first { observe() }
    }

    private func snapshot() -> (FM1SessionEvent?, Double) {
        lock.lock()
        defer { lock.unlock() }
        return (onEvent, rate)
    }

    private func send(_ kind: Int32) {
        if let f = snapshot().0 { f(kind) }
    }

    private func observe() {
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            self?.send(type == .began ? 1 : 2)
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            // (the unit converts from its rate to the hardware's itself; a new rate only costs latency, so it is
            // reopened at the new one)
            let (f, rate) = self.snapshot()
            if AVAudioSession.sharedInstance().sampleRate != rate { f?(3) }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
            self?.send(4)
        }
    }
}

/// Activate the session; `rate` and `ioBuffer` get the hardware's rate and IO buffer (seconds). 0 = ok.
@_cdecl("fm1_session_activate")
public func fm1_session_activate(_ rate: UnsafeMutablePointer<Double>, _ ioBuffer: UnsafeMutablePointer<Double>,
                                 _ onEvent: FM1SessionEvent?) -> Int32 {
    let s = AVAudioSession.sharedInstance()
    do {
        try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try s.setPreferredIOBufferDuration(0.005)
        try s.setActive(true)
    } catch {
        NSLog("[fm1audio] audio session: \(error)")
        return -1
    }
    FM1Session.shared.activated(rate: s.sampleRate, onEvent: onEvent)
    rate.pointee = s.sampleRate
    ioBuffer.pointee = s.ioBufferDuration
    NSLog("[fm1audio] session: %.0f Hz, IO buffer %.1f ms, output latency %.1f ms",
          s.sampleRate, s.ioBufferDuration * 1000, s.outputLatency * 1000)
    return 0
}

/// What a frame waits after the mixer renders it: the output's latency and one IO buffer, in seconds.
@_cdecl("fm1_session_latency")
public func fm1_session_latency() -> Double {
    let s = AVAudioSession.sharedInstance()
    return s.outputLatency + s.ioBufferDuration
}

@_cdecl("fm1_session_deactivate")
public func fm1_session_deactivate() {
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
}
