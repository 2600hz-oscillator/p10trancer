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
            // .playAndRecord with .defaultToSpeaker — verified by the
            // AudioSelfTest harness to produce audio at RMS 0.24 on the
            // built-in speaker. Earlier "silent" reports were the
            // master-volume propagation bug, not the category itself.
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .mixWithOthers]
            )
            try session.setActive(true)
        } catch {
            P10Logger.log("[AudioEngine] AVAudioSession config failed: \(error)")
        }
        engine.mainMixerNode.outputVolume = 0.7
        do {
            try engine.start()
            started = true
            P10Logger.log("[AudioEngine] running (.playAndRecord), masterVolume=0.7")
            logSessionState(tag: "after engine start")
        } catch {
            P10Logger.log("[AudioEngine] engine start failed: \(error)")
        }
    }

    /// No-op shim. Mic capture requires `.playAndRecord`, which silences
    /// playback on this iPad — so until we have a working strategy, REC
    /// records audio from the engine's main mixer (per-pad audio is
    /// captured) but the iPad mic is NOT in the recording. See the
    /// audio-self-test harness for the experiments that will let us
    /// re-enable mic without breaking playback.
    func enableRecordCategory() {}
    func disableRecordCategory() {}

    /// Log enough of AVAudioSession state to tell whether the system
    /// thinks audio should be audible. Called after every config change
    /// so the device console shows the route + volume.
    func logSessionState(tag: String) {
        let s = AVAudioSession.sharedInstance()
        let route = s.currentRoute
        let outs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let ins = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        P10Logger.log("[AudioEngine][\(tag)] cat=\(s.category.rawValue) outVol=\(s.outputVolume) sr=\(s.sampleRate) ch=\(s.outputNumberOfChannels) outs=[\(outs)] ins=[\(ins)] otherPlaying=\(s.isOtherAudioPlaying)")
    }
}
