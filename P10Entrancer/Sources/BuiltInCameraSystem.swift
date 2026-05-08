import AVFoundation
import CoreVideo
import Metal
import QuartzCore

@MainActor
final class BuiltInCameraSystem {
    let backSource: BuiltInCameraSource?
    let frontSource: BuiltInCameraSource?

    private let session: AVCaptureMultiCamSession
    private let queue = DispatchQueue(label: "p10e.multicam", qos: .userInitiated)

    init?() {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            print("[BuiltInCameraSystem] multicam not supported on this device")
            return nil
        }
        let session = AVCaptureMultiCamSession()
        self.session = session

        let backResult = Self.attach(
            session: session,
            position: .back,
            label: "back",
            queue: queue,
            context: .shared
        )
        let frontResult = Self.attach(
            session: session,
            position: .front,
            label: "front",
            queue: queue,
            context: .shared
        )
        self.backSource = backResult
        self.frontSource = frontResult

        if backResult == nil && frontResult == nil {
            print("[BuiltInCameraSystem] could not attach any built-in camera")
            return nil
        }

        queue.async { [session] in
            session.startRunning()
        }
        print("[BuiltInCameraSystem] running with back=\(backResult != nil) front=\(frontResult != nil)")
    }

    private static func attach(
        session: AVCaptureMultiCamSession,
        position: AVCaptureDevice.Position,
        label: String,
        queue: DispatchQueue,
        context: MetalContext
    ) -> BuiltInCameraSource? {
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

            let angle: CGFloat = 0
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }

            let source = BuiltInCameraSource(label: label, context: context)
            output.setSampleBufferDelegate(source.delegate, queue: queue)
            return source
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
