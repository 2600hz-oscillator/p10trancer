import Foundation
import AVFoundation

/// Audio diagnostic harness. Launched with `-AudioSelfTest YES` (or via
/// the URL scheme handler). Runs a fixed sequence of AVAudioSession +
/// AVAudioEngine experiments, captures the RMS at `mainMixerNode`'s
/// output bus, and writes a JSON report to
/// `Documents/audio-self-test.json`.
///
/// Pull from the iPad via:
///   xcrun devicectl device info files --device <udid> \
///     --domain-type appDataContainer --domain-identifier com.p10entrancer.app
///
/// Each `Probe` answers one question: "with this category + these
/// options, can we get audible PCM out of mainMixerNode?". A non-zero
/// RMS proves the engine is producing samples; the question of whether
/// they reach the speaker is then orthogonal (route inspection).
@MainActor
enum AudioSelfTest {

    static var isRequested: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-AudioSelfTest") || args.contains("--audio-self-test")
    }

    struct ProbeResult: Codable {
        let name: String
        let category: String
        let options: UInt
        let rms: Float
        let started: Bool
        let categoryAfter: String
        let routeOutputs: [String]
        let routeInputs: [String]
        let outputVolume: Float
        let sampleRate: Double
        let error: String?
    }

    struct Report: Codable {
        let device: String
        let osVersion: String
        let timestamp: String
        let probes: [ProbeResult]
    }

    static func runAndExit() async {
        let probes = [
            await runProbe(name: "playback_only",
                           category: .playback,
                           options: [.mixWithOthers]),
            await runProbe(name: "play_and_record_default_to_speaker",
                           category: .playAndRecord,
                           options: [.defaultToSpeaker]),
            await runProbe(name: "play_and_record_mix_with_others",
                           category: .playAndRecord,
                           options: [.defaultToSpeaker, .mixWithOthers]),
            // The big one: does AudioEngine.shared (the singleton the
            // app uses) actually produce audio? If this probe shows
            // RMS=0 while the fresh-engine probes show RMS=0.24, the
            // bug is in our app code, not the audio session config.
            await runSharedSingletonProbe(),
            // Same again, but with mic tap installed first — mirrors
            // the live app's startup sequence.
            await runSharedSingletonProbeWithMicTap(),
            // Verify reverting to .playback restores audibility.
            await runProbe(name: "playback_after_record",
                           category: .playback,
                           options: [.mixWithOthers])
        ]
        let report = Report(
            device: deviceModel(),
            osVersion: osVersion(),
            timestamp: ISO8601DateFormatter().string(from: Date()),
            probes: probes
        )
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("audio-self-test.json")
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(report).write(to: url)
            P10Logger.log("[AudioSelfTest] wrote \(url.lastPathComponent)")
        } catch {
            P10Logger.log("[AudioSelfTest] write failed: \(error)")
        }
        // Give the logger a moment to flush, then exit so an external
        // runner can sequence: launch → file pull → terminate.
        try? await Task.sleep(nanoseconds: 200_000_000)
        exit(0)
    }

    /// Configure the AVAudioSession for the requested category, build a
    /// fresh AVAudioEngine, schedule a 440 Hz sine, and measure RMS at
    /// mainMixerNode for ~0.5 s.
    private static func runProbe(
        name: String,
        category: AVAudioSession.Category,
        options: AVAudioSession.CategoryOptions
    ) async -> ProbeResult {
        let session = AVAudioSession.sharedInstance()
        var sessionError: String?
        do {
            try session.setCategory(category, mode: .default, options: options)
            try session.setActive(true, options: [])
        } catch {
            sessionError = "setCategory: \(error)"
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        engine.attach(player)
        engine.attach(mixer)

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        engine.connect(player, to: mixer, format: format)
        engine.connect(mixer, to: engine.mainMixerNode, format: nil)
        mixer.outputVolume = 1.0
        engine.mainMixerNode.outputVolume = 0.7

        let frames = AVAudioFrameCount(24_000) // 0.5s @ 48kHz
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let phaseStep = 2.0 * Float.pi * 440.0 / Float(format.sampleRate)
        for ch in 0..<Int(format.channelCount) {
            let p = buf.floatChannelData![ch]
            for i in 0..<Int(frames) { p[i] = 0.5 * sin(phaseStep * Float(i)) }
        }

        let lock = NSLock()
        var sumSquares: Double = 0
        var sampleCount: Int = 0
        let captureFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: captureFormat) { buffer, _ in
            guard let ch0 = buffer.floatChannelData?[0] else { return }
            var local: Double = 0
            let n = Int(buffer.frameLength)
            for i in 0..<n { local += Double(ch0[i] * ch0[i]) }
            lock.lock()
            sumSquares += local
            sampleCount += n
            lock.unlock()
        }

        var started = false
        var startError: String?
        do {
            try engine.start()
            started = true
        } catch {
            startError = "engine.start: \(error)"
        }

        if started {
            player.scheduleBuffer(buf, at: nil, options: [.loops], completionHandler: nil)
            player.play()
            try? await Task.sleep(nanoseconds: 600_000_000)
            player.stop()
        }
        engine.mainMixerNode.removeTap(onBus: 0)
        if started { engine.stop() }
        engine.detach(player)
        engine.detach(mixer)

        let rms: Float
        if sampleCount > 0 {
            rms = Float(sqrt(sumSquares / Double(sampleCount)))
        } else {
            rms = 0
        }

        let route = session.currentRoute
        let outs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }
        let ins = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }
        return ProbeResult(
            name: name,
            category: category.rawValue,
            options: options.rawValue,
            rms: rms,
            started: started,
            categoryAfter: session.category.rawValue,
            routeOutputs: outs,
            routeInputs: ins,
            outputVolume: session.outputVolume,
            sampleRate: session.sampleRate,
            error: [sessionError, startError].compactMap { $0 }.joined(separator: " | ").nilIfEmpty
        )
    }

    /// Probe using the singleton AudioEngine the app uses, not a fresh
    /// AVAudioEngine. Catches bugs where our startIfNeeded() leaves the
    /// engine in a state that produces silence even when the session
    /// config is fine.
    private static func runSharedSingletonProbe() async -> ProbeResult {
        await runSharedProbe(name: "shared_singleton_no_mic_tap", installMicTap: false)
    }

    private static func runSharedSingletonProbeWithMicTap() async -> ProbeResult {
        await runSharedProbe(name: "shared_singleton_with_mic_tap", installMicTap: true)
    }

    private static func runSharedProbe(name: String, installMicTap: Bool) async -> ProbeResult {
        let session = AVAudioSession.sharedInstance()
        AudioEngine.shared.startIfNeeded()
        AudioEngine.shared.masterVolume = 0.7
        let engine = AudioEngine.shared.engine

        // Optionally mirror the app's mic-tap install at boot so we can
        // see whether THAT is the silencer.
        if installMicTap {
            await MicCapture.shared.ensureRunning()
        }

        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        engine.attach(player)
        engine.attach(mixer)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        engine.connect(player, to: mixer, format: format)
        engine.connect(mixer, to: engine.mainMixerNode, format: nil)
        mixer.outputVolume = 1.0

        let frames = AVAudioFrameCount(24_000)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let phaseStep = 2.0 * Float.pi * 440.0 / Float(format.sampleRate)
        for ch in 0..<Int(format.channelCount) {
            let p = buf.floatChannelData![ch]
            for i in 0..<Int(frames) { p[i] = 0.5 * sin(phaseStep * Float(i)) }
        }

        let lock = NSLock()
        var sumSquares: Double = 0
        var sampleCount: Int = 0
        let captureFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: captureFormat) { buffer, _ in
            guard let ch0 = buffer.floatChannelData?[0] else { return }
            var local: Double = 0
            let n = Int(buffer.frameLength)
            for i in 0..<n { local += Double(ch0[i] * ch0[i]) }
            lock.lock()
            sumSquares += local
            sampleCount += n
            lock.unlock()
        }

        player.scheduleBuffer(buf, at: nil, options: [.loops], completionHandler: nil)
        player.play()
        try? await Task.sleep(nanoseconds: 600_000_000)
        player.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.detach(player)
        engine.detach(mixer)

        let rms: Float = sampleCount > 0
            ? Float(sqrt(sumSquares / Double(sampleCount)))
            : 0
        let route = session.currentRoute
        return ProbeResult(
            name: name,
            category: session.category.rawValue,
            options: session.categoryOptions.rawValue,
            rms: rms,
            started: engine.isRunning,
            categoryAfter: session.category.rawValue,
            routeOutputs: route.outputs.map { "\($0.portType.rawValue):\($0.portName)" },
            routeInputs: route.inputs.map { "\($0.portType.rawValue):\($0.portName)" },
            outputVolume: session.outputVolume,
            sampleRate: session.sampleRate,
            error: nil
        )
    }

    private static func deviceModel() -> String {
        var sys = utsname()
        uname(&sys)
        let mirror = Mirror(reflecting: sys.machine)
        var s = ""
        for child in mirror.children {
            if let v = child.value as? Int8, v != 0 {
                s.append(Character(UnicodeScalar(UInt8(v))))
            }
        }
        return s
    }

    private static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
