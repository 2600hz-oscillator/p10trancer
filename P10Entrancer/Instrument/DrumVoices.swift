import Foundation

/// Four 808-style drum voices. Each voice is a small synth with
/// internal envelope + oscillator state. trigger() restarts the
/// envelope; renderAdd() accumulates into stereo output. All
/// real-time safe — no allocations, no MainActor hops.
///
/// Per-voice user controls:
///   • `pitchMul`     0.25..4  multiplies every internal frequency
///                              (sweep start, sweep end, tone pitch)
///   • `decayMul`     0.1..4   scales how long the amp + pitch envs
///                              take to die out (1 = factory speed)
///   • `bitcrush`     0..1     0 bypass, > 0 quantizes amplitude AND
///                              holds samples across N audio frames
///                              for the chunky lo-fi crunch
///
/// Voices accumulate INTO the output buffer (not write — so multiple
/// voices on the same track tick can sum without trampling each
/// other). Callers pre-zero the buffer.

enum DrumVoiceType: Int, Codable, CaseIterable, Identifiable {
    case kick = 0, snare, hat, tom
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .kick:  return "KICK"
        case .snare: return "SNARE"
        case .hat:   return "HAT"
        case .tom:   return "TOM"
        }
    }
}

protocol DrumVoice: AnyObject {
    /// Multiplies every internal oscillator frequency in the voice.
    /// 1 = factory tuning.
    var pitchMul: Float { get set }
    /// Scales amp + pitch decay rates. > 1 = faster decay (shorter
    /// tail), < 1 = longer tail. UI label is intentionally inverted
    /// so the slider reads "decay length"; we store the rate ratio
    /// internally for cheap multiplication.
    var decayMul: Float { get set }
    /// 0 = clean, 1 = crushed-to-noise. Reduces amplitude resolution
    /// and holds samples to give the 8-bit hold-and-clip vibe.
    var bitcrush: Float { get set }

    func trigger()
    func renderAdd(left: UnsafeMutablePointer<Float>,
                    right: UnsafeMutablePointer<Float>,
                    count: Int,
                    sampleRate: Double)
    var isActive: Bool { get }
}

enum DrumVoiceFactory {
    static func make(type: DrumVoiceType) -> DrumVoice {
        switch type {
        case .kick:  return KickVoice()
        case .snare: return SnareVoice()
        case .hat:   return HatVoice()
        case .tom:   return TomVoice()
        }
    }
}

/// Bitcrush: maps a 0..1 amount onto (1) a sample-hold length in
/// audio frames and (2) an amplitude quantization step. Designed to
/// taste — small amounts give a subtle grit, the top end clamps the
/// signal to ~5 visible levels held across ~6 frames.
@inline(__always)
fileprivate func bitcrushSample(_ x: Float,
                                amount: Float,
                                holdCounter: inout Int,
                                heldSample: inout Float) -> Float {
    if amount <= 0.001 { return x }
    let a = min(1, amount)
    let hold = max(1, Int(1 + a * 5))           // 1..6 sample hold
    let bits: Float = max(1, 8 - a * 6)         // 8..2 bits effective
    let levels = max(2, Float(Int(pow(2, bits)) - 1))
    if holdCounter <= 0 {
        let q = (x * 0.5 + 0.5)                  // 0..1
        let qStep = (q * levels).rounded() / levels
        heldSample = (qStep - 0.5) * 2
        holdCounter = hold
    }
    holdCounter -= 1
    return heldSample
}

// MARK: - Kick

/// 808-style kick: a sine that pitch-sweeps from ~150 Hz to ~45 Hz
/// over about 50 ms with an exponential amplitude decay riding on
/// top. The fast pitch drop gives the "thump"; the long amp tail
/// gives the boom. Includes a small noise click at the very start
/// for transient attack.
final class KickVoice: DrumVoice {
    var pitchMul: Float = 1
    var decayMul: Float = 1
    var bitcrush: Float = 0

