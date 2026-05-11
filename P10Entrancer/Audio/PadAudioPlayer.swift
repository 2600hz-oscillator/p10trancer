import Foundation
import AVFoundation
import Combine

/// Per-pad audio output strip. Two source kinds: a video file's looping audio
/// (for VideoFileSource) and the iPad mic (for camera sources). The
/// downstream is the same: a private AVAudioMixerNode whose outputVolume
/// gates the pad's contribution to the master mix; routed=false zeros it.
@MainActor
final class PadAudioPlayer: ObservableObject {
    enum Source {
        case file(URL)
        case mic
    }

    private let engine: AVAudioEngine
    private let source: Source
    private let label: String

    private let mixerNode = AVAudioMixerNode()
    private let playerNode = AVAudioPlayerNode()  // unused for .mic
    private var buffer: AVAudioPCMBuffer?
    private var attachedFile = false
    private var attachedMic = false

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
        case .file: self.volume = 0.7
        case .mic:  self.volume = 0
        }
        switch source {
        case .file(let url):
            Task { await self.loadFile(url: url) }
        case .mic:
            Task { await self.loadMic() }
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
        guard case .file = source, attachedFile else { return }
        if playing {
            if !playerNode.isPlaying { playerNode.play() }
        } else {
            playerNode.pause()
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
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                P10Logger.log("[PadAudioPlayer:\(label)] could not allocate buffer")
                return
            }
            try file.read(into: buf)
            self.buffer = buf

            engine.attach(playerNode)
            engine.attach(mixerNode)
            engine.connect(playerNode, to: mixerNode, format: format)
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

            playerNode.scheduleBuffer(buf, at: nil, options: .loops, completionCallbackType: .dataPlayedBack) { _ in }
            playerNode.play()
            P10Logger.log("[PadAudioPlayer:\(label)] file loop frames=\(frameCount), default user vol \(volume)")
        } catch {
            P10Logger.log("[PadAudioPlayer:\(label)] load failed: \(error)")
        }
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
