import AVFoundation
import Combine
import Foundation

struct CameraDevice: Identifiable, Equatable {
    enum Kind { case builtinFront, builtinBack, external }
    let id: String
    let label: String
    let kind: Kind

    static func == (lhs: CameraDevice, rhs: CameraDevice) -> Bool { lhs.id == rhs.id }
}

/// Single source of truth for "what cameras are connected, and where do I get
/// a `PadSource` for one." Pads consume cameras by deviceID; if a UVC camera
/// disappears, the `PadSource` stays referenced but its `currentTexture` goes
/// nil (rendering black) until the device returns.
@MainActor
final class CameraRegistry: ObservableObject {
    @Published private(set) var devices: [CameraDevice] = []

    private var builtIn: BuiltInCameraSystem?
    private var externalSources: [String: CameraSource] = [:]
    private let externalSession = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.external],
        mediaType: .video,
        position: .unspecified
    )
    private var externalObserver: NSKeyValueObservation?

    func startIfNeeded() async {
        let granted = await CameraDeviceManager.requestCameraAccess()
        guard granted else {
            P10Logger.log("[CameraRegistry] camera access denied — nothing to expose")
            return
        }
        builtIn = BuiltInCameraSystem()
        externalObserver = externalSession.observe(\.devices, options: [.new, .initial]) { [weak self] session, _ in
            let devices = session.devices
            Task { @MainActor in
                self?.applyExternalDevices(devices)
            }
        }
        applyExternalDevices(externalSession.devices)
        rebuildDeviceList()
    }

    func source(for deviceID: String) -> PadSource? {
        switch deviceID {
        case "p10e.builtin.front":
            return builtIn?.frontSource
        case "p10e.builtin.back":
            return builtIn?.backSource
        default:
            return externalSources[deviceID]
        }
    }

    /// Reverse lookup: given a PadSource that came out of this registry,
    /// return its stable deviceID (or nil if it isn't a camera in this registry).
    func deviceID(for source: PadSource) -> String? {
        if let s = source as? BuiltInCameraSource {
            if s === builtIn?.frontSource { return "p10e.builtin.front" }
            if s === builtIn?.backSource  { return "p10e.builtin.back" }
        }
        if let s = source as? CameraSource {
            return s.deviceID
        }
        return nil
    }

    private func applyExternalDevices(_ avDevices: [AVCaptureDevice]) {
        let presentIDs = Set(avDevices.map { $0.uniqueID })
        // Tear down sources for devices that are gone.
        for id in externalSources.keys where !presentIDs.contains(id) {
            externalSources.removeValue(forKey: id)
            P10Logger.log("[CameraRegistry] external camera removed: \(id)")
        }
        // Create sources for new devices.
        for device in avDevices where externalSources[device.uniqueID] == nil {
            if let cam = CameraSource(device: device, label: device.localizedName) {
                externalSources[device.uniqueID] = cam
                P10Logger.log("[CameraRegistry] external camera added: \(device.localizedName) (\(device.uniqueID))")
            }
        }
        rebuildDeviceList()
    }

    private func rebuildDeviceList() {
        var entries: [CameraDevice] = []
        if builtIn?.backSource != nil {
            entries.append(CameraDevice(id: "p10e.builtin.back", label: "Back camera", kind: .builtinBack))
        }
        if builtIn?.frontSource != nil {
            entries.append(CameraDevice(id: "p10e.builtin.front", label: "Front camera", kind: .builtinFront))
        }
        for (id, source) in externalSources {
            entries.append(CameraDevice(id: id, label: source.label, kind: .external))
        }
        devices = entries.sorted { $0.label < $1.label }
    }
}
