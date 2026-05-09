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
            // .playAndRecord lets MicCapture later install a tap on
            // engine.inputNode for recording. .defaultToSpeaker keeps the
            // loud speakers as the default output route (otherwise the
            // category routes to the receiver-style speaker).
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.mixWithOthers, .defaultToSpeaker]
            )
            try session.setActive(true)
        } catch {
            P10Logger.log("[AudioEngine] AVAudioSession config failed: \(error)")
        }
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
