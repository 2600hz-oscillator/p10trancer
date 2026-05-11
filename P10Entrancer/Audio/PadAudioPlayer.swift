import Foundation
import AVFoundation
import Combine

/// Common surface for any stereo source we want to plug into a per-pad
/// audio strip (PadAudioPlayer.Source.synth / .drumMachine). Render
/// implementations run on the audio thread; conform `@unchecked
/// Sendable` for the closure capture.
protocol PadStereoRenderer: AnyObject {
    func renderStereoBlock(left: UnsafeMutablePointer<Float>,
                            right: UnsafeMutablePointer<Float>,
                            count: Int,
                            sampleRate: Double)
}

/// Per-pad audio output strip. Two source kinds: a video file's looping audio
/// (for VideoFileSource) and the iPad mic (for camera sources). The
/// downstream is the same: a private AVAudioMixerNode whose outputVolume
/// gates the pad's contribution to the master mix; routed=false zeros it.
@MainActor
final class PadAudioPlayer: ObservableObject {
    enum Source {
        case file(URL)
        case mic
        /// Real-time synth source. The renderer is called from an
        /// AVAudioSourceNode block on the audio thread to fill
        /// stereo sample buffers. Used by InstrumentSource for the
        /// WAVECEL wavetable synth + ADSR path.
        case synth(WaveCelSynthRenderer)
        /// ACIDKICK drum-machine stereo renderer.
        case drumMachine(ACIDKICKRenderer)
    }

    private let engine: AVAudioEngine
    private let source: Source
    private let label: String

    private let mixerNode = AVAudioMixerNode()
    private let playerNode = AVAudioPlayerNode()  // unused for .mic
    /// Sits between playerNode and mixerNode for file pads. Driving
    /// its `rate` makes the audio speed/pitch follow the video's
    /// AVPlayer rate (tape-style: pitch tracks speed).
    private let varispeed = AVAudioUnitVarispeed()
    private var buffer: AVAudioPCMBuffer?
    private var audioFile: AVAudioFile?
    private var fileFrameCount: AVAudioFramePosition = 0
    /// Loop region in audio frames, matching the video's trim
    /// region. Recomputed whenever the host VideoFileSource changes
    /// trim points. The player node loops within this window using
    /// scheduleSegment + completion-callback chaining.
    private var loopStartFrame: AVAudioFramePosition = 0
    private var loopEndFrame: AVAudioFramePosition = 0
    /// Cache of params set before the file finished loading; applied
    /// when loadFile completes so VideoFileSource can configure
    /// trim/rate at init time without races.
    private var pendingRate: Float = 1.0
    private var pendingLoopStartNorm: Double = 0
    private var pendingLoopEndNorm: Double = 1
    private var isFilePlaying: Bool = true
    private var attachedFile = false
    private var attachedMic = false
    private var attachedSynth = false
    private var synthSourceNode: AVAudioSourceNode?

    /// Default mic gain is 0 to avoid speaker→mic feedback the moment the
    /// user routes a camera pad. File pads still default to 0.7.
    @Published var volume: Float {
        didSet { applyEffectiveVolume() }
    }
    /// Latest RMS of this pad's per-pad mixer node output — post-pad
    /// volume + mute, BEFORE the master fader. Drives the channel VU
    /// meters in the side strips so they bounce with content even
    /// when the master is turned down or muted.
    @Published private(set) var instantRMS: Float = 0
    /// Per-pad mute that overrides the mixer routing — when true, the
    /// pad contributes 0 to mainMixer regardless of channel routing or
    /// volume slider position. Toggled by the mute button on each pad
    /// and by MIDI mute events for project recall.
    @Published var isMuted: Bool = false {
        didSet { applyEffectiveVolume() }
    }
    private var isRouted: Bool = false

    init(source: Source, label: String, engine: AVAudioEngine = AudioEngine.shared.engine) {
        self.engine = engine
        self.source = source
        self.label = label
        switch source {
        case .file:        self.volume = 0.7
        case .mic:         self.volume = 0
        case .synth:       self.volume = 0.7
        case .drumMachine: self.volume = 0.7
        }
        switch source {
        case .file(let url):
            Task { await self.loadFile(url: url) }
        case .mic:
            Task { await self.loadMic() }
        case .synth(let renderer):
            loadSynth(renderer: renderer)
        case .drumMachine(let renderer):
            loadStereoRenderer(renderer)
        }
    }

