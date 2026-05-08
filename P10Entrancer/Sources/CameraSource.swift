import AVFoundation
import CoreVideo
import Metal
import QuartzCore

@MainActor
final class CameraSource: NSObject, PadSource {
    private(set) var currentTexture: MTLTexture?
    private(set) var displayAspect: Float = 16.0 / 9.0

    private let context: MetalContext
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "p10e.camera", qos: .userInitiated)
    private var textureCache: CVMetalTextureCache?
    private var retainedCVTexture: CVMetalTexture?
    private let label: String

    init?(device: AVCaptureDevice, label: String, context: MetalContext = .shared) {
        self.context = context
        self.label = label
        super.init()

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, context.device, nil, &cache)
        self.textureCache = cache

        do {
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720

            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                print("[CameraSource:\(label)] cannot add input")
                session.commitConfiguration()
                return nil
            }
            session.addInput(input)

            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            let delegate = SampleBufferReceiver(owner: self)
            self.delegate = delegate
            videoOutput.setSampleBufferDelegate(delegate, queue: queue)
            guard session.canAddOutput(videoOutput) else {
                print("[CameraSource:\(label)] cannot add output")
                session.commitConfiguration()
                return nil
            }
            session.addOutput(videoOutput)

            if let connection = videoOutput.connection(with: .video) {
                let angle: CGFloat = 0
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }

            session.commitConfiguration()

            queue.async { [session] in
                session.startRunning()
            }
            print("[CameraSource:\(label)] started with device '\(device.localizedName)'")
        } catch {
            print("[CameraSource:\(label)] init failed: \(error)")
            return nil
        }
    }

    deinit {
        let session = self.session
        let queue = self.queue
        queue.async { session.stopRunning() }
    }

    func tick(timestamp: CFTimeInterval) {}

    fileprivate var delegate: SampleBufferReceiver?

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
            print("[CameraSource:\(label)] first frame \(w)x\(h)")
        }
        retainedCVTexture = cvTex
        currentTexture = CVMetalTextureGetTexture(cvTex)
    }
}

private final class SampleBufferReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var owner: CameraSource?

    init(owner: CameraSource) {
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
