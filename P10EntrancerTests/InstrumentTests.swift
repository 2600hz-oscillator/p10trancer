import XCTest
@testable import P10Entrancer

@MainActor
final class InstrumentTests: XCTestCase {

    // MARK: - WaveCel synth

    func test_synth_renders_nonzero_stereo_samples_at_default_freq() {
        let synth = WaveCelSynth()
        var l = [Float](repeating: 0, count: 512)
        var r = [Float](repeating: 0, count: 512)
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                synth.renderBlock(left: lp.baseAddress!, right: rp.baseAddress!,
                                  count: 512, sampleRate: 48000)
            }
        }
        let pp = (l.max() ?? 0) - (l.min() ?? 0)
        XCTAssertGreaterThan(pp, 0.3,
            "WAVECEL should emit a meaningful waveform (peak-to-peak \(pp))")
    }

    func test_synth_spread_widens_stereo_image() {
        // Spread=1: L == R (mono on both). Spread>1: channels differ.
        let synth = WaveCelSynth()
        synth.morph = 0.5
        synth.spread = 1
        var l1 = [Float](repeating: 0, count: 256)
        var r1 = [Float](repeating: 0, count: 256)
        l1.withUnsafeMutableBufferPointer { lp in
            r1.withUnsafeMutableBufferPointer { rp in
                synth.renderBlock(left: lp.baseAddress!, right: rp.baseAddress!,
                                  count: 256, sampleRate: 48000)
            }
        }
        XCTAssertEqual(l1, r1, "spread=1 must produce identical L/R")
        synth.spread = 5
        var l5 = [Float](repeating: 0, count: 256)
        var r5 = [Float](repeating: 0, count: 256)
        l5.withUnsafeMutableBufferPointer { lp in
            r5.withUnsafeMutableBufferPointer { rp in
                synth.renderBlock(left: lp.baseAddress!, right: rp.baseAddress!,
                                  count: 256, sampleRate: 48000)
            }
        }
        XCTAssertNotEqual(l5, r5, "spread=5 should diverge L from R")
    }

    func test_synth_fold_clips_amplitude_into_range() {
        let synth = WaveCelSynth()
        synth.fold = 1.0
        var l = [Float](repeating: 0, count: 256)
        var r = [Float](repeating: 0, count: 256)
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                synth.renderBlock(left: lp.baseAddress!, right: rp.baseAddress!,
                                  count: 256, sampleRate: 48000)
            }
        }
        XCTAssertTrue(l.allSatisfy { abs($0) <= 1.001 },
                      "Wavefolder must keep output within ±1")
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

    // MARK: - Reverb

    func test_reverb_wet_zero_is_bypass() {
        let rv = SimpleReverb(sampleRate: 48000)
        rv.wet = 0
        var l = [Float](repeating: 0.5, count: 128)
        var r = [Float](repeating: -0.5, count: 128)
        let lOriginal = l
        let rOriginal = r
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                rv.process(left: lp.baseAddress!, right: rp.baseAddress!, count: 128)
            }
        }
        XCTAssertEqual(l, lOriginal, "wet=0 must leave the dry signal untouched")
        XCTAssertEqual(r, rOriginal)
    }

    func test_reverb_produces_tail_after_silence() {
        // Feed a single impulse, then silence — the reverb tail
        // should keep producing nonzero samples for many ms.
        let rv = SimpleReverb(sampleRate: 48000)
        rv.size = 0.8
        rv.damp = 0.3
        rv.wet = 1.0
        var l = [Float](repeating: 0, count: 4800)
        var r = [Float](repeating: 0, count: 4800)
        l[0] = 1
        r[0] = 1
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                rv.process(left: lp.baseAddress!, right: rp.baseAddress!, count: 4800)
            }
        }
        // After ~50ms of silence following the impulse, samples
        // should still be nonzero somewhere downstream.
        let tail = l.suffix(2400)
        let hasEnergy = tail.contains { abs($0) > 1e-4 }
        XCTAssertTrue(hasEnergy, "reverb should keep ringing after a single impulse")
    }

    // MARK: - Wasp filter

    func test_filter_lowpass_attenuates_high_frequencies() {
        // Run a square-wave-ish signal through a low-pass at very
        // low cutoff; output peak-to-peak must drop noticeably.
        let f = WaspFilter()
        f.mode = .lowpass
        f.cutoffHz = 100
        f.resonance = 0.1
        var l = [Float](repeating: 0, count: 4800)
        var r = [Float](repeating: 0, count: 4800)
        for i in 0..<l.count { let v: Float = i % 2 == 0 ? 1 : -1; l[i] = v; r[i] = v }
        let origPP = (l.max() ?? 0) - (l.min() ?? 0)
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                f.process(left: lp.baseAddress!, right: rp.baseAddress!,
                          count: 4800, sampleRate: 48000)
            }
        }
        // After settling, the filtered tail must be smaller than input.
        let tail = l.suffix(1000)
        let pp = (tail.max() ?? 0) - (tail.min() ?? 0)
        XCTAssertLessThan(pp, origPP * 0.5,
            "LP at 100Hz should kill most of a ~24kHz square (orig p-p \(origPP), filtered \(pp))")
    }

    // MARK: - Multi-LFO pad routing

    func test_pad_lfo2_and_lfo3_see_same_targets_as_lfo1() {
        let transport = Transport()
        let engine = LFOEngine(transport: transport)
        engine.registerTargets([
            LFOTarget(id: "pad.0.volume", displayName: "P1 vol", range: 0...1, getBase: { 0 }, setEffective: { _ in }),
            LFOTarget(id: "pad.0.synth.morph", displayName: "P1 morph", range: 0...1, getBase: { 0 }, setEffective: { _ in }),
            LFOTarget(id: "pad.1.volume", displayName: "P2 vol", range: 0...1, getBase: { 0 }, setEffective: { _ in }),
        ])
        let lfo1Targets = Set(engine.availableTargets(forSlot: "pad-0").map(\.id))
        let lfo2Targets = Set(engine.availableTargets(forSlot: "pad-0-lfo-1").map(\.id))
        let lfo3Targets = Set(engine.availableTargets(forSlot: "pad-0-lfo-2").map(\.id))
        XCTAssertEqual(lfo1Targets, lfo2Targets,
                       "LFO 2 on pad-0 must see the same targets as LFO 1")
        XCTAssertEqual(lfo1Targets, lfo3Targets,
                       "LFO 3 on pad-0 must see the same targets as LFO 1")
        XCTAssertFalse(lfo2Targets.contains("pad.1.volume"),
                       "Pad LFOs must stay scoped to their own pad")
    }

    // MARK: - E352 parser

    func test_bundled_voxsynth_parses_into_frames() throws {
        let table = WaveCelTableLoader.loadBundled("VOXSYNTH")
        XCTAssertNotNil(table, "VOXSYNTH wavetable must ship in the bundle")
        if let t = table {
            // Each frame is 256 samples; the table at minimum has 32
            // frames per the E352 standard but typically 64 here.
            XCTAssertGreaterThanOrEqual(t.frameCount, 32)
            XCTAssertEqual(t.samples.count, t.frameCount * WaveCelSynth.frameSize)
            XCTAssertTrue(t.samples.allSatisfy { abs($0) <= 1.001 },
                          "All wavetable samples must lie in -1..+1")
        }
    }

    // MARK: - ACIDKICK

    func test_kick_voice_emits_energy_after_trigger() {
        let kick = KickVoice()
        kick.trigger()
        var l = [Float](repeating: 0, count: 512)
        var r = [Float](repeating: 0, count: 512)
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                kick.renderAdd(left: lp.baseAddress!, right: rp.baseAddress!,
                               count: 512, sampleRate: 48000)
            }
        }
        let pp = (l.max() ?? 0) - (l.min() ?? 0)
        XCTAssertGreaterThan(pp, 0.5, "kick must produce audible swing post-trigger")
    }

    func test_drum_sequencer_fires_trigger_at_step_boundaries() {
        let seq = DrumSequencer()
        seq.tracks[0].steps[0] = true
        seq.tracks[2].steps[0] = true
        seq.tracks[1].steps[1] = true
        var fires: [[Int]] = []
        seq.onStepTrigger = { fires.append($0) }
        // 12 ticks = first 2 steps.
        for _ in 0..<12 { seq.handleTick() }
        XCTAssertEqual(fires.count, 2)
        XCTAssertEqual(Set(fires[0]), Set([0, 2]),
                       "step 0 should fire tracks 0 and 2 simultaneously")
        XCTAssertEqual(fires[1], [1])
    }

    // MARK: - Frequency conversion

    func test_midi_note_60_is_middle_c() {
        XCTAssertEqual(StepSequencer.frequencyHz(forNote: 60), 261.626, accuracy: 0.05)
    }

    func test_midi_note_69_is_a440() {
        XCTAssertEqual(StepSequencer.frequencyHz(forNote: 69), 440.0, accuracy: 0.01)
    }
}
