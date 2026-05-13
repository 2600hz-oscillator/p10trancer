import Foundation

@MainActor
final class ThermalMonitor: ObservableObject {
    @Published private(set) var state: ProcessInfo.ThermalState = .nominal

    private let pads: PadSystem
    private var observer: NSObjectProtocol?

    init(pads: PadSystem) {
        self.pads = pads
        self.state = ProcessInfo.processInfo.thermalState
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.update()
            }
        }
        applyDegradeRules()
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func update() {
        state = ProcessInfo.processInfo.thermalState
        applyDegradeRules()
        print("[ThermalMonitor] state changed to \(state.label)")
    }

    private func applyDegradeRules() {
        let videoFPS: Double
        switch state {
        case .nominal, .fair: videoFPS = 15.0
        case .serious: videoFPS = 7.5
        case .critical: videoFPS = 5.0
        @unknown default: videoFPS = 15.0
        }
        for pad in pads.pads {
            if let video = pad.source as? VideoFileSource {
                video.targetFPS = videoFPS
            }
        }
    }

    var label: String { state.label }
    var indicatorColor: ThermalIndicator { state.indicator }
}

enum ThermalIndicator {
    case nominal, warm, hot, critical
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "OK"
        case .fair: return "FAIR"
        case .serious: return "WARM"
        case .critical: return "HOT"
        @unknown default: return "?"
        }
    }
    var indicator: ThermalIndicator {
        switch self {
        case .nominal: return .nominal
        case .fair: return .warm
        case .serious: return .hot
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}
