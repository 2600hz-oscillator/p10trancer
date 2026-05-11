import AVFoundation
import CoreVideo
import Metal
import QuartzCore

@MainActor
final class VideoFileSource: PadSource, ObservableObject {
    private(set) var currentTexture: MTLTexture?
    private(set) var displayAspect: Float = 16.0 / 9.0

    let audioPlayer: PadAudioPlayer

    /// Per-pad play/stop. When false, tick() doesn't pull frames and
    /// the AVPlayer rate is 0. @Published so MIDIOutputBindings and
    /// UI can subscribe.
    @Published var isPlaying: Bool = true {
        didSet {
            guard isPlaying != oldValue else { return }
            audioPlayer.setPlaying(isPlaying)
            applyRate()
        }
    }

    /// Playback rate as a multiplier of normal speed. 1.0 = normal,
    /// 0.5 = half, 2.0 = double, -1.0 = reverse at normal speed.
    /// Range -4..+4 enforced by the UI slider, with 0 = paused.
    /// AVPlayer only honors negative rates for assets whose
    /// canPlayReverse / canPlaySlowReverse / canPlayFastReverse are
    /// true (essentially all local MP4 files). Audio playback rate
    /// isn't matched — the audio loops at its native rate while
    /// only video honors speed changes.
    @Published var playbackRate: Float = 1.0 {
        didSet { applyRate() }
    }

    /// Trim points as normalized [0..1] positions within the clip's
    /// full duration. When the player reaches trimEnd it loops back
    /// to trimStart. trimEnd > trimStart is enforced by the setters.
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 1

    /// Legacy shim from the AVAssetReader era — ThermalMonitor used
    /// to dial this down under heat to throttle pull rate. AVPlayer
    /// plays at its own pace; thermal management belongs on a
    /// future pass (could map to playbackRate during throttling).
    /// Stored but currently ignored.
    var targetFPS: Double = 15.0

    /// Current playback position as a normalized [0..1] fraction of
    /// the full clip duration. Driven from the periodic time
    /// observer; the UI's scrub slider reads + writes this.
    @Published private(set) var position: Double = 0

    let url: URL
    private let context: MetalContext
    private let player = AVPlayer()
    private var playerItem: AVPlayerItem?
    private let videoOutput: AVPlayerItemVideoOutput
    private var textureCache: CVMetalTextureCache?
    private var retainedCVTexture: CVMetalTexture?
    private var duration: CMTime = .zero
    private var timeObserverToken: Any?

    init(url: URL, context: MetalContext = .shared) {
        self.url = url
        self.context = context

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, context.device, nil, &cache)
        self.textureCache = cache
        if cache == nil {
            print("[VideoFileSource] CVMetalTextureCacheCreate failed status=\(cacheStatus)")
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        self.videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: outputSettings)

        self.audioPlayer = PadAudioPlayer(source: .file(url), label: url.lastPathComponent)
        player.actionAtItemEnd = .none // we manually loop within [trimStart, trimEnd]
        player.isMuted = true // audio path goes through PadAudioPlayer, not AVPlayer
        Task { [weak self] in await self?.start() }
    }

    deinit {
        if let token = timeObserverToken { player.removeTimeObserver(token) }
        player.pause()
    }

    private func start() async {
        let label = url.lastPathComponent
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
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
            let dur = try await asset.load(.duration)
            self.duration = dur

            let item = AVPlayerItem(asset: asset)
            item.add(videoOutput)
            self.playerItem = item
            player.replaceCurrentItem(with: item)
            // Periodic observer publishes position every ~50ms — coarse
            // enough not to thrash SwiftUI but fine enough that the
            // scrub slider tracks playback visibly.
            let interval = CMTime(value: 1, timescale: 20)
            timeObserverToken = player.addPeriodicTimeObserver(
                forInterval: interval,
                queue: .main
            ) { [weak self] time in
                guard let self else { return }
                Task { @MainActor in self.advancePosition(currentTime: time) }
            }
            applyRate()
            print("[VideoFileSource:\(label)] AVPlayer ready, dur=\(CMTimeGetSeconds(dur))s size=\(Int(w))x\(Int(h))")
        } catch {
            print("[VideoFileSource:\(label)] start error: \(error)")
        }
    }

    func tick(timestamp: CFTimeInterval) {
        guard isPlaying else { return }
        let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime) else { return }
        if let pb = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
            updateTexture(from: pb)
        }
    }

    // MARK: - Position / trim / rate (UI-driven)

    /// Seek to a fraction [0..1] of the FULL clip duration. UI passes
    /// the scrub slider's raw position; we clamp into the current
    /// trim region so dragging past trimEnd doesn't strand the
    /// playhead.
    func seek(toNormalized t: Double) {
        let durSec = CMTimeGetSeconds(duration)
        guard durSec > 0 else { return }
        let clamped = min(max(0, t), 1)
        let target = CMTime(seconds: durSec * clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        position = clamped
    }

    /// Set trim start. Clamps to [0, trimEnd-0.01] so the in/out
    /// brackets don't cross over.
    func setTrimStart(_ t: Double) {
        let clamped = min(max(0, t), trimEnd - 0.01)
        trimStart = clamped
        // If the playhead is now to the left of trimStart, snap it
        // forward so playback resumes inside the new region.
        if position < trimStart { seek(toNormalized: trimStart) }
    }

    func setTrimEnd(_ t: Double) {
        let clamped = max(min(1, t), trimStart + 0.01)
        trimEnd = clamped
        if position > trimEnd { seek(toNormalized: trimStart) }
    }

    private func applyRate() {
        // Rate may be negative for reverse. The UI's "paused dead
        // zone" sends 0 through; we treat any |rate| < 0.02 as a
        // pause to avoid sub-percept playback that looks frozen but
        // still consumes the decode loop.
        if !isPlaying || abs(playbackRate) < 0.02 {
            player.rate = 0
            return
        }
        player.rate = playbackRate
    }

    private func advancePosition(currentTime: CMTime) {
        let durSec = CMTimeGetSeconds(duration)
        guard durSec > 0 else { return }
        let nowSec = CMTimeGetSeconds(currentTime)
        let normalized = nowSec / durSec
        position = normalized
        // Trim-loop: behavior depends on direction.
        //   Forward: hit trimEnd → wrap back to trimStart.
        //   Reverse: hit trimStart → wrap forward to trimEnd.
        // Without an explicit reverse-wrap, AVPlayer would freeze at
        // time 0 once the playhead crossed trimStart, exactly the
        // "stops playing entirely" symptom reported when the user
        // dragged the speed slider into reverse.
        if player.rate > 0, normalized >= trimEnd - 0.0005 {
            seek(toNormalized: trimStart)
            applyRate()
        } else if player.rate < 0, normalized <= trimStart + 0.0005 {
            seek(toNormalized: max(trimStart, trimEnd - 0.0005))
            applyRate()
        }
    }

    private func updateTexture(from pixelBuffer: CVPixelBuffer) {
        guard let cache = textureCache else { return }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, w, h, 0, &cvTex
        )
        guard status == kCVReturnSuccess, let cvTex = cvTex else { return }
        if currentTexture == nil {
            print("[VideoFileSource:\(url.lastPathComponent)] first frame ready \(w)x\(h)")
        }
        retainedCVTexture = cvTex
        currentTexture = CVMetalTextureGetTexture(cvTex)
    }
}
