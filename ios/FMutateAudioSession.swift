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

private final class FM1Session {
    static let shared = FM1Session()
    var onEvent: FM1SessionEvent?
    var observing = false
    var rate: Double = 0

    func observe() {
        guard !observing else { return }
        observing = true
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            self?.onEvent?(type == .began ? 1 : 2)
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            // (the unit converts from its rate to the hardware's itself; a new rate only costs latency, so it is
            // reopened at the new one)
            if AVAudioSession.sharedInstance().sampleRate != self.rate { self.onEvent?(3) }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
            self?.onEvent?(4)
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
    let session = FM1Session.shared
    session.onEvent = onEvent
    session.rate = s.sampleRate
    session.observe()
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
