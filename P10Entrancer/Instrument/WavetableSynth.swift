import Foundation

/// Wavetable VCO ported from inet.modular's wavetable-vco.ts. Holds a
/// 2D table of `frameCount × frameSize` Float samples and interpolates
/// both across frames (wavePosition 0..1 picks where in the table) and
/// across samples (sub-sample phase). Pitch is supplied per call as a
/// frequency in Hz; phase persists across renders. No mip-mapping yet —
/// high frequencies will alias above ~8kHz fundamental, same caveat as
/// the JS original.
///
/// The renderBlock is real-time safe (no allocation, no locks). Only
/// reads `wavePosition` and the immutable table; the table is replaced
/// atomically by swapping the array reference, which is fine in Swift
/// for our cooperatively-scheduled audio path.
final class WavetableSynth {
    /// Bundled default: a single-frame sine-ish table. Quick to build,
    /// useful for initial verification. UI will let the user pick
    /// from richer bundled tables later.
    static func bundledDefaultTable() -> Table {
        let frameSize = 2048
        let frameCount = 8
        var samples = [Float](repeating: 0, count: frameSize * frameCount)
        // Morph from sine (frame 0) → saw (frame 4) → square (frame 7).
        for f in 0..<frameCount {
            let t = Float(f) / Float(frameCount - 1)
            for i in 0..<frameSize {
                let phase = Float(i) / Float(frameSize)
                let sine = sin(phase * 2 * .pi)
                let saw  = 2 * phase - 1
                let sq: Float = phase < 0.5 ? 1 : -1
                let value: Float
                if t <= 0.5 {
                    let k = t * 2
                    value = sine * (1 - k) + saw * k
                } else {
                    let k = (t - 0.5) * 2
                    value = saw * (1 - k) + sq * k
                }
                samples[f * frameSize + i] = value
            }
        }
        return Table(samples: samples, frameSize: frameSize, frameCount: frameCount)
    }

    struct Table {
        let samples: [Float]
        let frameSize: Int
        let frameCount: Int
    }

    private var table: Table
    /// Phase accumulator in [0, 1). One cycle of the wavetable's
    /// frameSize maps to phase 0→1.
    private var phase: Double = 0
    /// 0..1 position within the table — picks which frame(s) to read.
    /// UI-writable; render reads it once per buffer (k-rate).
    var wavePosition: Float = 0
    /// Current pitch in Hz, set by the sequencer before each render.
    var frequencyHz: Float = 261.626  // C4 default

    init(table: Table = WavetableSynth.bundledDefaultTable()) {
        self.table = table
    }

    /// Swap in a new wavetable. Safe to call from the main thread —
    /// the audio thread will pick up the new reference on its next
    /// render call.
    func setTable(_ table: Table) {
        self.table = table
    }

    /// Render `count` samples into `out` at the given sampleRate.
    /// Real-time safe (no allocations, no locks).
    func renderBlock(into out: UnsafeMutablePointer<Float>, count: Int, sampleRate: Double) {
        let tbl = self.table
        let frameSize = tbl.frameSize
        let frameCount = tbl.frameCount
        guard !tbl.samples.isEmpty, frameSize > 0, frameCount > 0 else {
            for i in 0..<count { out[i] = 0 }
            return
        }
        let wp = max(0, min(1, Double(wavePosition)))
        let frameFloat = wp * Double(frameCount - 1)
        let f1 = Int(frameFloat)
        let f2 = min(f1 + 1, frameCount - 1)
        let frameFrac = Float(frameFloat - Double(f1))
        let f1Base = f1 * frameSize
        let f2Base = f2 * frameSize

        let freq = max(1, min(20000, Double(frequencyHz)))
        let phaseInc = freq / sampleRate

        var ph = self.phase
        tbl.samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for i in 0..<count {
                let sampleFloat = ph * Double(frameSize)
                let sFloor = Int(sampleFloat)
                let sampleFrac = Float(sampleFloat - Double(sFloor))
                let s1 = sFloor % frameSize
                let s2 = (sFloor + 1) % frameSize
                let a = base[f1Base + s1] + (base[f1Base + s2] - base[f1Base + s1]) * sampleFrac
                let b = base[f2Base + s1] + (base[f2Base + s2] - base[f2Base + s1]) * sampleFrac
                out[i] = a + (b - a) * frameFrac
                ph += phaseInc
                if ph >= 1 { ph -= floor(ph) }
            }
        }
        self.phase = ph
    }
}
