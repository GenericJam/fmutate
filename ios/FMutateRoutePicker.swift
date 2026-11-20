// FMutateRoutePicker.swift: the I/O screen's audio output on iOS (FMutate.RoutePicker). iOS chooses the output
// itself (docs/decisions/2026-11-13-ios-port.md §5–6): the row names the session's current route and holds the
// system's route picker (AVRoutePickerView: speaker, headphones, Bluetooth, AirPlay), in place of Android's list.

import AVFAudio
import AVKit
import SwiftUI

private final class FMRoute: ObservableObject {
    @Published var name = FMRoute.current()
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                                       queue: .main) { [weak self] _ in self?.name = FMRoute.current() }
    }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }

    static func current() -> String {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outs.isEmpty ? "No output" : outs.map(\.portName).joined(separator: " + ")
    }
}

private struct FMRoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor(cgColor: FMC.text2)
        v.activeTintColor = UIColor(cgColor: FMC.fm)
        v.prioritizesVideoDevices = false
        return v
    }

    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}

struct FMRoutePicker: View {
    @StateObject private var route = FMRoute()

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Playing to").font(.system(size: 11)).foregroundColor(Color(cgColor: FMC.muted))
                Text(route.name).font(.system(size: 13, weight: .semibold)).foregroundColor(Color(cgColor: FMC.text))
            }
            Spacer(minLength: 0)
            FMRoutePickerButton().frame(width: 40, height: 40)
        }
        .frame(maxWidth: .infinity, minHeight: 40)
    }
}
