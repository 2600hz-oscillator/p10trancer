import AVFoundation
import Foundation

@MainActor
final class CameraDeviceManager {
    let externalSession = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.external],
        mediaType: .video,
        position: .unspecified
    )
    private var observer: NSKeyValueObservation?
    private(set) var externalDevices: [AVCaptureDevice] = []
    var onExternalDevicesChange: (([AVCaptureDevice]) -> Void)?

    init() {
        externalDevices = externalSession.devices
        observer = externalSession.observe(\.devices, options: [.new]) { [weak self] session, _ in
            let devices = session.devices
            Task { @MainActor in
                guard let self else { return }
                self.externalDevices = devices
                print("[CameraDeviceManager] external devices changed: \(devices.map { $0.localizedName })")
                self.onExternalDevicesChange?(devices)
            }
        }
        if !externalDevices.isEmpty {
            print("[CameraDeviceManager] external devices at start: \(externalDevices.map { $0.localizedName })")
        }
    }

    static func backCameraDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    static func frontCameraDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
    }

    static func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }
}
