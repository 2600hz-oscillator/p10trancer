import Foundation
import AVFoundation
import Combine

@MainActor
final class PadAudioPlayer: ObservableObject {
    private let engine: AVAudioEngine
    private let playerNode = AVAudioPlayerNode()
    private let mixerNode = AVAudioMixerNode()
    private var buffer: AVAudioPCMBuffer?
    private let label: String
    private var attached = false

    /// User-set volume (0…1). Published so SwiftUI sliders re-render when MIDI
    /// or any other external source changes the value.
    @Published var volume: Float = 0.7 {
        didSet { applyEffectiveVolume() }
    }
    private var isRouted: Bool = false

    init(url: URL, label: String, engine: AVAudioEngine = AudioEngine.shared.engine) {
        self.engine = engine
        self.label = label
        Task {
            await self.load(url: url)
        }
    }

    deinit {
        if attached {
            playerNode.stop()
            engine.detach(playerNode)
            engine.detach(mixerNode)
        }
    }

    /// Set by the audio router based on whether this pad is currently in CH1 or CH2.
    func setRouted(_ routed: Bool) {
        isRouted = routed
        applyEffectiveVolume()
    }

    private func applyEffectiveVolume() {
        mixerNode.outputVolume = isRouted ? volume : 0.0
    }

    private func load(url: URL) async {
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
            attached = true

            playerNode.scheduleBuffer(buf, at: nil, options: .loops, completionCallbackType: .dataPlayedBack) { _ in }
            playerNode.play()
            P10Logger.log("[PadAudioPlayer:\(label)] looping, frames=\(frameCount), default user vol \(volume)")
        } catch {
            P10Logger.log("[PadAudioPlayer:\(label)] load failed: \(error)")
        }
    }
}
