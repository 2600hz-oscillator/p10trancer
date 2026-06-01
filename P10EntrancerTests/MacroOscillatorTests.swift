import XCTest
@testable import P10Entrancer

/// Sanity tests for the 14-model MacroOscillator port. The main porting risk
/// is NaN/Inf or runaway feedback, so every model is rendered and checked for
/// finite, bounded output; tonal/percussive models are also checked for signal.
final class MacroOscillatorTests: XCTestCase {
    let sr = 48000.0

    private func render(model: MacroModel, seconds: Double,
                        h: Double = 0.5, t: Double = 0.5, m: Double = 0.5) -> (peak: Double, finite: Bool) {
        let v = MacroVoice(sampleRate: sr)
        v.harmonics = h; v.timbre = t; v.morph = m; v.level = 0.8
        v.noteOn(midiNote: 57, model: model)   // A3
        var peak = 0.0
        var finite = true
        for _ in 0..<Int(seconds * sr) {
            let s = v.nextSample()
            if !s.isFinite { finite = false; break }
            peak = max(peak, abs(s))
        }
        return (peak, finite)
    }

    func test_all_models_finite_and_bounded() {
        for model in MacroModel.allCases {
            let r = render(model: model, seconds: 0.3)
            XCTAssertTrue(r.finite, "\(model.displayName) produced non-finite output")
            XCTAssertLessThan(r.peak, 8.0, "\(model.displayName) output is unreasonably hot (\(r.peak))")
        }
    }

    func test_tonal_models_produce_signal() {
        // Tonal/voiced models should make sound. 0.4s so MODAL gets at least
        // one of its internal 4 Hz excitation impulses (first at ~0.25s).
        for model in [MacroModel.va, .waveshape, .fm2op, .fm6op, .chord,
                      .additive, .modal, .wavetable, .granular, .speech] {
            let r = render(model: model, seconds: 0.4)
            XCTAssertGreaterThan(r.peak, 0.001, "\(model.displayName) was silent")
        }
    }

    func test_percussion_models_fire_on_gate() {
        // Drum/plucked engines re-excite on noteOn and should produce a hit.
        for model in [MacroModel.kick, .snare, .hihat, .string] {
            let r = render(model: model, seconds: 0.15)
            XCTAssertGreaterThan(r.peak, 0.001, "\(model.displayName) produced no hit on gate")
        }
    }

    func test_model_count_matches_enum() {
        XCTAssertEqual(MacroModel.allCases.count, 14)
        XCTAssertEqual(MacroModel.speech.rawValue, 13)
    }
}