    deinit {
        // We stop the player but deliberately do NOT detach the nodes from
        // the engine. Detaching a node that's connected to mainMixerNode
        // reliably throws inside AVAudioEngineGraph::UpdateGraphAfterReconfig
        // on iPadOS 26 — see crash log P10Entrancer-2026-05-09-111210.ips.
        // The leak is two AVAudioNodes per pad-source change; the engine's
        // mainMixer accepts unlimited inputs, and the mute-via-outputVolume
        // path keeps stale players silent. Accept the leak for stability.
        guard attachedFile else { return }
        let player = playerNode
        let mixer = mixerNode
        Task { @MainActor in
            player.stop()
            mixer.outputVolume = 0
        }
    }

    func setRouted(_ routed: Bool) {
        isRouted = routed
        applyEffectiveVolume()
    }

    /// Pause/resume the file's audio playback. No-op for `.mic` source
    /// (the mic engine isn't gated by per-pad play state).
    func setPlaying(_ playing: Bool) {
        guard case .file = source else { return }
        isFilePlaying = playing
        guard attachedFile else { return }
        if playing {
            if !playerNode.isPlaying { playerNode.play() }
        } else {
            playerNode.pause()
        }
    }

    /// Mirror the host VideoFileSource's playback rate. Uses
    /// AVAudioUnitVarispeed so pitch tracks speed (tape-style).
    /// Clamped to the slider's 0.1×–4× range.
    func setRate(_ rate: Float) {
        let r = max(0.1, min(4.0, rate))
        pendingRate = r
        if attachedFile { varispeed.rate = r }
    }

    /// Mirror the host's trim region. The audio loops within this
    /// fraction of the file [0..1]. Deliberately does NOT reschedule
    /// the current segment — the trim brackets fire setLoopRegion
    /// continuously while dragged, and restarting the player on
    /// every drag tick would chop the audio into fragments. Instead
    /// the currently-playing segment runs to its old end, then the
    /// completion callback picks up the new bounds. Audio settles
    /// into the new region within one loop iteration.
    func setLoopRegion(startNormalized: Double, endNormalized: Double) {
        pendingLoopStartNorm = startNormalized
        pendingLoopEndNorm = endNormalized
        guard attachedFile, fileFrameCount > 0 else { return }
        let s = AVAudioFramePosition(Double(fileFrameCount) * startNormalized)
        let e = AVAudioFramePosition(Double(fileFrameCount) * endNormalized)
        loopStartFrame = max(0, min(s, fileFrameCount - 1))
        loopEndFrame = max(loopStartFrame + 1, min(e, fileFrameCount))
    }

    /// Move the audio playhead to a fraction [0..1] of the full file
    /// duration. Called from VideoFileSource.seek so audio re-anchors
    /// when the user scrubs.
    func seekToFraction(_ t: Double) {
        guard attachedFile, fileFrameCount > 0 else { return }
        let frame = AVAudioFramePosition(Double(fileFrameCount) * t)
        let clamped = max(loopStartFrame, min(frame, loopEndFrame - 1))
        rescheduleFrom(clamped)
    }

    /// Stops the player node (which clears any pending segments),
    /// schedules a fresh segment from `frame` to `loopEndFrame`, and
    /// resumes playback if the pad is currently playing. The
    /// completion callback chain takes it from there.
    private func rescheduleFrom(_ frame: AVAudioFramePosition) {
        guard attachedFile, audioFile != nil else { return }
        playerNode.stop()
        scheduleLoopSegment(fromFrame: frame)
        if isFilePlaying { playerNode.play() }
    }

