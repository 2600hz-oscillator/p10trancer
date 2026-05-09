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
        if attachedFile {
            playerNode.stop()
            engine.detach(playerNode)
            engine.detach(mixerNode)
        }
        // Mic taps deliberately not torn down here — would need to hop to
        // MainActor and run disconnect through MicCapture. The leak is
        // small (one detached mixer node per camera-source lifecycle) and
        // doesn't affect playback.
    }

    func setRouted(_ routed: Bool) {
        isRouted = routed
        applyEffectiveVolume()
    }

    private func applyEffectiveVolume() {
        mixerNode.outputVolume = isRouted ? volume : 0.0
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