    private var phase: Double = 0
    private var ampLevel: Float = 0
    private var pitchEnv: Float = 0
    private var clickLevel: Float = 0
    private var noiseSeed: UInt32 = 0xACE1
    private var bcHold: Int = 0
    private var bcHeld: Float = 0
    var isActive: Bool { ampLevel > 0.0005 || clickLevel > 0.0005 }

    func trigger() {
        ampLevel = 1
        pitchEnv = 1
        clickLevel = 0.6
        phase = 0
    }

    func renderAdd(left: UnsafeMutablePointer<Float>,
                    right: UnsafeMutablePointer<Float>,
                    count: Int,
                    sampleRate: Double) {
        guard isActive else { return }
        let sr = Float(sampleRate)
        let decayScale = max(0.1, decayMul)
        let pitchDecay: Float = 1.0 / max(0.001, 0.05 * sr * decayScale)
        let ampDecay: Float = 1.0 / max(0.001, 0.35 * sr * decayScale)
        let clickDecay: Float = 1.0 / max(0.001, 0.003 * sr * decayScale)
        let pMul = max(0.05, pitchMul)
        for i in 0..<count {
            let f0: Float = (45 + (150 - 45) * pitchEnv) * pMul
            phase += Double(f0) / Double(sr)
            if phase >= 1 { phase -= floor(phase) }
            let body = sinf(Float(phase) * 2 * .pi) * ampLevel
            let click = (KickVoice.whiteNoise(&noiseSeed) * 2 - 1) * clickLevel
            var s = body * 0.9 + click * 0.5
            s = bitcrushSample(s, amount: bitcrush, holdCounter: &bcHold, heldSample: &bcHeld)
            left[i]  += s
            right[i] += s
            ampLevel = max(0, ampLevel - ampDecay)
            pitchEnv = max(0, pitchEnv - pitchDecay)
            clickLevel = max(0, clickLevel - clickDecay)
        }
    }

    @inline(__always)
    static func whiteNoise(_ seed: inout UInt32) -> Float {
        seed = seed &* 1664525 &+ 1013904223
        return Float(seed) / Float(UInt32.max)
    }
}

// MARK: - Snare

/// Snare: noise burst (the wires) mixed with a short 220 Hz sine
/// pop (the membrane). Both decay quickly so the snare reads as a
/// crack rather than a sustained tone.
final class SnareVoice: DrumVoice {
    var pitchMul: Float = 1
    var decayMul: Float = 1
    var bitcrush: Float = 0

    private var ampLevel: Float = 0
    private var toneLevel: Float = 0
    private var tonePhase: Double = 0
    private var noiseSeed: UInt32 = 0xBEEF
    private var bcHold: Int = 0
    private var bcHeld: Float = 0
    var isActive: Bool { ampLevel > 0.0005 || toneLevel > 0.0005 }

    func trigger() {
        ampLevel = 0.8
        toneLevel = 0.6
        tonePhase = 0
    }

    func renderAdd(left: UnsafeMutablePointer<Float>,
                    right: UnsafeMutablePointer<Float>,
                    count: Int,
                    sampleRate: Double) {
        guard isActive else { return }
        let sr = Float(sampleRate)
        let decayScale = max(0.1, decayMul)
        let noiseDecay: Float = 1.0 / max(0.001, 0.15 * sr * decayScale)
        let toneDecay: Float = 1.0 / max(0.001, 0.06 * sr * decayScale)
        let pMul = max(0.05, pitchMul)
        for i in 0..<count {
            let n = (KickVoice.whiteNoise(&noiseSeed) * 2 - 1) * ampLevel
            tonePhase += Double(220 * pMul) / Double(sr)
            if tonePhase >= 1 { tonePhase -= floor(tonePhase) }
            let t = sinf(Float(tonePhase) * 2 * .pi) * toneLevel
            var s = n * 0.7 + t * 0.5
            s = bitcrushSample(s, amount: bitcrush, holdCounter: &bcHold, heldSample: &bcHeld)
            left[i]  += s
            right[i] += s
            ampLevel = max(0, ampLevel - noiseDecay)
            toneLevel = max(0, toneLevel - toneDecay)
        }
    }
}

