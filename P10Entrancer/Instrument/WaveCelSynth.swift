import Foundation

/// Stereo wavetable VCO ported from inet.modular's wavecel.ts. Each
/// frame is 256 samples (E352 convention); the table can have any
/// number of frames (typically 32/64/128/256). Per-sample bilinear
/// interpolation between adjacent frames + adjacent samples. Spread
/// taps N adjacent frames around the morph position and equal-power
/// pans them across L/R; spread=1 is mono on both channels.
/// Wavefolder: symmetric foldback reflection with drive = 1+amount*4.
///
/// The renderBlock is real-time safe (no allocation, no locks). It
/// reads `tune / fine / morph / spread / fold / frequencyHz` once per
/// buffer (k-rate), which is good enough for an MVP.
final class WaveCelSynth {
    /// Frame size mandated by the E352 wavetable format.
    static let frameSize = 256
    private static let C4_HZ: Double = 261.626

    // MARK: - Public params (UI-writable)

    /// Coarse pitch offset in semitones (-36 .. +36).
    var tune: Float = 0
    /// Fine pitch offset in cents (-100 .. +100).
    var fine: Float = 0
    /// Wavetable position 0..1 — picks the center frame for spread.
    var morph: Float = 0
    /// Number of frames to mix and pan across (1..5). spread=1 is
    /// mono on both channels.
    var spread: Float = 1
    /// Wavefolder amount 0..1. 0 = bypass.
    var fold: Float = 0
    /// Fundamental frequency in Hz before tune/fine offsets are
    /// applied. Set by the sequencer when a step triggers.
    var frequencyHz: Float = Float(C4_HZ)

    // MARK: - Table

    struct Table {
        /// Flattened: frameCount × frameSize samples in -1..+1.
        let samples: [Float]
        let frameCount: Int
        let label: String
    }

    /// Bundled fallback used until VOXSYNTH (or another user table)
    /// is loaded. 16 frames morphing sine → saw → square.
    static func defaultTable() -> Table {
        let fc = 16
        var samples = [Float](repeating: 0, count: fc * frameSize)
        for f in 0..<fc {
            let t = Float(f) / Float(fc - 1)
            for i in 0..<frameSize {
                let phase = Float(i) / Float(frameSize)
                let sine = sin(phase * 2 * .pi)
                let saw  = 2 * phase - 1
                let sq: Float = phase < 0.5 ? 1 : -1
                let v: Float
                if t <= 0.5 {
                    let k = t * 2
                    v = sine * (1 - k) + saw * k
                } else {
                    let k = (t - 0.5) * 2
                    v = saw * (1 - k) + sq * k
                }
                samples[f * frameSize + i] = v
            }
        }
        return Table(samples: samples, frameCount: fc, label: "DEFAULT")
    }

    private var table: Table
    private var phase: Double = 0

    init(table: Table = WaveCelSynth.defaultTable()) {
        self.table = table
    }

    func setTable(_ table: Table) {
        self.table = table
    }

    var currentTableLabel: String { table.label }
    var currentTableFrameCount: Int { table.frameCount }

    // MARK: - Render

