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

    /// AppState is a singleton — tests that mutate pad sources or
    /// channel routing leak state into other tests. Restore the bundled
    /// default pads before each test so order doesn't matter.
    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            let app = AppState.shared
            app.startIfNeeded()
            // Stop any in-flight recording from a prior test so the
            // recorder isn't holding writer/state.
            if app.recorder.isRecording { app.recorder.stop() }
            // Clear the mic queue so a backlog can't bleed across tests.
            MicCapture.shared.queue.clear()
            for i in 0..<PadSystem.padCount {
                if let url = Bundle.main.url(forResource: "pad\(i + 1)", withExtension: "mp4") {
                    app.pads.setSource(VideoFileSource(url: url), at: i)
                } else {
                    app.pads.setSource(nil, at: i)
                }
            }
            app.mixer.ch1Source = ChannelSource.pad(0)
            app.mixer.ch2Source = ChannelSource.pad(1)
            app.applyAudioRouting()
        }
        // Let the writer's async finishWriting and any audio buffers
        // queued from the previous test settle before this test begins.
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    /// Reassigning a pad from a routed video to another source must
    /// silence the old video's audio immediately. Without
    /// PadSystem.setSource explicitly muting the prior audioPlayer,
    /// SwiftUI views (PadFooterControls' @ObservedObject) keep the
    /// old VideoFileSource alive long enough that its audio player's
    /// mixerNode stays connected to mainMixer at non-zero volume —
    /// "I switched pad 4 to camera but I can still hear the clip".
    func test_reassigning_routed_pad_silences_old_audio() throws {
        try XCTSkipIf(Self.isSimulator, "device only")
        let app = AppState.shared
        app.startIfNeeded()
        // Empty every other pad so only pad 3 contributes audio. Pads
        // 0/1 are routed by default and would mask the regression.
        for i in 0..<PadSystem.padCount where i != 3 {
            app.pads.setSource(nil, at: i)
        }
        // Route both channels to pad 4 so no other pad is contributing.
        let url = try XCTUnwrap(Bundle.main.url(forResource: "pad4", withExtension: "mp4"),
                                "pad4.mp4 missing from bundle")
        app.pads.setSource(VideoFileSource(url: url), at: 3)
        app.mixer.ch1Source = ChannelSource.pad(3)
        app.mixer.ch2Source = ChannelSource.pad(3)
        app.applyAudioRouting()
        app.mixer.masterVolume = 0.8
        AudioEngine.shared.masterVolume = 0.8

        let settle = Date().addingTimeInterval(0.4)
        while Date() < settle { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let audibleRMS = Self.measureMainMixerRMS(durationSeconds: 0.4)
        XCTAssertGreaterThan(audibleRMS, 0.001, "Setup pre-condition: pad audio should be playing")

        // Replace pad 4's source with nil (simulates "swap to camera"
        // — camera audioPlayers default to volume=0). The old video's
        // audio must stop within a couple runloop ticks.
        app.pads.setSource(nil, at: 3)
        let settle2 = Date().addingTimeInterval(0.5)
        while Date() < settle2 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

        let silentRMS = Self.measureMainMixerRMS(durationSeconds: 0.4)
        XCTAssertLessThan(silentRMS, 0.005,
                          "RMS=\(silentRMS) after pad source swap — old clip's audio is still playing")
    }

    /// LiveRecordingsStore.generateThumbnail used to call the asset
    /// image generator with default (zero) tolerances — when video PTS
    /// stopped landing at exactly 0.1s (after the wall-clock PTS
    /// rewrite), the generator returned `.failed` and the row was
    /// stuck on a spinner forever. Inserting a known clip with
    /// arbitrary PTS verifies the loose tolerances we set unblock the
    /// generator.
    func test_thumbnail_generator_handles_arbitrary_video_pts() async throws {
        // This test runs on simulator + device — pure generator path,
        // no AVAudioEngine involved.
        let url = try XCTUnwrap(Bundle.main.url(forResource: "pad1", withExtension: "mp4"),
                                "pad1.mp4 missing from bundle")
        let store = LiveRecordingsStore(pads: PadSystem(), mixer: MixerState())
        store.insert(url: url)
        XCTAssertEqual(store.recent.count, 1, "Recording should be inserted")
        // Wait up to 3s for the async thumbnail to land.
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline, store.recent.first?.thumbnail == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(store.recent.first?.thumbnail,
                        "Thumbnail did not generate within 3s — generator tolerances likely broken")
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

    /// Replicates the user's actual flow: pad routed to a camera (mic
    /// source), volume slider raised, REC. Catches the stale-mic-gain
    /// regression where MicCapture.shared.recordGain stayed at 0
    /// because moving the per-pad mixer slider doesn't fire
    /// applyAudioRouting. With the micGainProvider hook in place,
    /// MixerRecorder.start() resolves the live gain itself.
    func test_camera_pad_with_volume_records_mic_audio() async throws {
        try XCTSkipIf(Self.isSimulator, "device only")
        let app = AppState.shared
        // Empty the default file pads so mainMixer is silent — that
        // way ANY audio in the recording is mic-sourced.
        for i in 0..<PadSystem.padCount { app.pads.setSource(nil, at: i) }
        app.mixer.masterVolume = 0.8
        AudioEngine.shared.masterVolume = 0.8

        // Stand up a camera-shaped pad. We don't actually need a live
        // AVCaptureSession — what matters is that the pad's audioPlayer
        // is the .mic kind and its volume is > 0, which is what the
        // gain provider keys on. We use a stub PadSource that exposes
        // a mic-typed PadAudioPlayer.
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw XCTSkip("no front camera on device")
        }
        guard let camera = CameraSource(device: device, label: "front-test") else {
            throw XCTSkip("CameraSource init failed")
        }
        app.pads.setSource(camera, at: 3)
        app.mixer.ch1Source = ChannelSource.pad(3)
        app.applyAudioRouting()
        // Move the mic slider — same path the user takes in the mixer.
        camera.audioPlayer.volume = 0.7

        // Make sure mic engine is running and mic permission has been
        // granted. AppState.startIfNeeded does this in setUp via the
        // boot flow.
        await MicCapture.shared.ensureRunning()
        let settle = Date().addingTimeInterval(0.6)
        while Date() < settle { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

        app.recorder.start()
        let recDuration = Date().addingTimeInterval(1.5)
        while Date() < recDuration { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        app.recorder.stop()

        let writerWait = Date().addingTimeInterval(2.0)
        while Date() < writerWait, app.recorder.lastRecordingURL == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let url = try XCTUnwrap(app.recorder.lastRecordingURL)
        let rms = try await Self.audioRMSOfFile(at: url)
        // Even a quiet room registers above 0.0001 due to the mic's
        // own noise floor + the input gain we applied. A truly silent
        // (mic-not-mixed) track would be exactly 0.
        XCTAssertGreaterThan(rms, 0.00001,
                             "Recording \(url.lastPathComponent) is silent (RMS=\(rms)) — mic was not mixed in. micGainProvider may be returning 0 or setMicMix is off.")
    }

    /// Stronger version: read audio samples directly out of the
    /// recorded file with AVAssetReader, confirm the track is non-empty
    /// and non-silent. The mainMixer-RMS approach below can mask a
    /// silent recording because other pads (default ch2 etc) still
    /// contribute audio.
    /// AV sync regression: first audio sample's PTS and first video
    /// frame's PTS in the recorded file must be within 50ms — that's
    /// the perceptibility threshold for AV-sync issues. Without the
    /// firstSamplePTSSec offset, audio first PTS was 0 while video
    /// first PTS was ~16ms, leaving the audio capture at wall_time+85ms
    /// ahead of where it should have been (substantial perceptible lag).
    func test_recording_audio_and_video_first_pts_within_50ms() async throws {
        try XCTSkipIf(Self.isSimulator, "device only")
        let app = AppState.shared
        app.mixer.ch1Source = ChannelSource.pad(0)
        app.applyAudioRouting()
        app.mixer.masterVolume = 0.8
        AudioEngine.shared.masterVolume = 0.8
        let settle = Date().addingTimeInterval(0.4)
        while Date() < settle { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

        app.recorder.start()
        let recDuration = Date().addingTimeInterval(1.5)
        while Date() < recDuration { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        app.recorder.stop()
        let writerWait = Date().addingTimeInterval(2.0)
        while Date() < writerWait, app.recorder.lastRecordingURL == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let url = try XCTUnwrap(app.recorder.lastRecordingURL)
        let asset = AVURLAsset(url: url)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            XCTFail("no audio track"); return
        }
        let audioFirstPTS = try await firstSamplePTS(of: audioTrack, in: asset)

        // Tests run without an active CADisplayLink, so the recorder
        // may not capture any video frames — check defensively.
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first,
              let videoFirstPTS = try? await firstSamplePTS(of: videoTrack, in: asset) else {
            // No video to compare against; just verify audio PTS is
            // a reasonable real-time offset (< 250ms after REC).
            XCTAssertLessThan(audioFirstPTS, 0.25,
                              "Audio first PTS=\(audioFirstPTS)s — should be a small real-time offset from REC")
            return
        }

        let delta = abs(audioFirstPTS - videoFirstPTS)
        XCTAssertLessThan(delta, 0.05,
                          "AV sync: audio first PTS=\(audioFirstPTS)s, video first PTS=\(videoFirstPTS)s, delta=\(delta)s exceeds 50ms threshold")
    }

    /// Returns the start of the track's media time range. This is what
    /// the player uses to align tracks during playback — distinct from
    /// the first sample's decoded PTS via AVAssetReader, which can be
    /// later in the GOP.
    private func firstSamplePTS(of track: AVAssetTrack, in asset: AVAsset) async throws -> Double {
        let timeRange = try await track.load(.timeRange)
        return CMTimeGetSeconds(timeRange.start)
    }

    func test_recording_file_contains_actual_audio() async throws {
        try XCTSkipIf(Self.isSimulator, "device only")
        let app = AppState.shared
        app.mixer.ch1Source = ChannelSource.pad(0)
        app.applyAudioRouting()
        app.mixer.masterVolume = 0.8
        AudioEngine.shared.masterVolume = 0.8
        let settle = Date().addingTimeInterval(0.4)
        while Date() < settle { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

        app.recorder.start()
        let recDuration = Date().addingTimeInterval(1.5)
        while Date() < recDuration { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        app.recorder.stop()
        let writerWait = Date().addingTimeInterval(2.0)
        while Date() < writerWait, app.recorder.lastRecordingURL == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let url = try XCTUnwrap(app.recorder.lastRecordingURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let rms = try await Self.audioRMSOfFile(at: url)
        XCTAssertGreaterThan(rms, 0.001,
                             "Recording \(url.lastPathComponent) audio track is silent (RMS=\(rms))")
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
    /// Read the audio track of a recorded file and return its RMS.
    /// Throws if there's no audio track. Returns 0 if the track is
    /// fully silent (every sample == 0). Used by the camera-pad and
    /// general "did the recording capture audio" tests.
    static func audioRMSOfFile(at url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            XCTFail("Recording \(url.lastPathComponent) has no audio track"); return 0
        }
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)
        guard reader.startReading() else {
            XCTFail("AVAssetReader didn't start: \(String(describing: reader.error))"); return 0
        }
        var totalSamples: Int = 0
        var sumSquares: Double = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var lengthAtOffset: Int = 0
            var totalLength: Int = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                        totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
            guard let dp = dataPointer else { continue }
            dp.withMemoryRebound(to: Int16.self, capacity: totalLength / 2) { ptr in
                let sampleCount = totalLength / 2
                for i in 0..<sampleCount {
                    let v = Double(ptr[i]) / 32768.0
                    sumSquares += v * v
                }
                totalSamples += sampleCount
            }
        }
        guard totalSamples > 0 else { return 0 }
        return sqrt(sumSquares / Double(totalSamples))
    }

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
