import Foundation

/// Four 808-style drum voices. Each voice is a small synth with
/// internal envelope + oscillator state. trigger() restarts the
/// envelope; render() fills sample buffers and decays state. All
/// real-time safe — no allocations, no MainActor hops.
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

// MARK: - Kick

/// 808-style kick: a sine that pitch-sweeps from ~150 Hz to ~45 Hz
/// over about 50 ms with an exponential amplitude decay riding on
/// top. The fast pitch drop gives the "thump"; the long amp tail
/// gives the boom. Includes a small noise click at the very start
/// for transient attack.
final class KickVoice: DrumVoice {
    private var phase: Double = 0
    private var ampLevel: Float = 0
    private var pitchEnv: Float = 0
    private var clickLevel: Float = 0
    private var noiseSeed: UInt32 = 0xACE1
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
        // Pitch sweep: 150 Hz @ env=1, 45 Hz @ env=0.
        let pitchDecay: Float = 1.0 / max(0.001, 0.05 * sr)  // 50ms
        // Amp env: ~350ms tail.
        let ampDecay: Float = 1.0 / max(0.001, 0.35 * sr)
        let clickDecay: Float = 1.0 / max(0.001, 0.003 * sr)  // 3ms click
        for i in 0..<count {
            let f0: Float = 45 + (150 - 45) * pitchEnv
            phase += Double(f0) / Double(sr)
            if phase >= 1 { phase -= floor(phase) }
            let body = sinf(Float(phase) * 2 * .pi) * ampLevel
            let click = (Self.whiteNoise(&noiseSeed) * 2 - 1) * clickLevel
            let s = body * 0.9 + click * 0.5
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
    private var ampLevel: Float = 0
    private var toneLevel: Float = 0
    private var tonePhase: Double = 0
    private var noiseSeed: UInt32 = 0xBEEF
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
        let noiseDecay: Float = 1.0 / max(0.001, 0.15 * sr)
        let toneDecay: Float = 1.0 / max(0.001, 0.06 * sr)
        for i in 0..<count {
            let n = (KickVoice.whiteNoise(&noiseSeed) * 2 - 1) * ampLevel
            tonePhase += 220.0 / Double(sr)
            if tonePhase >= 1 { tonePhase -= floor(tonePhase) }
            let t = sinf(Float(tonePhase) * 2 * .pi) * toneLevel
            let s = n * 0.7 + t * 0.5
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
    private var ampLevel: Float = 0
    private var noiseSeed: UInt32 = 0xC0FE
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
        let decay: Float = 1.0 / max(0.001, 0.04 * sr)  // 40ms
        for i in 0..<count {
            let n = (KickVoice.whiteNoise(&noiseSeed) * 2 - 1) * ampLevel
            left[i]  += n * 0.4
            right[i] += n * 0.4
            ampLevel = max(0, ampLevel - decay)
        }
    }
}

// MARK: - Tom

/// Tom: like the kick but tuned higher and with a slower pitch
/// sweep — 220 Hz → 80 Hz over 100 ms, amp tail ~500 ms.
final class TomVoice: DrumVoice {
    private var phase: Double = 0
    private var ampLevel: Float = 0
    private var pitchEnv: Float = 0
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
        let pitchDecay: Float = 1.0 / max(0.001, 0.1 * sr)
        let ampDecay: Float = 1.0 / max(0.001, 0.5 * sr)
        for i in 0..<count {
            let f0: Float = 80 + (220 - 80) * pitchEnv
            phase += Double(f0) / Double(sr)
            if phase >= 1 { phase -= floor(phase) }
            let s = sinf(Float(phase) * 2 * .pi) * ampLevel
            left[i]  += s
            right[i] += s
            ampLevel = max(0, ampLevel - ampDecay)
            pitchEnv = max(0, pitchEnv - pitchDecay)
        }
    }
}
