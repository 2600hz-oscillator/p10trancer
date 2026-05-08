import Foundation
import AVFoundation
import CoreVideo
import Metal
import Combine

@MainActor
final class MixerRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var lastRecordingURL: URL?

    private let context = MetalContext.shared
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var pixelBufferPool: CVPixelBufferPool?
    private var startTime: CMTime?
    private var frameCount: Int64 = 0
    private let frameDuration = CMTime(value: 1, timescale: 30)
    private var lastFrameAppendTime: CFTimeInterval = 0
    private var canvasSize: (Int, Int) = (1280, 720)
    var onFinish: ((URL) -> Void)?

    func toggle() {
        if isRecording {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard !isRecording else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("UserVideos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("recording-\(formatter.string(from: Date())).mp4")
        try? FileManager.default.removeItem(at: url)

        let (w, h) = canvasSize
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 6_000_000,
                    AVVideoMaxKeyFrameIntervalKey: 60
                ]
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true

            let pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: pixelBufferAttributes
            )
            guard writer.canAdd(videoInput) else {
                P10Logger.log("[MixerRecorder] cannot add video input")
                return
            }
            writer.add(videoInput)
            guard writer.startWriting() else {
                P10Logger.log("[MixerRecorder] startWriting failed: \(String(describing: writer.error))")
                return
            }
            writer.startSession(atSourceTime: .zero)

            self.writer = writer
            self.videoInput = videoInput
            self.pixelAdaptor = adaptor
            self.pixelBufferPool = adaptor.pixelBufferPool
            self.startTime = .zero
            self.frameCount = 0
            self.lastRecordingURL = url
            self.isRecording = true
            P10Logger.log("[MixerRecorder] started: \(url.lastPathComponent) \(w)x\(h)")
        } catch {
            P10Logger.log("[MixerRecorder] writer init failed: \(error)")
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        guard let writer = writer, let input = videoInput, let url = lastRecordingURL else { return }
        input.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                P10Logger.log("[MixerRecorder] finished: \(url.lastPathComponent)")
                self.writer = nil
                self.videoInput = nil
                self.pixelAdaptor = nil
                self.pixelBufferPool = nil
                self.onFinish?(url)
            }
        }
    }

    func captureFrame(from source: MTLTexture, elapsedTime: CFTimeInterval) {
        guard isRecording, let adaptor = pixelAdaptor, let videoInput = videoInput else { return }
        guard videoInput.isReadyForMoreMediaData else { return }
        let interval = 1.0 / 30.0
        if lastFrameAppendTime > 0 && (elapsedTime - lastFrameAppendTime) < interval { return }
        lastFrameAppendTime = elapsedTime

        let w = source.width
        let h = source.height
        if (w, h) != canvasSize {
            canvasSize = (w, h)
        }
        guard let pool = pixelBufferPool else { return }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard let pixelBuffer = pixelBuffer else { return }

        guard let cmd = context.commandQueue.makeCommandBuffer() else { return }
        var cvTexture: CVMetalTexture?
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, context.device, nil, &cache)
        guard let cache = cache else { return }
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, w, h, 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTex = cvTexture, let mtlTex = CVMetalTextureGetTexture(cvTex) else { return }
        guard let blit = cmd.makeBlitCommandEncoder() else { return }
        blit.copy(from: source, to: mtlTex)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        let pts = CMTimeMultiply(frameDuration, multiplier: Int32(frameCount))
        adaptor.append(pixelBuffer, withPresentationTime: pts)
        frameCount += 1
    }
}
