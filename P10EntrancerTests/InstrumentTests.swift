import XCTest
@testable import P10Entrancer

@MainActor
final class InstrumentTests: XCTestCase {

    // MARK: - Wavetable synth

    func test_synth_renders_nonzero_samples_at_default_freq() {
        let synth = WavetableSynth()
        var buf = [Float](repeating: 0, count: 512)
        buf.withUnsafeMutableBufferPointer { ptr in
            synth.renderBlock(into: ptr.baseAddress!, count: 512, sampleRate: 48000)
        }
        // Default frequency is 261.626 Hz; over 512 samples at 48k
        // we cover ~10 ms ≈ 2.8 cycles → samples must vary.
        let mn = buf.min() ?? 0
        let mx = buf.max() ?? 0
        XCTAssertGreaterThan(mx - mn, 0.5,
                             "Synth should produce a meaningful waveform, got peak-to-peak \(mx - mn)")
    }

    func test_synth_phase_advances_with_frequency() {
        let synth = WavetableSynth()
        synth.frequencyHz = 1000
        var buf1 = [Float](repeating: 0, count: 48)
        var buf2 = [Float](repeating: 0, count: 48)
        buf1.withUnsafeMutableBufferPointer { p in
            synth.renderBlock(into: p.baseAddress!, count: 48, sampleRate: 48000)
        }
        buf2.withUnsafeMutableBufferPointer { p in
            synth.renderBlock(into: p.baseAddress!, count: 48, sampleRate: 48000)
        }
        // 48 samples at 48k = 1ms; at 1kHz that's exactly one cycle.
        // Second buffer should differ from the first at start
        // because phase carries over (drift across cycles is small
        // but nonzero due to floating point).
        XCTAssertFalse(buf1 == buf2,
                       "Phase should persist across renderBlock calls")
    }

    // MARK: - ADSR

    func test_adsr_idle_when_gate_never_set() {
        let adsr = ADSREnvelope()
        var buf = [Float](repeating: 1, count: 100)
        buf.withUnsafeMutableBufferPointer { p in
            adsr.applyBlock(buffer: p.baseAddress!, count: 100, sampleRate: 48000)
        }
        XCTAssertTrue(buf.allSatisfy { $0 == 0 },
                      "Idle envelope should mute the input buffer entirely")
    }

    func test_adsr_reaches_sustain_after_attack_decay() {
        let adsr = ADSREnvelope()
        adsr.attack = 0.001
        adsr.decay = 0.001
        adsr.sustain = 0.5
        adsr.setGate(true)
        // Run more than enough samples for attack + decay to finish.
        var buf = [Float](repeating: 1, count: 4800)
        buf.withUnsafeMutableBufferPointer { p in
            adsr.applyBlock(buffer: p.baseAddress!, count: 4800, sampleRate: 48000)
        }
        // Tail of the buffer should be sitting at sustain.
        let tail = buf.suffix(100)
        let avg = tail.reduce(0, +) / Float(tail.count)
        XCTAssertEqual(avg, 0.5, accuracy: 0.01,
                       "After attack+decay, ADSR should hold sustain (0.5)")
    }

    func test_adsr_releases_to_zero_after_gate_off() {
        let adsr = ADSREnvelope()
        adsr.attack = 0.001; adsr.decay = 0.001; adsr.sustain = 1.0; adsr.release = 0.001
        adsr.setGate(true)
        var buf = [Float](repeating: 1, count: 1000)
        buf.withUnsafeMutableBufferPointer { p in
            adsr.applyBlock(buffer: p.baseAddress!, count: 1000, sampleRate: 48000)
        }
        adsr.setGate(false)
        var rel = [Float](repeating: 1, count: 1000)
        rel.withUnsafeMutableBufferPointer { p in
            adsr.applyBlock(buffer: p.baseAddress!, count: 1000, sampleRate: 48000)
        }
        let tail = rel.suffix(50)
        XCTAssertTrue(tail.allSatisfy { abs($0) < 0.01 },
                      "After release, envelope should be at zero (saw tail=\(Array(tail)))")
        XCTAssertTrue(adsr.isIdle)
    }

    // MARK: - StepSequencer

    func test_sequencer_fires_trigger_at_step_boundaries() {
        let seq = StepSequencer()
        seq.steps[0].enabled = true
        seq.steps[0].note = 60
        seq.steps[1].enabled = true
        seq.steps[1].note = 64
        var fired: [StepSequencer.Step] = []
        seq.onStepTrigger = { fired.append($0) }
        // 6 ticks per step. handleTick fires the trigger at the START
        // of each step. Send 12 ticks to cover steps 0 and 1.
        for _ in 0..<12 { seq.handleTick() }
        XCTAssertEqual(fired.count, 2)
        XCTAssertEqual(fired[0].note, 60)
        XCTAssertEqual(fired[1].note, 64)
        XCTAssertEqual(seq.currentStep, 2,
                       "Playhead should be on step 2 after firing 0 and 1")
    }

    func test_sequencer_wraps_around_at_step_16() {
        let seq = StepSequencer()
        // 16 steps × 6 ticks = 96 ticks for one full pattern.
        for _ in 0..<96 { seq.handleTick() }
        XCTAssertEqual(seq.currentStep, 0,
                       "After exactly one pattern, playhead should wrap back to 0")
    }

    // MARK: - Frequency conversion

    func test_midi_note_60_is_middle_c() {
        XCTAssertEqual(StepSequencer.frequencyHz(forNote: 60), 261.626, accuracy: 0.05)
    }

    func test_midi_note_69_is_a440() {
        XCTAssertEqual(StepSequencer.frequencyHz(forNote: 69), 440.0, accuracy: 0.01)
    }
}
