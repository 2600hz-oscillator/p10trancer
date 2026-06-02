import XCTest
@testable import P10Entrancer

/// Audio-path tests that drive the per-pad stereo RENDERERS end-to-end
/// (renderStereoBlock), not just the bare DSP voices. Deterministic, no
/// AppState / AVAudioEngine — renderers are constructed directly. These
/// baseline current audio behavior before any perf (k-rate) change.
final class RendererAudioPathTests: XCTestCase {
    let sr: Double = 48000

    private func render(_ r: PadStereoRenderer, count: Int = 512) -> (l: [Float], r: [Float]) {
        var l = [Float](repeating: 0, count: count)
        var rr = [Float](repeating: 0, count: count)
        l.withUnsafeMutableBufferPointer { lp in
            rr.withUnsafeMutableBufferPointer { rp in
                r.renderStereoBlock(left: lp.baseAddress!, right: rp.baseAddress!,
                                    count: count, sampleRate: sr)
            }
        }
        return (l, rr)
    }
    private func peak(_ a: [Float]) -> Float { a.reduce(0) { max($0, abs($1)) } }
    private func energy(_ a: [Float]) -> Float { a.reduce(0) { $0 + $1 * $1 } }
    private func allFinite(_ a: [Float]) -> Bool { a.allSatisfy { $0.isFinite } }
    private func blocks(forSeconds s: Double, block: Int = 512) -> Int { max(1, Int(s * sr / Double(block))) }

    // MARK: - ACIDBASS

    func test_acidbass_sounds_on_trigger_then_decays() {
        let r = ACIDBASSRenderer(voice: TB303Voice(sampleRate: sr))
        r.noteOn(noteCv: 0, accented: false, glide: false)   // applied next block
        var onset: Float = 0
        var checkedLR = false
        for _ in 0..<blocks(forSeconds: 0.2) {
            let (l, rr) = render(r)
            if !checkedLR { XCTAssertEqual(l, rr, "ACIDBASS writes identical L/R"); checkedLR = true }
            onset = max(onset, peak(l))
            XCTAssertTrue(allFinite(l))
        }
        XCTAssertGreaterThan(onset, 0.05, "a triggered 303 note must be audible")
        // No retrigger; the amp env (~1.23s) decays. Tail well below onset.
        var tail: Float = 0
        for _ in 0..<blocks(forSeconds: 3.0) { tail = peak(render(r).l) }
        XCTAssertLessThan(tail, onset * 0.3, "tail should decay well below onset (\(tail) vs \(onset))")
    }

    // MARK: - MULTIPLATES

    func test_multiplates_sounds_on_gate_then_silent_after_release() {
        let r = MultiplatesRenderer(voice: MacroVoice(sampleRate: sr))
        r.gate(midiNote: 57, model: .va, on: true)
        var onset: Float = 0
        var checkedLR = false
        for _ in 0..<blocks(forSeconds: 0.2) {
            let (l, rr) = render(r)
            if !checkedLR { XCTAssertEqual(l, rr, "MULTIPLATES writes identical L/R"); checkedLR = true }
            onset = max(onset, peak(l))
        }
        XCTAssertGreaterThan(onset, 0.001)
        r.gate(midiNote: 0, model: .va, on: false)
        // The ADSR release is exponential; it reaches the idle floor (level=0,
        // hard zero) a bit over 1s after gate-off. Render long enough to hit it.
        var tail: Float = 0
        for _ in 0..<blocks(forSeconds: 1.5) { tail = peak(render(r).l) }
        XCTAssertEqual(tail, 0, accuracy: 1e-6, "ADSR release reaches idle → hard zero on a rest")
    }

    func test_multiplates_all_models_finite_and_bounded_through_renderer() {
        for model in MacroModel.allCases {
            let v = MacroVoice(sampleRate: sr)
            v.harmonics = 0.5; v.timbre = 0.5; v.morph = 0.5; v.level = 0.8
            let r = MultiplatesRenderer(voice: v)
            r.gate(midiNote: 57, model: model, on: true)
            var pk: Float = 0
            var finite = true
            for _ in 0..<blocks(forSeconds: 0.3) {
                let (l, _) = render(r)
                if !allFinite(l) { finite = false; break }
                pk = max(pk, peak(l))
            }
            XCTAssertTrue(finite, "\(model.displayName) produced non-finite output through the renderer")
            XCTAssertLessThan(pk, 1.001, "\(model.displayName) exceeded the clip bound (\(pk))")
        }
    }

