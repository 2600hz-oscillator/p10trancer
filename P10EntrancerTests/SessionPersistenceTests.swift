import XCTest
@testable import P10Entrancer

/// JSON round-trip tests for the instrument patch specs added to SessionSpec.
/// Guards against a field silently dropping out of session save/restore.
final class SessionPersistenceTests: XCTestCase {

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func test_acidbass_spec_roundtrips() throws {
        let spec = SessionSpec.ACIDBASSSpec(
            steps: [BassSequencer.Step(enabled: true, note: 38, accent: true, slide: false),
                    BassSequencer.Step(enabled: false, note: 41, accent: false, slide: true)],
            tune: 2, cutoff: 1234, resonance: 0.6, envMod: 0.7, decay: 420,
            accent: 0.55, waveform: 0.3, overdrive: 0.2, glide: 0.08,
            octave: 2, vizWarp: 1.5, vizHue: 0.25, vizZoom: 1.1)
        let r = try roundTrip(spec)
        XCTAssertEqual(r.steps, spec.steps)
        XCTAssertEqual(r.cutoff, 1234)
        XCTAssertEqual(r.steps[0].accent, true)
        XCTAssertEqual(r.octave, 2)
    }

    func test_multiplates_spec_roundtrips_including_nil_model() throws {
        let spec = SessionSpec.MultiplatesSpec(
            steps: [MultiplatesSequencer.Step(enabled: true, note: 48, model: 5),
                    MultiplatesSequencer.Step(enabled: true, note: 50, model: nil)],
            harmonics: 0.4, timbre: 0.6, morph: 0.2, level: 0.8,
            octave: 3, vizWarp: 1.0, vizHue: 0.2, vizZoom: 1.0)
        let r = try roundTrip(spec)
        XCTAssertEqual(r.steps[0].model, 5)
        XCTAssertNil(r.steps[1].model, "hold-last (nil) model must survive the round trip")
        XCTAssertEqual(r.level, 0.8)
    }

    func test_acidkick_spec_roundtrips() throws {
        let spec = SessionSpec.ACIDKICKSpec(
            tracks: [DrumSequencer.Track(voiceType: .snare,
                                         steps: (0..<16).map { $0 % 4 == 0 })],
            voiceParams: [[1.5, 0.8, 0.3]])
        let r = try roundTrip(spec)
        XCTAssertEqual(r.tracks[0].voiceType, .snare)
        XCTAssertEqual(r.tracks[0].steps[0], true)
        XCTAssertEqual(r.voiceParams[0], [1.5, 0.8, 0.3])
    }

    func test_wavetable_spec_roundtrips() throws {
        let spec = SessionSpec.WavetableInstSpec(
            steps: [StepSequencer.Step(enabled: true, note: 60)],
            tune: 7, fine: -12, morph: 0.5, spread: 2, fold: 0.1,
            attack: 0.01, decay: 0.2, sustain: 0.6, release: 0.4,
            filterCutoff: 5000, filterResonance: 0.3, filterMode: 2,
            reverbSize: 0.5, reverbDamp: 0.4, reverbWet: 0.2,
            octave: 4, wavetableLabel: "VOXSYNTH",
            vizZoom: 1, vizRotation: 0.2, vizColorCycle: 0.3)
        let r = try roundTrip(spec)
        XCTAssertEqual(r.filterMode, 2)
        XCTAssertEqual(r.wavetableLabel, "VOXSYNTH")
        XCTAssertEqual(r.tune, 7)
    }

    func test_padspec_without_instrument_fields_decodes() throws {
        // Pre-instrument-persistence PadSpec JSON has none of the new fields.
        let json = """
        {"index":0,"kind":"empty","fx":{"effects":[]}}
        """.data(using: .utf8)!
        let spec = try JSONDecoder().decode(SessionSpec.PadSpec.self, from: json)
        XCTAssertEqual(spec.kind, .empty)
        XCTAssertNil(spec.acidbass)
        XCTAssertNil(spec.fillMode)
    }
}