    /// Render `count` stereo frames (interleaved is NOT used; we fill
    /// two mono buffers). Real-time safe.
    func renderBlock(left: UnsafeMutablePointer<Float>,
                     right: UnsafeMutablePointer<Float>,
                     count: Int,
                     sampleRate: Double) {
        let tbl = table
        let fc = tbl.frameCount
        guard fc > 0, !tbl.samples.isEmpty else {
            for i in 0..<count { left[i] = 0; right[i] = 0 }
            return
        }
        let FS = Self.frameSize

        // Pitch (k-rate snapshot).
        let semitones = Double(tune) + Double(fine) / 100.0
        var freq = Double(frequencyHz) * pow(2.0, semitones / 12.0)
        if freq < 1 { freq = 1 }
        else if freq > sampleRate * 0.5 { freq = sampleRate * 0.5 }
        let phaseInc = freq / sampleRate

        let morphVal = max(0, min(1, Double(morph)))
        let spreadVal = max(1, min(5, Double(spread)))
        let foldAmt = max(0, min(1, Double(fold)))

        let centerFrame = morphVal * Double(fc - 1)
        let N = spreadVal
        let halfSpan = (N - 1) / 2

        // Precompute spread taps. Cheap loop body — up to 5 taps.
        let tapCount = max(1, Int(ceil(N)))
        // Buffer up to 5 (offset, lGain, rGain, weight). Stack-allocated
        // via small fixed array; we use Swift Array because the count
        // is tiny and lifetime is per-call.
        struct Tap { var offset: Double; var lg: Double; var rg: Double; var w: Double }
        var taps: [Tap] = []
        taps.reserveCapacity(5)
        for t in 0..<tapCount {
            let offset = Double(t) - Double(tapCount - 1) / 2
            if abs(offset) > halfSpan + 0.5 { continue }
            let nrm: Double
            if halfSpan == 0 { nrm = 0 }
            else { nrm = max(-1, min(1, offset / halfSpan)) }
            let panAngle = (.pi / 4) * (1 + nrm)
            let edgeWeight = max(0, min(1, halfSpan + 0.5 - abs(offset)))
            taps.append(Tap(offset: offset,
                            lg: cos(panAngle),
                            rg: sin(panAngle),
                            w: edgeWeight))
        }
        var weightSum = 0.0
        for t in taps { weightSum += t.w }
        let norm = weightSum > 0 ? 1.0 / sqrt(weightSum) : 0

        var ph = phase
        tbl.samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for i in 0..<count {
                let samplePos = ph * Double(FS)
                let sFloor = Int(samplePos)
                let sFrac = Float(samplePos - Double(sFloor))
                let s1 = sFloor % FS
                let s2 = (sFloor + 1) % FS

                var l = 0.0
                var r = 0.0
                if halfSpan == 0 {
                    let v = Self.sampleFrame(base: base,
                                              frameFloat: centerFrame,
                                              fc: fc,
                                              s1: s1, s2: s2, sFrac: sFrac)
                    l = Double(v); r = l
                } else {
                    for t in taps {
                        let v = Self.sampleFrame(base: base,
                                                  frameFloat: centerFrame + t.offset,
                                                  fc: fc,
                                                  s1: s1, s2: s2, sFrac: sFrac)
                        l += Double(v) * t.lg * t.w
                        r += Double(v) * t.rg * t.w
                    }
                    l *= norm
                    r *= norm
                }
                if foldAmt > 0 {
                    l = Self.fold(l, amount: foldAmt)
                    r = Self.fold(r, amount: foldAmt)
                }
                left[i] = Float(l)
                right[i] = Float(r)

                ph += phaseInc
                if ph >= 1 { ph -= floor(ph) }
            }
        }
        phase = ph
    }

    // MARK: - Internal math

    @inline(__always)
    private static func sampleFrame(base: UnsafePointer<Float>,
                                    frameFloat: Double,
                                    fc: Int,
                                    s1: Int, s2: Int,
                                    sFrac: Float) -> Float {
        let f1 = max(0, min(fc - 1, Int(floor(frameFloat))))
        let f2 = max(0, min(fc - 1, f1 + 1))
        let frameFrac = Float(frameFloat - floor(frameFloat))
        let a = base[f1 * frameSize + s1] + (base[f1 * frameSize + s2] - base[f1 * frameSize + s1]) * sFrac
        let b = base[f2 * frameSize + s1] + (base[f2 * frameSize + s2] - base[f2 * frameSize + s1]) * sFrac
        return a + (b - a) * frameFrac
    }

    @inline(__always)
    private static func fold(_ x: Double, amount: Double) -> Double {
        if amount <= 0 { return x }
        let drive = 1 + amount * 4
        var y = x * drive
        var guardCount = 0
        while (y > 1 || y < -1) && guardCount < 32 {
            if y > 1 { y = 2 - y } else { y = -2 - y }
            guardCount += 1
        }
        return y
    }
}

/// Result of loading a wavetable into a WaveCelSynth.Table — used by
/// the InstrumentSource and its UI to swap tables.
enum WaveCelTableLoader {
    /// Load a bundled wavetable WAV by resource name (without
    /// extension). The asset is shipped via Resources/Wavetables.
    static func loadBundled(_ name: String) -> WaveCelSynth.Table? {
        guard let url = Bundle.main.url(forResource: name,
                                        withExtension: "wav",
                                        subdirectory: "Wavetables") else {
            // The xcodebuild bundle policy flattens resources; fall
            // back to a direct lookup.
            if let flat = Bundle.main.url(forResource: name, withExtension: "wav") {
                return load(url: flat, label: name)
            }
            return nil
        }
        return load(url: url, label: name)
    }

    /// Load a wavetable from an arbitrary file URL (Files picker,
    /// recent capture, etc.).
    static func load(url: URL, label: String? = nil) -> WaveCelSynth.Table? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let parsed = try? E352WavetableParser.parse(data: data) else { return nil }
        return makeTable(frames: parsed.frames,
                         label: label ?? url.deletingPathExtension().lastPathComponent)
    }

    private static func makeTable(frames: [[Float]], label: String) -> WaveCelSynth.Table {
        var flat = [Float](repeating: 0,
                           count: frames.count * WaveCelSynth.frameSize)
        for f in 0..<frames.count {
            let off = f * WaveCelSynth.frameSize
            for s in 0..<WaveCelSynth.frameSize {
                flat[off + s] = frames[f][s]
            }
        }
        return WaveCelSynth.Table(samples: flat,
                                  frameCount: frames.count,
                                  label: label)
    }
}