    // MARK: - ACIDKICK

    func test_acidkick_kick_fires_on_trigger() {
        let kick = KickVoice()
        let r = ACIDKICKRenderer(voices: [kick, SnareVoice(), HatVoice(), TomVoice()])
        kick.trigger()
        let (l, rr) = render(r, count: 1024)
        XCTAssertTrue(allFinite(l) && allFinite(rr))
        let pp = (l.max() ?? 0) - (l.min() ?? 0)
        XCTAssertGreaterThan(pp, 0.5, "a triggered kick should produce a meaningful waveform")
    }

    func test_acidkick_each_voice_produces_energy() {
        let makers: [() -> DrumVoice] = [{ KickVoice() }, { SnareVoice() }, { HatVoice() }, { TomVoice() }]
        for make in makers {
            let v = make()
            let r = ACIDKICKRenderer(voices: [v])
            v.trigger()
            var pk: Float = 0
            for _ in 0..<4 { pk = max(pk, peak(render(r, count: 1024).l)) }
            XCTAssertGreaterThan(pk, 0.01, "each drum voice should produce audible energy on trigger")
        }
    }

    // MARK: - Sidechain (renderer + bus integration)

    func test_acidbass_ducks_under_a_loud_trigger() {
        func bassEnergy(triggerLoud: Bool) -> Float {
            let bus = TriggerBus(padCount: 2)
            let r = ACIDBASSRenderer(voice: TB303Voice(sampleRate: sr))
            r.triggerBus = bus
            r.busPadIndex = 0
            r.setSidechain(SidechainSnapshot(enabled: true, triggerPad: 1, amount: 1,
                                             attackMs: 3, thresholdDb: -40, ratio: 8))
            r.noteOn(noteCv: 0, accented: false, glide: false)
            // Warm up so the duck envelope settles before measuring.
            let block = 512
            let loud = (0..<block).map { Float($0 % 2 == 0 ? 1.0 : -1.0) }
            let silent = [Float](repeating: 0, count: block)
            func publish() {
                let src = triggerLoud ? loud : silent
                src.withUnsafeBufferPointer { bus.publish(pad: 1, samples: $0.baseAddress!, count: block) }
            }
            for _ in 0..<blocks(forSeconds: 0.05) { publish(); _ = render(r, count: block) }
            var e: Float = 0
            for _ in 0..<blocks(forSeconds: 0.1) { publish(); e += energy(render(r, count: block).l) }
            return e
        }
        let loud = bassEnergy(triggerLoud: true)
        let silent = bassEnergy(triggerLoud: false)
        XCTAssertLessThan(loud, silent * 0.8,
                          "bass energy must drop when the trigger pad is loud (\(loud) vs \(silent))")
    }

    func test_instrument_publishes_to_trigger_bus() {
        let bus = TriggerBus(padCount: 1)
        let kick = KickVoice()
        let r = ACIDKICKRenderer(voices: [kick, SnareVoice(), HatVoice(), TomVoice()])
        r.triggerBus = bus
        r.busPadIndex = 0
        kick.trigger()
        _ = render(r, count: 512)
        var out = [Float](repeating: 0, count: 512)
        bus.readRecent(pad: 0, into: &out, count: 512)
        XCTAssertGreaterThan(peak(out), 0.01, "a triggered kick must publish nonzero audio to the bus")
    }

    // MARK: - Visualizer-facing accessors

    func test_renderer_peak_and_snapshot_feed_the_visualizer() {
        let r = ACIDBASSRenderer(voice: TB303Voice(sampleRate: sr))
        r.noteOn(noteCv: 0, accented: false, glide: false)
        for _ in 0..<8 { _ = render(r) }
        XCTAssertGreaterThan(r.peak(), 0, "peak() should reflect recent output")
        let snap = r.snapshotRecentSamples()
        XCTAssertEqual(snap.count, 1024)
        XCTAssertTrue(allFinite(snap))
    }
}
