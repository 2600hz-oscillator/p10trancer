import AVFoundation
import CoreVideo
import Metal
import QuartzCore
import UIKit

@MainActor
final class BuiltInCameraSystem {
    let backSource: BuiltInCameraSource?
    let frontSource: BuiltInCameraSource?

    private let session: AVCaptureMultiCamSession
    private let queue = DispatchQueue(label: "p10e.multicam", qos: .userInitiated)
    private var connections: [(connection: AVCaptureConnection, position: AVCaptureDevice.Position)] = []
    private var orientationObserver: NSObjectProtocol?

    init?() {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            print("[BuiltInCameraSystem] multicam not supported on this device")
            return nil
        }
        let session = AVCaptureMultiCamSession()
        self.session = session

        let backAttach = Self.attach(
            session: session,
            position: .back,
            label: "back",
            queue: queue,
            context: .shared
        )
        let frontAttach = Self.attach(
            session: session,
            position: .front,
            label: "front",
            queue: queue,
            context: .shared
        )
        self.backSource = backAttach?.source
        self.frontSource = frontAttach?.source
        if let c = backAttach?.connection { connections.append((c, .back)) }
        if let c = frontAttach?.connection { connections.append((c, .front)) }

        if backSource == nil && frontSource == nil {
            print("[BuiltInCameraSystem] could not attach any built-in camera")
            return nil
        }

        // Mirror the front camera so it reads as a "selfie" (the way users
        // expect — text/face left-right consistent with what they see).
        for (connection, position) in connections where position == .front {
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = true }
        }
        applyAngleForCurrentOrientation()
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyAngleForCurrentOrientation() }
        }

        queue.async { [session] in
            session.startRunning()
        }
        print("[BuiltInCameraSystem] running with back=\(backSource != nil) front=\(frontSource != nil)")
    }

    deinit {
        if let token = orientationObserver {
            NotificationCenter.default.removeObserver(token)
        }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    /// Map physical device orientation + camera position to AVCaptureConnection
    /// videoRotationAngle (degrees, CCW from sensor native). Updates every
    /// camera so cameras stay right-side-up as the user rotates the iPad.
    private func applyAngleForCurrentOrientation() {
        let orientation = UIDevice.current.orientation
        for (connection, position) in connections {
            let angle = Self.angle(forDevice: orientation, position: position)
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
    }

    private static func angle(forDevice orientation: UIDeviceOrientation,
                              position: AVCaptureDevice.Position) -> CGFloat {
        // Front camera uses Apple's standard videoRotationAngle table.
        // Back camera's sensor "up" direction is mounted such that its native
        // frame matches the front camera's only in portrait — in landscape the
        // two halves of the table are swapped. Empirically verified on iPad
        // Pro M2: back portrait=90 ✓, back landscape needs the inverse of
        // front's landscape values.
        switch (orientation, position) {
        case (.portrait, _):                       return 90
        case (.portraitUpsideDown, _):             return 270
        case (.landscapeLeft, .front):             return 180
        case (.landscapeLeft, .back):              return 0
        case (.landscapeRight, .front):            return 0
        case (.landscapeRight, .back):             return 180
        default:
            return 90
        }
    }

    private static func attach(
        session: AVCaptureMultiCamSession,
        position: AVCaptureDevice.Position,
        label: String,
        queue: DispatchQueue,
        context: MetalContext
    ) -> (source: BuiltInCameraSource, connection: AVCaptureConnection)? {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            print("[BuiltInCameraSystem:\(label)] no device for position \(position.rawValue)")
            return nil
        }

        do {
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                print("[BuiltInCameraSystem:\(label)] cannot add input")
                return nil
            }
            session.addInputWithNoConnections(input)

            guard let port = input.ports(for: .video, sourceDeviceType: device.deviceType, sourceDevicePosition: position).first else {
                print("[BuiltInCameraSystem:\(label)] no video port")
                return nil
            }

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            output.alwaysDiscardsLateVideoFrames = true
            guard session.canAddOutput(output) else {
                print("[BuiltInCameraSystem:\(label)] cannot add output")
                return nil
            }
            session.addOutputWithNoConnections(output)

            let connection = AVCaptureConnection(inputPorts: [port], output: output)
            guard session.canAddConnection(connection) else {
                print("[BuiltInCameraSystem:\(label)] cannot add connection")
                return nil
            }
            session.addConnection(connection)

            // Initial angle is set by `applyAngleForCurrentOrientation()` once
            // the system is wired up; updated on every device rotation event.
            let source = BuiltInCameraSource(label: label, context: context)
            output.setSampleBufferDelegate(source.delegate, queue: queue)
            return (source, connection)
        } catch {
            print("[BuiltInCameraSystem:\(label)] error: \(error)")
            return nil
        }
    }
}

@MainActor
final class BuiltInCameraSource: NSObject, PadSource {
    private(set) var currentTexture: MTLTexture?
    private(set) var displayAspect: Float = 16.0 / 9.0

    fileprivate let label: String
    fileprivate var delegate: BuiltInFrameReceiver!
    private let context: MetalContext
    private var textureCache: CVMetalTextureCache?
    private var retainedCVTexture: CVMetalTexture?

    init(label: String, context: MetalContext = .shared) {
        self.label = label
        self.context = context
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, context.device, nil, &cache)
        self.textureCache = cache
        super.init()
        self.delegate = BuiltInFrameReceiver(owner: self)
    }

    func tick(timestamp: CFTimeInterval) {}

    fileprivate func receive(pixelBuffer: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        if w > 0, h > 0 {
            let aspect = Float(w) / Float(h)
            if abs(aspect - displayAspect) > 0.001 { displayAspect = aspect }
        }
        guard let cache = textureCache else { return }
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, w, h, 0, &cvTex
        )
        guard status == kCVReturnSuccess, let cvTex = cvTex else { return }
        if currentTexture == nil {
            print("[BuiltInCameraSource:\(label)] first frame \(w)x\(h)")
        }
        retainedCVTexture = cvTex
        currentTexture = CVMetalTextureGetTexture(cvTex)
    }
}

final class BuiltInFrameReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var owner: BuiltInCameraSource?

    init(owner: BuiltInCameraSource) {
        self.owner = owner
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        Task { @MainActor [weak owner] in
            owner?.receive(pixelBuffer: pixelBuffer)
        }
    }
}
