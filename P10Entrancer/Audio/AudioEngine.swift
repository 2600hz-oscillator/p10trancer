import Foundation
import AVFoundation

@MainActor
final class AudioEngine {
    static let shared = AudioEngine()

    let engine = AVAudioEngine()
    private var started = false

    private init() {}

    var masterVolume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    func startIfNeeded() {
        guard !started else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            P10Logger.log("[AudioEngine] AVAudioSession config failed: \(error)")
        }
        // Touch mainMixerNode before start() so the engine creates its output node graph;
        // start() asserts otherwise on a fresh engine with no attached nodes.
        engine.mainMixerNode.outputVolume = 0.7
        do {
            try engine.start()
            started = true
            P10Logger.log("[AudioEngine] running, master volume = 0.7")
        } catch {
            P10Logger.log("[AudioEngine] engine start failed: \(error)")
        }
    }
}
