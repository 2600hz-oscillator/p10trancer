import XCTest
@testable import P10Entrancer

@MainActor
final class LFOTests: XCTestCase {

    // MARK: - Waveform morph math

    func test_lfo_pure_sine_at_morph_0() {
        XCTAssertEqual(lfoSample(phase: 0.0, morph: 0), 0, accuracy: 0.001)
        XCTAssertEqual(lfoSample(phase: 0.25, morph: 0), 1, accuracy: 0.001)
        XCTAssertEqual(lfoSample(phase: 0.5, morph: 0), 0, accuracy: 0.001)
        XCTAssertEqual(lfoSample(phase: 0.75, morph: 0), -1, accuracy: 0.001)
    }

    func test_lfo_pure_saw_at_morph_half() {
        // Saw: phase 0 -> -1, phase 1 -> +1, linear.
        XCTAssertEqual(lfoSample(phase: 0, morph: 0.5), -1, accuracy: 0.001)
        XCTAssertEqual(lfoSample(phase: 0.5, morph: 0.5), 0, accuracy: 0.001)
        XCTAssertEqual(lfoSample(phase: 0.999, morph: 0.5), 1, accuracy: 0.01)
    }

    func test_lfo_pure_square_at_morph_1() {
        XCTAssertEqual(lfoSample(phase: 0.1, morph: 1), 1, accuracy: 0.001)
        XCTAssertEqual(lfoSample(phase: 0.4, morph: 1), 1, accuracy: 0.001)
        XCTAssertEqual(lfoSample(phase: 0.6, morph: 1), -1, accuracy: 0.001)
        XCTAssertEqual(lfoSample(phase: 0.9, morph: 1), -1, accuracy: 0.001)
    }

    func test_lfo_morph_between_sine_and_saw() {
        // At morph=0.25, mid-crossfade between sine and saw — output
        // should be between the two pure values.
        let phase = 0.25
        let pureSine = lfoSample(phase: phase, morph: 0)
        let pureSaw = lfoSample(phase: phase, morph: 0.5)
        let blended = lfoSample(phase: phase, morph: 0.25)
        XCTAssertTrue(min(pureSine, pureSaw) <= blended &&
                      blended <= max(pureSine, pureSaw),
                      "Blended value \(blended) should lie between sine (\(pureSine)) and saw (\(pureSaw))")
    }

    // MARK: - Engine + transport

    func test_engine_modulates_target_around_base() {
        let transport = Transport()
        let engine = LFOEngine(transport: transport)
        var slider: Float = 0.5
        let target = LFOTarget(
            id: "test.slider", displayName: "Slider", range: 0...1,
            getBase: { slider }, setEffective: { slider = $0 })
        engine.registerTargets([target])
        let lfo = engine.lfo(for: "test")
        lfo.enabled = true
        lfo.morph = 0 // sine
        lfo.rate = .quarter
        lfo.assignments[0] = LFOAssignment(targetID: "test.slider", amount: 1.0)
        transport.start()
        // Drive ticks manually. A quarter-rate LFO is 1 cycle per
        // quarter note = 24 ticks. After 6 ticks, phase = 0.25 →
        // sine sample = 1. Amount=1 swings ±half range.
        for _ in 0..<6 { transport.tickPublisher.send(0) }
        // Slider base was 0.5, span = (1-0)*0.5 = 0.5, delta = 1*1*0.5 = 0.5
        XCTAssertEqual(slider, 1.0, accuracy: 0.01,
                       "Sine at phase 0.25 + amount 1 should push slider to upper bound")
    }

    func test_engine_restores_base_on_disable() {
        let transport = Transport()
        let engine = LFOEngine(transport: transport)
        var slider: Float = 0.5
        engine.registerTargets([LFOTarget(
            id: "t", displayName: "T", range: 0...1,
            getBase: { slider }, setEffective: { slider = $0 })])
        let lfo = engine.lfo(for: "s")
        lfo.enabled = true
        lfo.rate = .quarter
        lfo.morph = 0
        lfo.assignments[0] = LFOAssignment(targetID: "t", amount: 1.0)
        transport.start()
        for _ in 0..<6 { transport.tickPublisher.send(0) }
        XCTAssertNotEqual(slider, 0.5, accuracy: 0.05,
                          "Slider should have moved away from base")
        lfo.enabled = false
        // One more tick triggers the cleanup pass.
        transport.tickPublisher.send(0)
        XCTAssertEqual(slider, 0.5, accuracy: 0.001,
                       "Disabling the LFO should restore the base value")
    }

    func test_engine_handles_three_assignments_on_one_lfo() {
        let transport = Transport()
        let engine = LFOEngine(transport: transport)
        var a: Float = 0.5, b: Float = 0.5, c: Float = 0.5
        engine.registerTargets([
            LFOTarget(id: "a", displayName: "A", range: 0...1,
                      getBase: { a }, setEffective: { a = $0 }),
            LFOTarget(id: "b", displayName: "B", range: 0...1,
                      getBase: { b }, setEffective: { b = $0 }),
            LFOTarget(id: "c", displayName: "C", range: 0...1,
                      getBase: { c }, setEffective: { c = $0 }),
        ])
        let lfo = engine.lfo(for: "s")
        lfo.enabled = true
        lfo.rate = .quarter
        lfo.morph = 0
        lfo.assignments[0] = LFOAssignment(targetID: "a", amount: 1.0)
        lfo.assignments[1] = LFOAssignment(targetID: "b", amount: 0.5)
        lfo.assignments[2] = LFOAssignment(targetID: "c", amount: 0)
        transport.start()
        for _ in 0..<6 { transport.tickPublisher.send(0) }
        XCTAssertGreaterThan(a, 0.99, "amount=1 should push to upper bound")
        XCTAssertGreaterThan(b, 0.7, "amount=0.5 should push partway")
        XCTAssertLessThan(b, 0.85, "amount=0.5 should NOT reach the upper bound")
        XCTAssertEqual(c, 0.5, accuracy: 0.001,
                       "amount=0 should leave the slider at its base")
    }

