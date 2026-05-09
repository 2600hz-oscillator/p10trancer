import AVFoundation
import CoreVideo
import Metal
import QuartzCore

@MainActor
final class VideoFileSource: PadSource, ObservableObject {
    private(set) var currentTexture: MTLTexture?
    private(set) var displayAspect: Float = 16.0 / 9.0
    var targetFPS: Double = 15.0

    let audioPlayer: PadAudioPlayer

    /// Per-pad play/stop state. When false, tick() doesn't pull new
    /// frames (so the visible texture freezes on the last decoded one)
    /// and the audio player is paused. Toggled by the pad's play/stop
    /// button and by MIDI play/stop events. @Published so MIDIOutputBindings
    /// can subscribe to changes for project-recall recording.
    @Published var isPlaying: Bool = true {
        didSet {
            guard isPlaying != oldValue else { return }
            audioPlayer.setPlaying(isPlaying)
        }
    }

    let url: URL
    private let context: MetalContext
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var textureCache: CVMetalTextureCache?
    private var retainedCVTexture: CVMetalTexture?
    private var lastFramePullTime: CFTimeInterval = 0

    init(url: URL, context: MetalContext = .shared) {
        self.url = url
        self.context = context
        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, context.device, nil, &cache)
        self.textureCache = cache
        if cache == nil {
            print("[VideoFileSource] CVMetalTextureCacheCreate failed status=\(cacheStatus)")
        }
        self.audioPlayer = PadAudioPlayer(source: .file(url), label: url.lastPathComponent)
        Task { [weak self] in
            await self?.startReader()
        }
    }

    deinit {
        reader?.cancelReading()
    }

    private func startReader() async {
        let label = url.lastPathComponent
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                print("[VideoFileSource:\(label)] no video track")
                return
            }
            let naturalSize = try await track.load(.naturalSize)
            let preferredTransform = try await track.load(.preferredTransform)
            let transformed = naturalSize.applying(preferredTransform)
            let w = abs(transformed.width)
            let h = abs(transformed.height)
            if w > 0, h > 0 { self.displayAspect = Float(w / h) }

            let outputSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            output.alwaysCopiesSampleData = false
            let reader = try AVAssetReader(asset: asset)
            reader.add(output)
            guard reader.startReading() else {
                print("[VideoFileSource:\(label)] startReading failed: \(String(describing: reader.error))")
                return
            }
            print("[VideoFileSource:\(label)] reading started, size=\(Int(w))x\(Int(h))")
            self.reader = reader
            self.output = output
        } catch {
            print("[VideoFileSource:\(label)] error: \(error)")
            self.reader = nil
            self.output = nil
        }
    }

    func tick(timestamp: CFTimeInterval) {
        guard isPlaying else { return }
        let interval = 1.0 / targetFPS
        if timestamp - lastFramePullTime < interval { return }
        guard let output = output, let reader = reader else { return }
        if reader.status != .reading {
            relaunchReader(timestamp: timestamp)
            return
        }
        if let sample = output.copyNextSampleBuffer() {
            lastFramePullTime = timestamp
            if let pb = CMSampleBufferGetImageBuffer(sample) {
                updateTexture(from: pb)
            }
        } else {
            relaunchReader(timestamp: timestamp)
        }
    }

    private var relaunchInFlight = false

    private func relaunchReader(timestamp: CFTimeInterval) {
        guard !relaunchInFlight else { return }
        relaunchInFlight = true
        lastFramePullTime = timestamp
        reader?.cancelReading()
        reader = nil
        output = nil
        Task { [weak self] in
            await self?.startReader()
            self?.relaunchInFlight = false
        }
    }

    private func updateTexture(from pixelBuffer: CVPixelBuffer) {
        guard let cache = textureCache else {
            print("[VideoFileSource:\(url.lastPathComponent)] updateTexture: no cache")
            return
        }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, w, h, 0, &cvTex
        )
        guard status == kCVReturnSuccess, let cvTex = cvTex else {
            print("[VideoFileSource:\(url.lastPathComponent)] CVMetalTextureCacheCreate failed status=\(status)")
            return
        }
        if currentTexture == nil {
            print("[VideoFileSource:\(url.lastPathComponent)] first frame ready \(w)x\(h)")
        }
        retainedCVTexture = cvTex
        currentTexture = CVMetalTextureGetTexture(cvTex)
    }
}