    /// Schedules one segment from `startFrame` → `loopEndFrame`. On
    /// completion the callback re-arms the next segment starting at
    /// `loopStartFrame`, producing an indefinite trim-respecting
    /// loop without buffer-loading overhead.
    private func scheduleLoopSegment(fromFrame startFrame: AVAudioFramePosition) {
        guard let file = audioFile else { return }
        let segStart = max(loopStartFrame, min(startFrame, loopEndFrame - 1))
        let segLength = AVAudioFrameCount(max(1, loopEndFrame - segStart))
        playerNode.scheduleSegment(file,
                                    startingFrame: segStart,
                                    frameCount: segLength,
                                    at: nil,
                                    completionCallbackType: .dataPlayedBack) { [weak self] type in
            guard type == .dataPlayedBack else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleLoopSegment(fromFrame: self.loopStartFrame)
            }
        }
    }

    private func applyEffectiveVolume() {
        mixerNode.outputVolume = (isMuted || !isRouted) ? 0.0 : volume
    }

    // MARK: - Source-specific setup

    private func loadFile(url: URL) async {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard frameCount > 0 else {
                P10Logger.log("[PadAudioPlayer:\(label)] no audio frames")
                return
            }
            self.audioFile = file
            self.fileFrameCount = file.length
            self.loopStartFrame = 0
            self.loopEndFrame = file.length

            engine.attach(playerNode)
            engine.attach(varispeed)
            engine.attach(mixerNode)
            engine.connect(playerNode, to: varispeed, format: format)
            engine.connect(varispeed, to: mixerNode, format: format)
            engine.connect(mixerNode, to: engine.mainMixerNode, format: nil)
            // VU tap on the per-pad mixer: post pad-volume + pad-mute,
            // pre-master. Lets the channel VU bounce with content
            // regardless of master fader position.
            mixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
                guard let ch0 = buffer.floatChannelData?[0] else { return }
                var sum: Float = 0
                let n = Int(buffer.frameLength)
                for i in 0..<n { sum += ch0[i] * ch0[i] }
                let rms = sqrtf(sum / Float(max(1, n)))
                Task { @MainActor [weak self] in self?.instantRMS = rms }
            }
            applyEffectiveVolume()
            attachedFile = true

            // Apply any rate/trim values the host set before loadFile
            // completed (VideoFileSource may have already pushed
            // defaults during its async start). After bounds are
            // set, kick off the loop chain.
            varispeed.rate = pendingRate
            setLoopRegion(startNormalized: pendingLoopStartNorm,
                          endNormalized: pendingLoopEndNorm)
            scheduleLoopSegment(fromFrame: loopStartFrame)
            if isFilePlaying { playerNode.play() }
            P10Logger.log("[PadAudioPlayer:\(label)] file loop frames=\(frameCount), default user vol \(volume)")
        } catch {
            P10Logger.log("[PadAudioPlayer:\(label)] load failed: \(error)")
        }
    }

    /// Attach a stereo AVAudioSourceNode driven by the WAVECEL synth
    /// renderer. Thin wrapper over loadStereoRenderer.
    private func loadSynth(renderer: WaveCelSynthRenderer) {
        loadStereoRenderer(renderer)
    }

    /// Attach a stereo AVAudioSourceNode whose render block delegates
    /// to any conforming PadStereoRenderer. Both the WAVECEL
    /// wavetable synth and the ACIDKICK drum machine plug in here so
    /// they share the per-pad mixerNode (volume / mute / VU tap).
    private func loadStereoRenderer(_ renderer: PadStereoRenderer) {
        let outFmt = engine.outputNode.outputFormat(forBus: 0)
        let sr = outFmt.sampleRate > 0 ? outFmt.sampleRate : 48000
        guard let stereoFmt = AVAudioFormat(standardFormatWithSampleRate: sr,
                                            channels: 2) else {
            P10Logger.log("[PadAudioPlayer:\(label)] stereo fmt failed")
            return
        }
        let node = AVAudioSourceNode(format: stereoFmt) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let lPtr = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let rPtr = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            renderer.renderStereoBlock(left: lPtr, right: rPtr,
                                       count: Int(frameCount),
                                       sampleRate: sr)
            return noErr
        }
        self.synthSourceNode = node
        engine.attach(node)
        engine.attach(mixerNode)
        engine.connect(node, to: mixerNode, format: stereoFmt)
        engine.connect(mixerNode, to: engine.mainMixerNode, format: nil)
        mixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let ch0 = buffer.floatChannelData?[0] else { return }
            var sum: Float = 0
            let n = Int(buffer.frameLength)
            for i in 0..<n { sum += ch0[i] * ch0[i] }
            let rms = sqrtf(sum / Float(max(1, n)))
            Task { @MainActor [weak self] in self?.instantRMS = rms }
        }
        applyEffectiveVolume()
        attachedSynth = true
        P10Logger.log("[PadAudioPlayer:\(label)] stereo renderer attached, sr=\(sr)")
    }

    private func loadMic() async {
        // No-op stub. Mic capture lives entirely inside MixerRecorder /
        // MicCapture as a tap-based path; this PadAudioPlayer instance
        // exists only so the camera pad has an ObservableObject for the
        // mixer panel slider. Volume here drives MicCapture.cameraGain
        // via AppState.applyAudioRouting → see that for the wiring.
        P10Logger.log("[PadAudioPlayer:\(label)] mic stub (capture lives in MicCapture)")
    }
}