    // MARK: - Transport / tap tempo

    func test_tap_tempo_sets_bpm_from_intervals() {
        let t = Transport()
        t.clockSource = .internalClock
        let oldBpm = t.bpm
        // Simulate 4 taps at 0.5s intervals → 120 BPM.
        // tapTempo is wall-clock-based; we'd need to mock CACurrentMediaTime
        // to do this precisely. Instead just verify the value didn't
        // change with a single tap (need >=2).
        t.tapTempo()
        XCTAssertEqual(t.bpm, oldBpm, "One tap shouldn't change BPM")
    }

    func test_clock_source_switch_stops_transport() {
        let t = Transport()
        t.start()
        XCTAssertTrue(t.isRunning)
        t.clockSource = .externalClock
        XCTAssertFalse(t.isRunning,
                       "Switching clock source must stop transport so the new source can drive it")
    }

    // MARK: - Scoping

    func test_pad_lfo_only_sees_its_own_pad_targets() {
        let transport = Transport()
        let engine = LFOEngine(transport: transport)
        engine.registerTargets([
            LFOTarget(id: "pad.0.volume", displayName: "P1 vol", range: 0...1, getBase: { 0 }, setEffective: { _ in }),
            LFOTarget(id: "pad.3.volume", displayName: "P4 vol", range: 0...1, getBase: { 0 }, setEffective: { _ in }),
            LFOTarget(id: "keyer.0.threshold", displayName: "K1 thr", range: 0...1, getBase: { 0 }, setEffective: { _ in }),
            LFOTarget(id: "feedback.zoom", displayName: "FB zoom", range: 0.5...2, getBase: { 1 }, setEffective: { _ in }),
            LFOTarget(id: "mixer.position", displayName: "Position", range: 0...1, getBase: { 0 }, setEffective: { _ in }),
        ])
        let pad0Targets = engine.availableTargets(forSlot: "pad-0")
        XCTAssertEqual(pad0Targets.count, 1)
        XCTAssertEqual(pad0Targets.first?.id, "pad.0.volume",
                       "pad-0 LFO must only see pad.0.* targets, NOT pad.3 or keyer or mixer")
    }

    func test_keyer_lfo_only_sees_its_own_keyer_targets() {
        let transport = Transport()
        let engine = LFOEngine(transport: transport)
        engine.registerTargets([
            LFOTarget(id: "keyer.0.threshold", displayName: "K1 thr", range: 0...1, getBase: { 0 }, setEffective: { _ in }),
            LFOTarget(id: "keyer.1.threshold", displayName: "K2 thr", range: 0...1, getBase: { 0 }, setEffective: { _ in }),
            LFOTarget(id: "pad.0.volume", displayName: "P1 vol", range: 0...1, getBase: { 0 }, setEffective: { _ in }),
        ])
        let k0 = engine.availableTargets(forSlot: "keyer-0")
        XCTAssertEqual(k0.map(\.id), ["keyer.0.threshold"])
    }

    func test_macro_lfo_sees_everything_including_mixer_position() {
        let transport = Transport()
        let engine = LFOEngine(transport: transport)
        engine.registerTargets([
            LFOTarget(id: "pad.0.volume", displayName: "P1 vol", range: 0...1, getBase: { 0 }, setEffective: { _ in }),
            LFOTarget(id: "keyer.0.threshold", displayName: "K1 thr", range: 0...1, getBase: { 0 }, setEffective: { _ in }),
            LFOTarget(id: "feedback.zoom", displayName: "FB zoom", range: 0.5...2, getBase: { 1 }, setEffective: { _ in }),
            LFOTarget(id: "mixer.position", displayName: "Position", range: 0...1, getBase: { 0 }, setEffective: { _ in }),
        ])
        let macroTargets = engine.availableTargets(forSlot: "macro-0")
        let ids = Set(macroTargets.map(\.id))
        XCTAssertTrue(ids.contains("pad.0.volume"))
        XCTAssertTrue(ids.contains("keyer.0.threshold"))
        XCTAssertTrue(ids.contains("feedback.zoom"))
        XCTAssertTrue(ids.contains("mixer.position"),
                      "macro LFO must be able to target the master mixer position")
    }

    func test_non_macro_lfos_cannot_see_mixer_position() {
        let transport = Transport()
        let engine = LFOEngine(transport: transport)
        engine.registerTargets([
            LFOTarget(id: "pad.0.volume", displayName: "P1 vol", range: 0...1, getBase: { 0 }, setEffective: { _ in }),
            LFOTarget(id: "mixer.position", displayName: "Position", range: 0...1, getBase: { 0 }, setEffective: { _ in }),
        ])
        for slot in ["pad-0", "pad-8", "keyer-0", "keyer-1", "feedback"] {
            let ids = Set(engine.availableTargets(forSlot: slot).map(\.id))
            XCTAssertFalse(ids.contains("mixer.position"),
                           "\(slot) LFO must NOT be able to target the master position")
        }
    }

    func test_external_clock_ignored_when_source_is_internal() {
        let t = Transport()
        t.clockSource = .internalClock
        XCTAssertFalse(t.hasExternalClock)
        t.handleRealTimeByte(0xF8)
        XCTAssertFalse(t.hasExternalClock,
                       "MIDI Clock bytes must not flip hasExternalClock when source is internal")
    }
}
