import XCTest
@testable import P10Entrancer

/// Acceptance tests for the TB303Voice DSP port, replicating the invariants
/// pinned by inet.modular's treeohvox-dsp.test.ts so we know the Swift port
/// matches the TreeOhVox/Open303 reference.
final class TB303VoiceTests: XCTestCase {

    let sr = 48000.0

    // MARK: - Pure math invariants

    func test_pitchCvToFreq_0V_is_C4() {
        XCTAssertEqual(tb303PitchCvToFreq(0, 0), 261.6255653005986, accuracy: 1e-9)
    }

    func test_pitchCvToFreq_one_octave_per_volt() {
        XCTAssertEqual(tb303PitchCvToFreq(1, 0), 2 * kTB303_C4_HZ, accuracy: 1e-6)
        // +12 semitones tune == +1 octave.
        XCTAssertEqual(tb303PitchCvToFreq(0, 12), 2 * kTB303_C4_HZ, accuracy: 1e-6)
    }

    func test_resonanceSkew_reference_points() {
        XCTAssertEqual(tb303ResonanceSkew(0), 0, accuracy: 1e-9)
        XCTAssertEqual(tb303ResonanceSkew(1), 1, accuracy: 1e-9)
        // The canonical pinned value from the reference test.
        XCTAssertEqual(tb303ResonanceSkew(0.5), 0.8176, accuracy: 1e-4)
    }

    func test_envModScaler_grows_with_envMod() {
        let lo = tb303EnvModScalerOffset(cutoffHz: 800, envModPercent: 10)
        let hi = tb303EnvModScalerOffset(cutoffHz: 800, envModPercent: 90)
        XCTAssertGreaterThan(hi.scaler, lo.scaler,
            "more env mod must open the filter more (bigger scaler)")
    }

    func test_decayEnv_reaches_one_over_e_after_decayMs() {
        var env = TbVoxDecayEnv(sampleRate: sr, decayMs: 100)
        env.trigger()
        let n = Int(0.100 * sr)   // 100 ms worth of samples
        var v = 0.0
        for _ in 0..<n { v = env.step() }
        XCTAssertEqual(v, 1.0 / M_E, accuracy: 0.02,
            "decay env should be ~1/e after one decay time")
    }

    // MARK: - Voice behavior

    private func renderPeak(_ voice: TB303Voice, seconds: Double) -> Double {
        let n = Int(seconds * sr)
        var peak = 0.0
        for _ in 0..<n {
            let s = voice.nextSample()
            XCTAssertFalse(s.isNaN || s.isInfinite, "voice produced non-finite output")
            peak = max(peak, abs(s))
        }
        return peak
    }

    func test_voice_emits_sound_on_trigger() {
        let v = TB303Voice(sampleRate: sr)
        v.cutoffHz = 1200; v.resonance = 0.7; v.envAmount01 = 0.7; v.decayMs = 400
        v.noteOn(noteCv: 0, accented: false, glide: false)
        XCTAssertGreaterThan(renderPeak(v, seconds: 0.2), 0.05,
            "a triggered note must produce audible output")
    }

    func test_accent_is_louder() {
        let normal = TB303Voice(sampleRate: sr)
        normal.accentAmount01 = 0.8
        normal.noteOn(noteCv: 0, accented: false, glide: false)
        let normalPeak = renderPeak(normal, seconds: 0.15)

        let accented = TB303Voice(sampleRate: sr)
        accented.accentAmount01 = 0.8
        accented.noteOn(noteCv: 0, accented: true, glide: false)
        let accentPeak = renderPeak(accented, seconds: 0.15)

        XCTAssertGreaterThan(accentPeak, normalPeak * 1.1,
            "accented notes should be meaningfully louder (\(accentPeak) vs \(normalPeak))")
    }

    func test_brighter_cutoff_has_more_high_freq_energy() {
        // Rough HF proxy: sum of |sample[n]-sample[n-1]| (a crude high-pass).
        func hfEnergy(cutoff: Double) -> Double {
            let v = TB303Voice(sampleRate: sr)
            v.cutoffHz = cutoff; v.resonance = 0.3; v.envAmount01 = 0.0
            v.noteOn(noteCv: 0, accented: false, glide: false)
            var prev = 0.0, acc = 0.0
            for _ in 0..<Int(0.1 * sr) {
                let s = v.nextSample()
                acc += abs(s - prev); prev = s
            }
            return acc
        }
        XCTAssertGreaterThan(hfEnergy(cutoff: 4000), hfEnergy(cutoff: 300),
            "a brighter cutoff should pass more high-frequency content")
    }

    func test_morph_changes_timbre() {
        // Saw and square through the same (open) filter differ in HF content.
        func hf(morph: Double) -> Double {
            let v = TB303Voice(sampleRate: sr)
            v.cutoffHz = 6000; v.resonance = 0.0; v.envAmount01 = 0.0; v.waveform = morph
            v.noteOn(noteCv: 0, accented: false, glide: false)
            var prev = 0.0, acc = 0.0
            for _ in 0..<Int(0.1 * sr) { let s = v.nextSample(); acc += abs(s - prev); prev = s }
            return acc
        }
        XCTAssertNotEqual(hf(morph: 0), hf(morph: 1), accuracy: 0,
            "saw and square should not be identical")
    }
}
