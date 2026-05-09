import XCTest
import AVFoundation
@testable import P10Entrancer

/// Integration tests for the audio session + AVAudioEngine pipeline.
/// State-machine assertions run everywhere; tests that need a working
/// audio HAL (engine.start() that doesn't abort) are gated to device.
@MainActor
final class AudioEngineIntegrationTests: XCTestCase {

    // MARK: - Sim + device

    /// Regression for the silent-during-REC bug: enable/disable must NOT
    /// touch AVAudioSession (any mid-flight category swap silenced
    /// playback on iPadOS 26).
    func test_enable_record_category_is_a_noop() {
        let s = AVAudioSession.sharedInstance()
        let before = s.category
        AudioEngine.shared.enableRecordCategory()
        XCTAssertEqual(s.category, before,
                       "enableRecordCategory must not mutate AVAudioSession")
    }

    func test_disable_record_category_is_a_noop() {
        let s = AVAudioSession.sharedInstance()
        let before = s.category
        AudioEngine.shared.disableRecordCategory()
        XCTAssertEqual(s.category, before,
                       "disableRecordCategory must not mutate AVAudioSession")
    }

    // MARK: - Device only (simulator's AURemoteIO can't initialize)

    /// Boot the singleton AudioEngine in `.playAndRecord` and prove that
    /// scheduled audio actually flows through `mainMixerNode`. Catches
    /// any regression where category options or the engine startup
    /// sequence silently mutes the bus. Skipped on simulator.
    func test_engine_produces_audio_in_play_and_record() throws {
        try XCTSkipIf(Self.isSimulator,
                      "AVAudioEngine.start() aborts on simulator (AURemoteIO)")

        AudioEngine.shared.startIfNeeded()
        let s = AVAudioSession.sharedInstance()
        XCTAssertEqual(s.category, .playAndRecord,
                       "Boot must leave session in .playAndRecord")
        XCTAssertTrue(AudioEngine.shared.engine.isRunning, "Engine must be running")
        AudioEngine.shared.masterVolume = 0.7

        let rms = try Self.measureMainMixerRMS(durationSeconds: 0.6)
        XCTAssertGreaterThan(rms, 0.01,
                             "mainMixerNode must produce audible samples; got RMS=\(rms)")
    }

    // MARK: - Helpers

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// Schedule a 440 Hz sine on a fresh player → mixer → mainMixer
    /// chain in the singleton engine, tap mainMixer's output, and
    /// return the average RMS over the captured window.
    static func measureMainMixerRMS(durationSeconds: Double) throws -> Float {
        let engine = AudioEngine.shared.engine
        let mainMixer = engine.mainMixerNode

        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        engine.attach(player)
        engine.attach(mixer)

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        engine.connect(player, to: mixer, format: format)
        engine.connect(mixer, to: mainMixer, format: nil)
        mixer.outputVolume = 1.0

        let frames = AVAudioFrameCount(format.sampleRate * 0.5)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            XCTFail("PCM buffer alloc failed"); return 0
        }
        buf.frameLength = frames
        let phaseStep = 2.0 * Float.pi * 440.0 / Float(format.sampleRate)
        for ch in 0..<Int(format.channelCount) {
            let p = buf.floatChannelData![ch]
            for i in 0..<Int(frames) { p[i] = 0.5 * sin(phaseStep * Float(i)) }
        }

        let lock = NSLock()
        var sumSquares: Double = 0
        var sampleCount: Int = 0
        let captureFormat = mainMixer.outputFormat(forBus: 0)
        mainMixer.installTap(onBus: 0, bufferSize: 4096, format: captureFormat) { buffer, _ in
            guard let ch0 = buffer.floatChannelData?[0] else { return }
            var local: Double = 0
            let n = Int(buffer.frameLength)
            for i in 0..<n { local += Double(ch0[i] * ch0[i]) }
            lock.lock()
            sumSquares += local
            sampleCount += n
            lock.unlock()
        }

        if !engine.isRunning { try engine.start() }
        player.scheduleBuffer(buf, at: nil, options: [.loops], completionHandler: nil)
        player.play()

        let until = Date().addingTimeInterval(durationSeconds)
        while Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        player.stop()
        mainMixer.removeTap(onBus: 0)
        engine.detach(player)
        engine.detach(mixer)

        guard sampleCount > 0 else { return 0 }
        return Float(sqrt(sumSquares / Double(sampleCount)))
    }
}
