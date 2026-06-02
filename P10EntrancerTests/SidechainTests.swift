import XCTest
@testable import P10Entrancer

/// Unit tests for the sidechain DSP + cross-pad trigger bus. Pure CPU, fully
/// deterministic — no Metal, no audio engine, no AppState.
final class SidechainTests: XCTestCase {
    let sr: Float = 48000

    // MARK: - TriggerBus

    func test_triggerBus_roundtrips_samples() {
        let bus = TriggerBus(padCount: 2)
        let input = (0..<256).map { Float($0) * 0.001 }
        input.withUnsafeBufferPointer { bus.publish(pad: 0, samples: $0.baseAddress!, count: input.count) }
        var out = [Float](repeating: -9, count: 256)
        bus.readRecent(pad: 0, into: &out, count: 256)
        XCTAssertEqual(out, input)
    }

    func test_triggerBus_readRecent_returns_most_recent_block() {
        let bus = TriggerBus(padCount: 1)
        let a = [Float](repeating: 0.1, count: 128)
        let b = [Float](repeating: 0.9, count: 128)
        a.withUnsafeBufferPointer { bus.publish(pad: 0, samples: $0.baseAddress!, count: 128) }
        b.withUnsafeBufferPointer { bus.publish(pad: 0, samples: $0.baseAddress!, count: 128) }
        var out = [Float](repeating: 0, count: 128)
        bus.readRecent(pad: 0, into: &out, count: 128)
        XCTAssertEqual(out, b, "most recent published block should be returned")
    }

    func test_triggerBus_out_of_range_pad_zero_fills_and_publish_noops() {
        let bus = TriggerBus(padCount: 2)
        var out = [Float](repeating: 7, count: 64)
        bus.readRecent(pad: 99, into: &out, count: 64)
        XCTAssertEqual(out, [Float](repeating: 0, count: 64))
        // publish to an invalid pad must not crash.
        let s = [Float](repeating: 1, count: 64)
        s.withUnsafeBufferPointer { bus.publish(pad: -1, samples: $0.baseAddress!, count: 64) }
    }

    func test_triggerBus_wraps_past_ring_size() {
        let bus = TriggerBus(padCount: 1)
        // Publish more than the ring holds, then read the tail back.
        let total = TriggerBus.ringSize + 500
        let full = (0..<total).map { Float($0 % 100) }
        full.withUnsafeBufferPointer { bus.publish(pad: 0, samples: $0.baseAddress!, count: total) }
        var out = [Float](repeating: 0, count: 200)
        bus.readRecent(pad: 0, into: &out, count: 200)
        let expectedTail = Array(full.suffix(200))
        XCTAssertEqual(out, expectedTail, "reading across the ring wrap must return the last N samples")
    }

    // MARK: - SidechainDucker

    /// Drive the ducker for `n` samples with a constant key magnitude and
    /// return the final gain multiplier. Uses an alternating ±key so the
    /// detector high-pass passes it (a DC key would be filtered to zero).
    private func runDucker(_ d: inout SidechainDucker, key: Float, n: Int, params: SidechainSnapshot) -> Float {
        var g: Float = 1
        for i in 0..<n {
            let k = (i % 2 == 0) ? key : -key
            g = d.processGain(trigger: k, params: params, sampleRate: sr)
        }
        return g
    }

    func test_ducker_silent_trigger_no_reduction() {
        var d = SidechainDucker()
        let p = SidechainSnapshot(enabled: true, triggerPad: 0, amount: 1, thresholdDb: -40, ratio: 8)
        let g = runDucker(&d, key: 0, n: 480, params: p)
        XCTAssertEqual(g, 1.0, accuracy: 1e-4, "a silent trigger must not duck")
    }

    func test_ducker_loud_trigger_reduces_gain() {
        var d = SidechainDucker()
        let p = SidechainSnapshot(enabled: true, triggerPad: 0, amount: 1,
                                  attackMs: 5, thresholdDb: -40, ratio: 8)
        let g = runDucker(&d, key: 1.0, n: 4800, params: p)
        XCTAssertLessThan(g, 0.5, "a loud trigger over threshold must duck hard (gain \(g))")
    }

    func test_ducker_amount_zero_never_ducks() {
        var d = SidechainDucker()
        let p = SidechainSnapshot(enabled: true, triggerPad: 0, amount: 0, thresholdDb: -40, ratio: 8)
        let g = runDucker(&d, key: 1.0, n: 2400, params: p)
        XCTAssertEqual(g, 1.0, accuracy: 1e-4, "amount=0 disables the duck entirely")
    }

    func test_ducker_release_is_slower_than_attack() {
        var d = SidechainDucker()
        let p = SidechainSnapshot(enabled: true, triggerPad: 0, amount: 1,
                                  attackMs: 1, releaseMs: 500, thresholdDb: -40, ratio: 8)
        let loud = runDucker(&d, key: 1.0, n: 2400, params: p)   // 50ms loud → ducked
        let released = runDucker(&d, key: 0, n: 2400, params: p)  // 50ms silent → slow recover
        XCTAssertGreaterThan(released, loud, "gain should recover after the trigger stops")
        XCTAssertLessThan(released, 0.9, "with a 500ms release, 50ms isn't enough to fully recover")
    }

    @MainActor
    func test_sidechainState_snapshot_copies_all_fields() {
        let s = SidechainState()
        s.enabled = true; s.triggerPad = 3; s.amount = 0.42; s.attackMs = 7
        s.releaseMs = 222; s.thresholdDb = -30; s.ratio = 9; s.kneeDb = 4; s.scHpfHz = 80
        let snap = s.snapshot
        XCTAssertEqual(snap.enabled, true)
        XCTAssertEqual(snap.triggerPad, 3)
        XCTAssertEqual(snap.amount, 0.42)
        XCTAssertEqual(snap.attackMs, 7)
        XCTAssertEqual(snap.releaseMs, 222)
        XCTAssertEqual(snap.thresholdDb, -30)
        XCTAssertEqual(snap.ratio, 9)
        XCTAssertEqual(snap.kneeDb, 4)
        XCTAssertEqual(snap.scHpfHz, 80)
    }
}
