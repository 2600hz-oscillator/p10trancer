import XCTest
import AVFoundation
@testable import P10Entrancer

/// End-to-end tests that exercise the full app's audio pipeline through
/// AppState — not isolated AVAudioEngine probes. Catches regressions
/// like "AppState boots but no audio reaches mainMixer", which the
/// fresh-engine probes in AudioSelfTest cannot see.
///
/// Device-only: simulator's AURemoteIO can't run AVAudioEngine.
@MainActor
final class AudioEndToEndTests: XCTestCase {

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// Replicates the live-app boot more faithfully: boot, then await
    /// MicCapture.ensureRunning (the live app's Task completes; the
    /// other tests' fire-and-forget often finishes before the tap
    /// actually installs). If installing the inputNode tap silences
    /// mainMixer, this test catches it.
    func test_audio_survives_mic_tap_install() async throws {
        try XCTSkipIf(Self.isSimulator, "device only")
        let app = AppState.shared
        app.startIfNeeded()
        // Force the mic tap to be in place before we measure.
        await MicCapture.shared.ensureRunning()
        app.mixer.ch1Source = ChannelSource.pad(0)
        app.mixer.ch2Source = ChannelSource.pad(1)
        app.applyAudioRouting()
        app.mixer.masterVolume = 0.8
        AudioEngine.shared.masterVolume = 0.8

        let until = Date().addingTimeInterval(0.5)
        while Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let rms = Self.measureMainMixerRMS(durationSeconds: 0.6)
        XCTAssertGreaterThan(rms, 0.001,
                             "mainMixer RMS=\(rms) after mic tap install — installing the inputNode tap silences playback")
    }

    /// The user's "no audio at all" complaint: boot the app, turn up
    /// the master, route the default pad — and assert that
    /// `mainMixerNode` actually produces audible PCM.
    func test_default_pads_produce_audio_after_boot_and_master_up() throws {
        try XCTSkipIf(Self.isSimulator,
                      "AVAudioEngine.start() aborts on simulator (AURemoteIO)")

        let app = AppState.shared
        app.startIfNeeded()

        // The default pads come from bundled clips. Force a known-good
        // routing so we don't depend on persisted session state.
        app.mixer.ch1Source = ChannelSource.pad(0)
        app.mixer.ch2Source = ChannelSource.pad(1)
        app.applyAudioRouting()

        // Push master up via the same path the slider uses. Tests the
        // wireMasterVolume sink + the direct setter both work.
        app.mixer.masterVolume = 0.8
        AudioEngine.shared.masterVolume = 0.8

        // Give Combine sinks + AVAudioFile loads time to settle, then
        // measure RMS at mainMixerNode for a fixed window.
        let until = Date().addingTimeInterval(0.5)
        while Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        let rms = Self.measureMainMixerRMS(durationSeconds: 0.6)
        XCTAssertGreaterThan(rms, 0.001,
                             "After boot + master up + routing, mainMixer RMS=\(rms) — audio is silent in the live app")
    }

    /// REC must NOT silence playback. Play a routed clip, hit record,
    /// confirm RMS at mainMixer is still non-zero during the recording.
    func test_record_does_not_silence_playback() throws {
        try XCTSkipIf(Self.isSimulator, "device only")
        let app = AppState.shared
        app.startIfNeeded()
        app.mixer.ch1Source = ChannelSource.pad(0)
        app.applyAudioRouting()
        app.mixer.masterVolume = 0.8
        AudioEngine.shared.masterVolume = 0.8

        // Settle.
        let settle = Date().addingTimeInterval(0.3)
        while Date() < settle { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

        app.recorder.start()
        defer { app.recorder.stop() }
        XCTAssertTrue(app.recorder.isRecording, "Recorder must be running")

        let rms = Self.measureMainMixerRMS(durationSeconds: 0.6)
        XCTAssertGreaterThan(rms, 0.001,
                             "RMS=\(rms) during REC — recording silenced playback")
    }

    /// Full loop: REC, save, drag the recorded file onto a pad, route
    /// it, confirm audio comes back from the new source. Catches the
    /// "recorded clip plays silent" regression.
    func test_record_then_drag_recording_onto_pad_plays_audio() throws {
        try XCTSkipIf(Self.isSimulator, "device only")
        let app = AppState.shared
        app.startIfNeeded()
        app.mixer.ch1Source = ChannelSource.pad(0)
        app.applyAudioRouting()
        app.mixer.masterVolume = 0.8
        AudioEngine.shared.masterVolume = 0.8

        let settle = Date().addingTimeInterval(0.3)
        while Date() < settle { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

        // Record ~1.5s.
        app.recorder.start()
        let recDuration = Date().addingTimeInterval(1.5)
        while Date() < recDuration { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        app.recorder.stop()

        // Wait for finishWriting (async).
        let writerWait = Date().addingTimeInterval(2.0)
        while Date() < writerWait, app.recorder.lastRecordingURL == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let url = try XCTUnwrap(app.recorder.lastRecordingURL,
                                "Recorder didn't expose a recording URL")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Recording file missing: \(url.path)")

        // Drag the recording onto pad 8 (last pad, unused by default).
        app.pads.setSource(VideoFileSource(url: url), at: 8)
        app.mixer.ch2Source = ChannelSource.pad(8)
        app.applyAudioRouting()

        // Settle (Combine + audio file load).
        let settle2 = Date().addingTimeInterval(0.5)
        while Date() < settle2 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

        let rms = Self.measureMainMixerRMS(durationSeconds: 0.6)
        XCTAssertGreaterThan(rms, 0.001,
                             "RMS=\(rms) after dragging recording to pad — recorded clip is silent")
    }

    // MARK: - Helpers

    /// Pull the RMS via AudioAppender's persistent-tap probe rather than
    /// installing our own tap — AVAudioEngine only allows one tap per
    /// bus and the recorder owns it for the app's lifetime. We sample
    /// across the window and return the max (peak RMS).
    private static func measureMainMixerRMS(durationSeconds: Double) -> Float {
        let appender = AppState.shared.recorder.audioAppender
        var peak: Float = 0
        let until = Date().addingTimeInterval(durationSeconds)
        while Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            peak = max(peak, appender.lastBufferRMS)
        }
        return peak
    }
}
