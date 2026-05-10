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
    /// Wall-time of the first captured frame. All subsequent video PTS
    /// is derived from `(elapsedTime - recordStartElapsed)` so that
    /// even when rendering falls below 30fps, the file's video track
    /// stays the same length as the audio track. Without this, video
    /// PTS advanced at ~33ms per frame regardless of real elapsed
    /// time — a slow renderer made the video track shorter than audio
    /// in the saved file.
    private var recordStartElapsed: CFTimeInterval?
    private var lastFrameAppendTime: CFTimeInterval = 0
    private var canvasSize: (Int, Int) = (1280, 720)

    let audioAppender = AudioAppender()
    private var persistentTapInstalled = false
    private var persistentTapFormat: AVAudioFormat?

    /// Resolves the current mic gain at REC time. AppState wires this
    /// to walk routed camera pads and pull `audioPlayer.volume`. Without
    /// it, REC reads a stale `MicCapture.shared.recordGain` because
    /// nothing forces `applyAudioRouting` to run when the user moves
    /// only the camera pad's volume slider.
    var micGainProvider: (() -> Float)?

    /// Resolves the full list of auxiliary audio sources to mix into
    /// the recording (each routed camera contributes its own queue —
    /// either UVC embedded audio for cams that have it enabled, or
    /// iPad mic for the rest). If nil, falls back to the single-source
    /// micGainProvider path.
    var auxSourcesProvider: (() -> [AudioAppender.AudioSource])?

    var onFinish: ((URL) -> Void)?

    func toggle() {
        if isRecording {
            stop()
        } else {
            start()
        }
    }

    /// Install the recorder's tap on mainMixerNode at app startup so we
    /// never have to reconfigure the audio graph during REC (which
    /// silences playback on iPadOS 26). Buffers are gated by
    /// `audioAppender.enabled` — when not recording, the appender drops
    /// them on the floor, free.
    func installPersistentTap() {
        guard !persistentTapInstalled else { return }
        let mixer = AudioEngine.shared.engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            P10Logger.log("[MixerRecorder] mainMixer not ready (sr=0); deferring tap")
            return
        }
        mixer.installTap(onBus: 0, bufferSize: 4096, format: format) { [appender = audioAppender] buffer, time in
            appender.handle(buffer, audioTime: time)
        }
        persistentTapInstalled = true
        persistentTapFormat = format
        P10Logger.log("[MixerRecorder] persistent tap installed on mainMixer ch=\(format.channelCount) sr=\(format.sampleRate)")
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

            // Video
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

            // Audio — match the format the persistent tap is delivering.
            // Falls back to the live mainMixer format if the tap hasn't
            // been installed yet (e.g., engine wasn't ready at boot).
            installPersistentTap()
            let inputFormat = persistentTapFormat
                ?? AudioEngine.shared.engine.mainMixerNode.outputFormat(forBus: 0)
            var addedAudio = false
            // Capture mach time anchor BEFORE the writer starts so the
            // appender's first audio buffer can compute its PTS as a
            // real-time offset from REC press, matching the video PTS
            // origin (which uses CACurrentMediaTime — same clock).
            let recordStartHostTime = mach_absolute_time()
            if let (audioWriterInput, fmtDesc) = AudioAppender.makeInput(format: inputFormat),
               writer.canAdd(audioWriterInput) {
                writer.add(audioWriterInput)
                audioAppender.configure(input: audioWriterInput,
                                        formatDescription: fmtDesc,
                                        sampleRate: inputFormat.sampleRate,
                                        mainFormat: inputFormat,
                                        recordStartHostTime: recordStartHostTime)
                addedAudio = true
            } else {
                P10Logger.log("[MixerRecorder] could not configure audio input — recording video only")
            }

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
            // Anchored on the FIRST captured frame, not at REC press.
            // Both audio and video tracks then start at PTS=0 in the
            // file (audio drops pre-REC buffers; video uses its first
            // frame as origin). The writer's edit list normalizes both
            // to playback time 0, keeping them in sync.
            self.recordStartElapsed = nil
            self.lastFrameAppendTime = 0
            self.lastRecordingURL = url
            self.isRecording = true

            if addedAudio {
                // Per-camera audio: each routed camera contributes its
                // own source (UVC embedded or iPad mic), so multiple
                // cameras can record their own audio simultaneously.
                // Falls back to the single-source path if no provider
                // is wired (e.g., in unit tests).
                let auxes = auxSourcesProvider?() ?? []
                if auxes.isEmpty {
                    let gain = micGainProvider?() ?? MicCapture.shared.recordGain
                    MicCapture.shared.recordGain = gain
                    self.audioAppender.setMicMix(queue: MicCapture.shared.queue, gain: gain)
                    P10Logger.log("[MixerRecorder] mic mix (fallback) gain=\(gain) ready=\(MicCapture.shared.isReady)")
                } else {
                    self.audioAppender.setAuxSources(auxes)
                    let summary = auxes.map { "\($0.label)@\(String(format: "%.2f", $0.gain))" }.joined(separator: ",")
                    P10Logger.log("[MixerRecorder] aux audio sources: \(summary)")
                }
                audioAppender.setEnabled(true)
            }
            P10Logger.log("[MixerRecorder] started: \(url.lastPathComponent) \(w)x\(h) audio=\(addedAudio ? "yes" : "no")")
        } catch {
            P10Logger.log("[MixerRecorder] writer init failed: \(error)")
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false

        // Cut audio off first to avoid late buffers landing after finish.
        // We keep the persistent tap installed — the appender now
        // ignores buffers when disabled, and re-installing on next REC
        // would cause a graph reconfigure that silences playback.
        audioAppender.setEnabled(false)
        audioAppender.setMicMix(queue: nil, gain: 0)
        MicCapture.shared.queue.clear()
        // Wait for the appender's serial dispatch queue to drain any
        // already-built CMSampleBuffers into the writer. Without this,
        // those last ~50ms of buffers are dropped after markAsFinished
        // — that's the "audio cuts out before the end" symptom.
        audioAppender.flushPendingAppends()

        guard let writer = writer, let input = videoInput, let url = lastRecordingURL else { return }
        input.markAsFinished()
        audioAppender.markFinished()
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

        // Anchor wall-time origin on the FIRST captured frame so
        // video first PTS=0 in the file, mirroring audio's PTS=0
        // first kept buffer. Subsequent frames advance by real
        // elapsed time so the file's video duration tracks wall
        // clock (vs. assuming exactly 30fps via frame_index/30,
        // which made video shorter than audio under load).
        let now = CACurrentMediaTime()
        if recordStartElapsed == nil { recordStartElapsed = now }
        let elapsedSinceStart = now - (recordStartElapsed ?? now)

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

        // 600 timescale (NTSC/PAL-friendly LCM of 24/25/30).
        let pts = CMTime(seconds: elapsedSinceStart, preferredTimescale: 600)
        adaptor.append(pixelBuffer, withPresentationTime: pts)
    }

}