// MARK: - Hat

/// Hat: short noise burst with very fast decay. The HF character
/// comes from the brevity (a tiny noise click reads as bright); we
/// don't bother with an explicit high-pass.
final class HatVoice: DrumVoice {
    var pitchMul: Float = 1
    var decayMul: Float = 1
    var bitcrush: Float = 0

    private var ampLevel: Float = 0
    private var noiseSeed: UInt32 = 0xC0FE
    private var holdCounter: Int = 0
    private var heldNoise: Float = 0
    private var bcHold: Int = 0
    private var bcHeld: Float = 0
    var isActive: Bool { ampLevel > 0.0005 }

    func trigger() {
        ampLevel = 0.5
    }

    func renderAdd(left: UnsafeMutablePointer<Float>,
                    right: UnsafeMutablePointer<Float>,
                    count: Int,
                    sampleRate: Double) {
        guard isActive else { return }
        let sr = Float(sampleRate)
        let decayScale = max(0.1, decayMul)
        let decay: Float = 1.0 / max(0.001, 0.04 * sr * decayScale)
        // pitchMul controls how often we step the noise generator —
        // lower = smoother / darker, higher = brighter chatter.
        let stepEvery = max(1, Int(1.0 / max(0.05, pitchMul)))
        for i in 0..<count {
            if holdCounter <= 0 {
                heldNoise = (KickVoice.whiteNoise(&noiseSeed) * 2 - 1)
                holdCounter = stepEvery
            }
            holdCounter -= 1
            var s = heldNoise * ampLevel * 0.4
            s = bitcrushSample(s, amount: bitcrush, holdCounter: &bcHold, heldSample: &bcHeld)
            left[i]  += s
            right[i] += s
            ampLevel = max(0, ampLevel - decay)
        }
    }
}

// MARK: - Tom

/// Tom: like the kick but tuned higher and with a slower pitch
/// sweep — 220 Hz → 80 Hz over 100 ms, amp tail ~500 ms.
final class TomVoice: DrumVoice {
    var pitchMul: Float = 1
    var decayMul: Float = 1
    var bitcrush: Float = 0

    private var phase: Double = 0
    private var ampLevel: Float = 0
    private var pitchEnv: Float = 0
    private var bcHold: Int = 0
    private var bcHeld: Float = 0
    var isActive: Bool { ampLevel > 0.0005 }

    func trigger() {
        ampLevel = 0.9
        pitchEnv = 1
        phase = 0
    }

    func renderAdd(left: UnsafeMutablePointer<Float>,
                    right: UnsafeMutablePointer<Float>,
                    count: Int,
                    sampleRate: Double) {
        guard isActive else { return }
        let sr = Float(sampleRate)
        let decayScale = max(0.1, decayMul)
        let pitchDecay: Float = 1.0 / max(0.001, 0.1 * sr * decayScale)
        let ampDecay: Float = 1.0 / max(0.001, 0.5 * sr * decayScale)
        let pMul = max(0.05, pitchMul)
        for i in 0..<count {
            let f0: Float = (80 + (220 - 80) * pitchEnv) * pMul
            phase += Double(f0) / Double(sr)
            if phase >= 1 { phase -= floor(phase) }
            var s = sinf(Float(phase) * 2 * .pi) * ampLevel
            s = bitcrushSample(s, amount: bitcrush, holdCounter: &bcHold, heldSample: &bcHeld)
            left[i]  += s
            right[i] += s
            ampLevel = max(0, ampLevel - ampDecay)
            pitchEnv = max(0, pitchEnv - pitchDecay)
        }
    }
}
