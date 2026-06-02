import Foundation

// Per-instrument sidechain ducking (modeled on inet.modular's "sidecar"
// compressor). A standard soft-knee feedforward gain computer + asymmetric
// dB-domain envelope follower fed by a detector high-pass, driven by the
// RAW audio of another pad (the "sidechain to <pad>" trigger) so a bassline
// pumps when a kick hits. Pads are audio-isolated, so trigger audio crosses
// between renderers via the TriggerBus ring buffers.

private let kDbPerLog2: Float = 20.0 * 0.30102999566   // 20*log10(2) ≈ 6.0206
private let kLog2Floor: Float = -20.0

/// Cross-pad raw-audio exchange. Each instrument renderer publishes its mono
/// mix into its pad's ring every block; a ducked renderer reads the most
/// recent samples of its trigger pad. Lock-guarded (renderers pull on the
/// shared audio render thread; critical sections are a single block copy).
final class TriggerBus: @unchecked Sendable {
    static let ringSize = 4096
    private var rings: [[Float]]
    private var writeIdx: [Int]
    private let lock = NSLock()

    init(padCount: Int) {
        rings = Array(repeating: [Float](repeating: 0, count: TriggerBus.ringSize), count: padCount)
        writeIdx = [Int](repeating: 0, count: padCount)
    }

    /// A trigger pad publishes `count` mono samples.
    func publish(pad: Int, samples: UnsafePointer<Float>, count: Int) {
        guard pad >= 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard rings.indices.contains(pad) else { return }
        var idx = writeIdx[pad]
        let n = TriggerBus.ringSize
        for i in 0..<count {
            rings[pad][idx] = samples[i]
            idx += 1; if idx >= n { idx = 0 }
        }
        writeIdx[pad] = idx
    }

    /// Read the most recent `count` mono samples of `pad` into `out`.
    func readRecent(pad: Int, into out: inout [Float], count: Int) {
        lock.lock(); defer { lock.unlock() }
        guard rings.indices.contains(pad) else {
            for i in 0..<count { out[i] = 0 }
            return
        }
        let n = TriggerBus.ringSize
        var idx = (writeIdx[pad] - count + n) % n
        for i in 0..<count {
            out[i] = rings[pad][idx]
            idx += 1; if idx >= n { idx = 0 }
        }
    }
}

/// Immutable per-block snapshot of the sidechain params, handed from the main
/// thread to the audio thread under a lock (k-rate; the audio thread never
/// reads @Published state directly).
struct SidechainSnapshot {
    var enabled = false
    var triggerPad: Int? = nil
    var amount: Float = 0.6       // 0 = no duck, 1 = full gain reduction
    var attackMs: Float = 10
    var releaseMs: Float = 120
    var thresholdDb: Float = -24
    var ratio: Float = 6
    var kneeDb: Float = 6
    var scHpfHz: Float = 20
}

/// UI-facing observable sidechain settings (one per instrument).
@MainActor
final class SidechainState: ObservableObject {
    @Published var enabled: Bool = false
    @Published var triggerPad: Int? = nil
    @Published var amount: Float = 0.6
    @Published var attackMs: Float = 10
    @Published var releaseMs: Float = 120
    @Published var thresholdDb: Float = -24
    @Published var ratio: Float = 6
    @Published var kneeDb: Float = 6
    @Published var scHpfHz: Float = 20

    var snapshot: SidechainSnapshot {
        SidechainSnapshot(enabled: enabled, triggerPad: triggerPad, amount: amount,
                          attackMs: attackMs, releaseMs: releaseMs, thresholdDb: thresholdDb,
                          ratio: ratio, kneeDb: kneeDb, scHpfHz: scHpfHz)
    }
}

/// Per-sample soft-knee ducker. Detector HPF → log gain computer →
/// asymmetric dB smoother → linear duck multiplier blended by `amount`.
struct SidechainDucker {
    private var hpfXPrev: Float = 0
    private var hpfYPrev: Float = 0
    private var smGainDb: Float = 0   // smoothed gain reduction, <= 0 dB

    // Cached coefficients — the HPF / attack / release coeffs depend only on
    // params that are constant within a render block, so recompute them only
    // when their inputs change (bit-identical output, ~3 fewer expf/sample).
    private var aHp: Float = 0, aAtt: Float = 0, aRel: Float = 0
    private var cHpf: Float = -1, cAtt: Float = -1, cRel: Float = -1, cSr: Float = -1

    mutating func reset() { hpfXPrev = 0; hpfYPrev = 0; smGainDb = 0 }

    /// Returns the duck gain multiplier (≤ 1) for one sample, given the
    /// trigger (key) sample.
    mutating func processGain(trigger key: Float, params p: SidechainSnapshot, sampleRate sr: Float) -> Float {
        if p.scHpfHz != cHpf || p.attackMs != cAtt || p.releaseMs != cRel || sr != cSr {
            aHp = expf(-2.0 * .pi * max(1, p.scHpfHz) / sr)
            aAtt = expf(-1.0 / (max(0.01, p.attackMs) * 0.001 * sr))
            aRel = expf(-1.0 / (max(0.01, p.releaseMs) * 0.001 * sr))
            cHpf = p.scHpfHz; cAtt = p.attackMs; cRel = p.releaseMs; cSr = sr
        }
        // Detector high-pass (one-pole).
        let det = aHp * (hpfYPrev + key - hpfXPrev)
        hpfXPrev = key
        hpfYPrev = det

        let mag = abs(det)
        let xLog2 = mag > 0 ? log2f(mag) : kLog2Floor
        let xDb = kDbPerLog2 * xLog2

        // Soft-knee gain computer (GMR 2012). Gain reduction in dB (≤ 0).
        let slope = 1 - 1 / max(1, p.ratio)
        let half = max(0.0001, p.kneeDb) / 2
        let over = xDb - p.thresholdDb
        var targetDb: Float
        if over <= -half {
            targetDb = 0
        } else if over >= half {
            targetDb = -slope * over
        } else {
            let t = over + half
            targetDb = -slope * (t * t) / (2 * max(0.0001, p.kneeDb))
        }

        // Asymmetric dB smoother: fast when increasing reduction (attack),
        // slower when recovering (release). Coeffs are cached above.
        let a = targetDb < smGainDb ? aAtt : aRel
        smGainDb = a * smGainDb + (1 - a) * targetDb

        let reducedLin = exp2f(smGainDb / kDbPerLog2)   // ≤ 1
        return (1 - p.amount) + p.amount * reducedLin
    }
}
