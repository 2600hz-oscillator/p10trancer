import Foundation

// MacroOscillator — Swift port of inet.modular's MACROOSCILLATOR (a
// clean-room Mutable Plaits-style multi-model oscillator). All 14 synthesis
// engines ported from the pure-math mirror (packages/web/src/lib/audio/
// modules/macrooscillator.ts). Powers the MULTIPLATES pad instrument.
//
// Each engine returns its MAIN output (the reference also computes an `aux`
// tap we don't use in the mono instrument). DSP is Double internally.
//
// PERF: the reference ticks all 14 engines every sample and selects one —
// we DO NOT. MacroVoice ticks only the active model's engine, so per-sample
// cost equals a single engine. Model + pitch are per-step; harmonics/timbre/
// morph/level are global macros (smoothed at ~80 Hz).

// MARK: - Model enum

enum MacroModel: Int, CaseIterable, Identifiable {
    case va = 0, waveshape, fm2op, fm6op, chord, additive, string, modal,
         kick, snare, hihat, wavetable, granular, speech

    var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .va: return "VA"
        case .waveshape: return "WAVESHAPE"
        case .fm2op: return "FM 2OP"
        case .fm6op: return "FM 6OP"
        case .chord: return "CHORD"
        case .additive: return "ADDITIVE"
        case .string: return "STRING"
        case .modal: return "MODAL"
        case .kick: return "KICK"
        case .snare: return "SNARE"
        case .hihat: return "HIHAT"
        case .wavetable: return "WAVETABLE"
        case .granular: return "GRANULAR"
        case .speech: return "SPEECH"
        }
    }
    /// Percussive/plucked engines that need a gate re-excitation on trigger.
    var retriggersOnGate: Bool {
        switch self {
        case .string, .kick, .snare, .hihat: return true
        default: return false
        }
    }
}

// MARK: - Shared helpers

@inline(__always)
private func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }

@inline(__always)
private func polyBlep(_ t: Double, _ dt: Double) -> Double {
    if t < dt { let x = t / dt; return x + x - x * x - 1 }
    if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
    return 0
}

@inline(__always)
private func wavefold(_ x: Double, _ fold: Double) -> Double {
    let drive = 1 + fold * 5
    return sin(x * drive * Double.pi * 0.5) / max(1, drive * 0.5)
}

/// 32-bit LCG mirroring the reference's `(state * 16807) | 0` noise so the
/// percussion has the same spectral character.
private struct LCG {
    var state: Int32
    init(_ seed: UInt32) { state = Int32(bitPattern: seed) }
    mutating func noise() -> Double {
        state = state &* 16807
        return Double(state & 0x7fff_ffff) / Double(0x7fff_ffff) * 2 - 1
    }
    mutating func rand() -> Double {
        state = state &* 16807
        return Double(state & 0x7fff_ffff) / Double(0x7fff_ffff)
    }
}

protocol MacroEngine: AnyObject {
    func reset()
    func render(freq: Double, harmonics h: Double, timbre t: Double, morph m: Double, sampleRate sr: Double) -> Double
}

// MARK: - Tables

private let FM2_RATIOS: [(Double, Double)] = [
    (1, 1), (1, 2), (2, 1), (1, 3), (3, 1), (1, 4), (2, 3), (3, 2),
]
private let FM6_BASE_RATIOS: [Double] = [1.0, 1.0, 2.0, 3.0, 4.0, 1.0]
private let CHORD_SHAPES: [[Double]] = [
    [0, 12, 24, 36], [0, 7, 12, 19], [0, 3, 7, 12], [0, 4, 7, 12],
    [0, 2, 7, 12], [0, 5, 7, 12], [0, 4, 7, 10], [0, 3, 6, 9],
]
private let MODAL_PRESETS: [(ratios: [Double], amps: [Double])] = [
    ([1.0, 2.76, 5.41, 8.93, 13.34, 18.64], [1.0, 0.6, 0.4, 0.3, 0.2, 0.15]),
    ([1.0, 4.0, 10.0, 16.0, 23.0, 30.0], [1.0, 0.7, 0.3, 0.15, 0.1, 0.05]),
    ([0.5, 1.0, 1.2, 2.4, 3.0, 4.5], [0.8, 1.0, 0.4, 0.3, 0.2, 0.15]),
    ([1.0, 4.0, 9.5, 14.0, 18.0, 24.0], [1.0, 0.4, 0.2, 0.1, 0.05, 0.03]),
]
private let MODAL_MODES = 6
private let HIHAT_RATIOS: [Double] = [2.0, 3.0, 4.16, 5.43, 6.79, 8.21]
private let ADDITIVE_PARTIALS = 16
private let STRING_MAX_DELAY = 2400
private let GRAN_MAX_GRAINS = 8
private let VOWEL_PRESETS: [(f: [Double], g: [Double])] = [
    ([730, 1090, 2440], [1.0, 0.5, 0.3]),
    ([530, 1840, 2480], [1.0, 0.6, 0.3]),
    ([270, 2290, 3010], [1.0, 0.4, 0.2]),
    ([570, 840, 2410], [1.0, 0.5, 0.3]),
    ([300, 870, 2240], [1.0, 0.3, 0.2]),
    ([640, 1190, 2390], [1.0, 0.5, 0.3]),
]

// MARK: - Engines

private final class VAEngine: MacroEngine {
    var phaseA = 0.0, phaseB = 0.0, phaseSub = 0.0
    func reset() { phaseA = 0; phaseB = 0; phaseSub = 0 }
    private func morphAB(_ t: Double, _ dtl: Double, _ morph: Double) -> Double {
        let saw = (2 * t - 1) - polyBlep(t, dtl)
        var sqr = (t < 0.5 ? 1.0 : -1.0) + polyBlep(t, dtl)
        let tShifted = (t + 0.5) - floor(t + 0.5)
        sqr -= polyBlep(tShifted, dtl)
        let tri = 1 - 4 * abs(t - 0.5)
        if morph < 0.5 { let m = morph * 2; return saw * (1 - m) + sqr * m }
        let m = (morph - 0.5) * 2; return sqr * (1 - m) + tri * m
    }
    func render(freq: Double, harmonics: Double, timbre: Double, morph: Double, sampleRate sr: Double) -> Double {
        let dt = freq / sr
        let detuneRatio = pow(2, (harmonics * 0.5) / 12) - 1
        let dtB = dt * (1 + detuneRatio)
        phaseA += dt; if phaseA >= 1 { phaseA -= 1 }
        phaseB += dtB; if phaseB >= 1 { phaseB -= 1 }
        phaseSub += dt * 0.5; if phaseSub >= 1 { phaseSub -= 1 }
        let summed = (morphAB(phaseA, dt, morph) + morphAB(phaseB, dtB, morph)) * 0.5
        return wavefold(summed, timbre)
    }
}

private final class WaveshapeEngine: MacroEngine {
    var phase = 0.0, subPhase = 0.0
    func reset() { phase = 0; subPhase = 0 }
    func render(freq: Double, harmonics: Double, timbre: Double, morph: Double, sampleRate sr: Double) -> Double {
        let dt = freq / sr
        phase += dt; if phase >= 1 { phase -= 1 }
        subPhase += dt * 0.5; if subPhase >= 1 { subPhase -= 1 }
        let body = sin(2 * .pi * phase) + sin(2 * .pi * subPhase) * harmonics * 0.7
        let drive = 1 + timbre * 7
        let driven = body * drive
        let main = sin(driven * .pi * 0.5) * (1 - morph) + tanh(driven) * morph
        return main / max(1, sqrt(drive))
    }
}

private final class FM2OpEngine: MacroEngine {
    var cPhase = 0.0, mPhase = 0.0, cPrev = 0.0
    func reset() { cPhase = 0; mPhase = 0; cPrev = 0 }
    func render(freq: Double, harmonics: Double, timbre: Double, morph: Double, sampleRate sr: Double) -> Double {
        let ratioIdx = Int(max(0, min(Double(FM2_RATIOS.count - 1), floor(harmonics * Double(FM2_RATIOS.count)))))
        let (cRatio, mRatio) = FM2_RATIOS[ratioIdx]
        cPhase += freq * cRatio / sr; if cPhase >= 1 { cPhase -= 1 }
        mPhase += freq * mRatio / sr; if mPhase >= 1 { mPhase -= 1 }
        let mod = sin(2 * .pi * mPhase) * (timbre * 8)
        let carrier = sin(2 * .pi * cPhase + mod + cPrev * (morph * .pi))
        cPrev = carrier
        return carrier * 0.8
    }
}

private final class ChordEngine: MacroEngine {
    var phases = [0.0, 0.0, 0.0, 0.0]
    func reset() { for i in 0..<4 { phases[i] = 0 } }
    func render(freq: Double, harmonics: Double, timbre: Double, morph: Double, sampleRate sr: Double) -> Double {
        let shapeIdx = Int(max(0, min(Double(CHORD_SHAPES.count - 1), floor(harmonics * Double(CHORD_SHAPES.count)))))
        let intervals = CHORD_SHAPES[shapeIdx]
        let detuneCents = morph * 5
        var main = 0.0
        for v in 0..<4 {
            let sign: Double = v % 2 == 0 ? 1 : -1
            let cents = v == 0 ? 0 : sign * detuneCents
            let voiceFreq = min(8000, freq * pow(2, (intervals[v] + cents / 100) / 12))
            phases[v] += voiceFreq / sr; if phases[v] >= 1 { phases[v] -= 1 }
            let t = phases[v]
            let sample = sin(2 * .pi * t) * (1 - timbre) + (2 * t - 1) * timbre
            main += sample * (v == 0 ? 1.0 : morph)
        }
        main /= 1 + 3 * morph
        return main * 0.8
    }
}

private final class StringEngine: MacroEngine {
    var buf = [Double](repeating: 0, count: STRING_MAX_DELAY)
    var bufWrite = 0, lpState = 0.0, apX1 = 0.0, apY1 = 0.0, excAmp = 0.0
    var rng = LCG(0xa5a5a5a5)
    func reset() {
        for i in 0..<STRING_MAX_DELAY { buf[i] = 0 }
        bufWrite = 0; lpState = 0; apX1 = 0; apY1 = 0; excAmp = 1.0
    }
    func render(freq: Double, harmonics: Double, timbre: Double, morph: Double, sampleRate sr: Double) -> Double {
        let delayLen = max(2, min(STRING_MAX_DELAY - 1, Int((sr / freq).rounded())))
        let readIdx = (bufWrite - delayLen + STRING_MAX_DELAY) % STRING_MAX_DELAY
        let delayed = buf[readIdx]
        let burst = excAmp > 0 ? rng.noise() * excAmp : 0
        if excAmp > 0 { excAmp *= exp(-1 / (0.01 * sr)) }
        let burstAlpha = 1 - exp(-2 * .pi * (200 + timbre * 7800) / sr)
        let loopIn = delayed + burst * burstAlpha
        let dampAlpha = 1 - exp(-2 * .pi * (200 + morph * 11800) / sr)
        lpState += dampAlpha * (loopIn - lpState)
        let a = harmonics * 0.5
        let filtered = -a * lpState + apX1 + a * apY1
        apX1 = lpState; apY1 = filtered
        let looped = filtered * 0.998
        buf[bufWrite] = looped
        bufWrite = (bufWrite + 1) % STRING_MAX_DELAY
        return looped
    }
}

private final class ModalEngine: MacroEngine {
    var x1 = [Double](repeating: 0, count: MODAL_MODES)
    var x2 = [Double](repeating: 0, count: MODAL_MODES)
    var y1 = [Double](repeating: 0, count: MODAL_MODES)
    var y2 = [Double](repeating: 0, count: MODAL_MODES)
    var impPhase = 0.0
    func reset() {
        for i in 0..<MODAL_MODES { x1[i] = 0; x2[i] = 0; y1[i] = 0; y2[i] = 0 }
        impPhase = 0
    }
    func render(freq: Double, harmonics: Double, timbre: Double, morph: Double, sampleRate sr: Double) -> Double {
        let preset = MODAL_PRESETS[Int(max(0, min(Double(MODAL_PRESETS.count - 1), floor(harmonics * Double(MODAL_PRESETS.count)))))]
        let q = 5 + timbre * 195
        let impulseEvery = sr / 4
        impPhase += 1
        var impulse = 0.0
        if impPhase >= impulseEvery { impulse = 1.0; impPhase -= impulseEvery }
        var main = 0.0
        for m in 0..<MODAL_MODES {
            let morphAmp = preset.amps[m] * (1 - morph) + (Double(m) / Double(MODAL_MODES)) * morph
            let modeFreq = min(sr * 0.45, freq * preset.ratios[m])
            let w0 = 2 * .pi * modeFreq / sr
            let alpha = sin(w0) / (2 * q)
            let b0 = alpha, b2 = -alpha, a0 = 1 + alpha, a1 = -2 * cos(w0), a2 = 1 - alpha
            let y = (b0 * impulse + b2 * x2[m] - a1 * y1[m] - a2 * y2[m]) / a0
            x2[m] = x1[m]; x1[m] = impulse; y2[m] = y1[m]; y1[m] = y
            main += y * morphAmp
        }
        return main * 0.25
    }
}

private final class KickEngine: MacroEngine {
    var phase = 0.0, pitchEnv = 0.0, ampEnv = 0.0, clickEnv = 0.0
    var rng = LCG(0x12345678)
    func reset() { phase = 0; pitchEnv = 1; ampEnv = 1; clickEnv = 1 }
    func render(freq: Double, harmonics: Double, timbre: Double, morph: Double, sampleRate sr: Double) -> Double {
        pitchEnv *= exp(-1 / (0.03 * sr))
        let currentFreq = min(20000, freq * pow(2, (harmonics * 4) * pitchEnv))
        ampEnv *= exp(-1 / ((0.05 + morph * 1.45) * sr))
        clickEnv *= exp(-1 / (0.003 * sr))
        phase += currentFreq / sr; if phase >= 1 { phase -= 1 }
        let body = sin(2 * .pi * phase) * ampEnv
        let click = rng.noise() * clickEnv * timbre * 0.8
        return body + click
    }
}

private final class SnareEngine: MacroEngine {
    var phaseA = 0.0, phaseB = 0.5, bodyEnv = 0.0, noiseEnv = 0.0, hpState = 0.0
    var rng = LCG(0xfacefeed)
    func reset() { phaseA = 0; phaseB = 0.5; bodyEnv = 1; noiseEnv = 1; hpState = 0 }
    func render(freq: Double, harmonics: Double, timbre: Double, morph: Double, sampleRate sr: Double) -> Double {
        bodyEnv *= exp(-1 / ((0.05 + morph * 0.45) * sr))
        noiseEnv *= exp(-1 / ((0.1 + morph * 0.6) * sr))
        phaseA += freq / sr; if phaseA >= 1 { phaseA -= 1 }
        phaseB += freq * 1.5 / sr; if phaseB >= 1 { phaseB -= 1 }
        let body = (sin(2 * .pi * phaseA) + sin(2 * .pi * phaseB) * 0.5) * bodyEnv * 0.7
        let hpAlpha = 1 - exp(-2 * .pi * (200 + timbre * 4800) / sr)
        let rawNoise = rng.noise()
        hpState += hpAlpha * (rawNoise - hpState)
        let noiseTone = (rawNoise - hpState) * noiseEnv
        return body * (1 - harmonics) + noiseTone * harmonics
    }
}

private final class HihatEngine: MacroEngine {
    var phases = [Double](repeating: 0, count: HIHAT_RATIOS.count)
    var ampEnv = 0.0, bpX1 = 0.0, bpX2 = 0.0, bpY1 = 0.0, bpY2 = 0.0
    var rng = LCG(0xdeadbeef)
    func reset() {
        for i in 0..<HIHAT_RATIOS.count { phases[i] = Double(i + 1) * 0.1 }
        ampEnv = 1; bpX1 = 0; bpX2 = 0; bpY1 = 0; bpY2 = 0
    }
    func render(freq: Double, harmonics: Double, timbre: Double, morph: Double, sampleRate sr: Double) -> Double {
        ampEnv *= exp(-1 / ((0.04 + morph * 0.46) * sr))
        var metallic = 0.0
        for i in 0..<HIHAT_RATIOS.count {
            phases[i] += freq * HIHAT_RATIOS[i] / sr; if phases[i] >= 1 { phases[i] -= 1 }
            metallic += phases[i] < 0.5 ? 1 : -1
        }
        metallic /= Double(HIHAT_RATIOS.count)
        let src = metallic * (1 - timbre) + rng.noise() * timbre
        let w0 = 2 * .pi * (2000 + harmonics * 8000) / sr
        let alpha = sin(w0) / (2 * 0.7)
        let b0 = alpha, b2 = -alpha, a0 = 1 + alpha, a1 = -2 * cos(w0), a2 = 1 - alpha
        let filtered = (b0 * src + b2 * bpX2 - a1 * bpY1 - a2 * bpY2) / a0
        bpX2 = bpX1; bpX1 = src; bpY2 = bpY1; bpY1 = filtered
        return filtered * ampEnv * 0.8
    }
}

@inline(__always)
private func wavetableFrame(_ phase: Double, _ frameIdx: Int, _ secondPhase: Double) -> Double {
    switch frameIdx {
    case 0: return sin(2 * .pi * phase)
    case 1: return 1 - 4 * abs(phase - 0.5)
    case 2: return 2 * phase - 1
    case 3: return phase < 0.5 ? 1 : -1
    case 4: return phase < 0.25 ? 1 : -0.5
    case 5: return ((2 * phase - 1) + (2 * secondPhase - 1)) * 0.5
    case 6:
        var sum = 0.0
        var k = 1
        while k <= 7 { sum += sin(2 * .pi * Double(k) * phase) / Double(k * k); k += 2 }
        return sum
    case 7:
        let i = floor(phase * 64)
        let x = sin(i * 12.9898) * 43758.5453
        return (x - floor(x)) * 2 - 1
    default: return 0
    }
}

private final class WavetableEngine: MacroEngine {
    var phase = 0.0, secondPhase = 0.0, lpState = 0.0
    func reset() { phase = 0; secondPhase = 0; lpState = 0 }
    func render(freq: Double, harmonics: Double, timbre: Double, morph: Double, sampleRate sr: Double) -> Double {
        phase += freq / sr; if phase >= 1 { phase -= 1 }
        secondPhase += freq * 1.01 / sr; if secondPhase >= 1 { secondPhase -= 1 }
        let frameF = harmonics * 7
        let frameLo = Int(floor(frameF))
        let frameHi = min(7, frameLo + 1)
        let blend = frameF - Double(frameLo)
        let warpDen = 1 - (morph - 0.5)
        let morphPhase = morph < 0.5 ? phase : (phase < warpDen ? phase / warpDen : 1)
        let morphSecond = morph < 0.5 ? secondPhase : (secondPhase < warpDen ? secondPhase / warpDen : 1)
        let wLo = wavetableFrame(morphPhase, frameLo, morphSecond)
        let wHi = wavetableFrame(morphPhase, frameHi, morphSecond)
        let raw = wLo * (1 - blend) + wHi * blend
        let alpha = 1 - exp(-2 * .pi * (200 + timbre * 11800) / sr)
        lpState += alpha * (raw - lpState)
        return lpState
    }
}

private final class GranularEngine: MacroEngine {
    private struct Grain { var active = false; var pos = 0.0; var length = 0.0; var pitchMul = 1.0; var phase = 0.0 }
    private var grains = [Grain](repeating: Grain(), count: GRAN_MAX_GRAINS)
    var spawnTimer = 0.0
    var rng = LCG(0xcafef00d)
    func reset() { for i in grains.indices { grains[i] = Grain() }; spawnTimer = 0 }
    private func grainEnv(_ pos: Double, _ length: Double, _ morph: Double) -> Double {
        let t = pos / length
        if t < 0 || t >= 1 { return 0 }
        if morph < 0.33 { return 1 }
        if morph < 0.66 { return 1 - abs(2 * t - 1) }
        return 0.5 - 0.5 * cos(2 * .pi * t)
    }
    func render(freq: Double, harmonics: Double, timbre: Double, morph: Double, sampleRate sr: Double) -> Double {
        let spawnEvery = sr / (5 + harmonics * 195)
        spawnTimer += 1
        if spawnTimer >= spawnEvery {
            spawnTimer -= spawnEvery
            for i in grains.indices where !grains[i].active {
                grains[i].active = true
                grains[i].pos = 0
                grains[i].length = floor(0.01 * sr)
                grains[i].pitchMul = 1 + (rng.rand() * 2 - 1) * timbre * 0.06
                grains[i].phase = rng.rand()
                break
            }
        }
        var main = 0.0
        var activeCount = 0
        for i in grains.indices where grains[i].active {
            let env = grainEnv(grains[i].pos, grains[i].length, morph)
            grains[i].phase += freq * grains[i].pitchMul / sr
            if grains[i].phase >= 1 { grains[i].phase -= 1 }
            main += sin(2 * .pi * grains[i].phase) * env
            activeCount += 1
            grains[i].pos += 1
            if grains[i].pos >= grains[i].length { grains[i].active = false }
        }
        if activeCount > 1 { main /= sqrt(Double(activeCount)) }
        return main * 0.7
    }
}

private final class SpeechEngine: MacroEngine {
    var phase = 0.0
    var x1 = [0.0, 0.0, 0.0], x2 = [0.0, 0.0, 0.0], y1 = [0.0, 0.0, 0.0], y2 = [0.0, 0.0, 0.0]
    var rng = LCG(0x1badc0de)
    func reset() { phase = 0; for i in 0..<3 { x1[i] = 0; x2[i] = 0; y1[i] = 0; y2[i] = 0 } }
    private func glottal(_ t: Double) -> Double {
        if t < 0.3 { return sin(.pi * (t / 0.3)) }
        if t < 0.5 { return -0.3 * sin(.pi * ((t - 0.3) / 0.2)) }
        return 0
    }
    func render(freq: Double, harmonics: Double, timbre: Double, morph: Double, sampleRate sr: Double) -> Double {
        let vowel = VOWEL_PRESETS[Int(max(0, min(Double(VOWEL_PRESETS.count - 1), floor(harmonics * Double(VOWEL_PRESETS.count)))))]
        let q = 3 + timbre * 37
        phase += freq / sr; if phase >= 1 { phase -= 1 }
        let pulse = glottal(phase)
        let src = pulse * (1 - morph) + rng.noise() * morph * 0.5
        var main = 0.0
        for i in 0..<3 {
            let w0 = 2 * .pi * vowel.f[i] / sr
            let alpha = sin(w0) / (2 * q)
            let b0 = alpha, b2 = -alpha, a0 = 1 + alpha, a1 = -2 * cos(w0), a2 = 1 - alpha
            let y = (b0 * src + b2 * x2[i] - a1 * y1[i] - a2 * y2[i]) / a0
            x2[i] = x1[i]; x1[i] = src; y2[i] = y1[i]; y1[i] = y
            main += y * vowel.g[i]
        }
        return main * 4.0
    }
}

private final class AdditiveEngine: MacroEngine {
    var phases = [Double](repeating: 0, count: ADDITIVE_PARTIALS)
    func reset() { for i in 0..<ADDITIVE_PARTIALS { phases[i] = 0 } }
    func render(freq: Double, harmonics: Double, timbre: Double, morph: Double, sampleRate sr: Double) -> Double {
        var main = 0.0, normSum = 0.0
        let tiltExp = 0.5 + 1.5 * timbre
        for p in 0..<ADDITIVE_PARTIALS {
            let n = Double(p + 1)
            let partialFreq = n * freq * (1 + harmonics * 0.1 * (n - 1))
            if partialFreq >= sr * 0.5 { continue }
            phases[p] += partialFreq / sr; if phases[p] >= 1 { phases[p] -= 1 }
            var amp = 1 / pow(n, tiltExp)
            amp *= (p % 2 == 0) ? (1 - morph) : morph   // n odd (p even) → (1-morph)
            main += sin(2 * .pi * phases[p]) * amp
            normSum += amp
        }
        if normSum > 1 { main /= normSum }
        return main * 0.9
    }
}

private final class FM6OpEngine: MacroEngine {
    var phases = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
    var fbkPrev = 0.0
    var envs = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
    func reset() { for i in 0..<6 { phases[i] = 0; envs[i] = 1 }; fbkPrev = 0 }
    func render(freq: Double, harmonics: Double, timbre: Double, morph: Double, sampleRate sr: Double) -> Double {
        let ratioScale = 0.25 + harmonics * 0.75
        let decayCoef = exp(-1 / ((0.05 * pow(100, morph)) * sr))
        for i in 0..<6 {
            let ratio = i == 0 ? 1.0 : FM6_BASE_RATIOS[i] * ratioScale
            phases[i] += freq * ratio / sr; if phases[i] >= 1 { phases[i] -= 1 }
            envs[i] *= decayCoef
        }
        let modIndex = timbre * 6
        let fbk = sin(2 * .pi * phases[5] + fbkPrev * (0.5 * modIndex)) * envs[5]
        fbkPrev = fbk
        let op4 = sin(2 * .pi * phases[4]) * envs[4] * modIndex * 0.5
        let op3 = sin(2 * .pi * phases[3] + op4) * envs[3] * modIndex * 0.5
        let op2 = sin(2 * .pi * phases[2] + op3) * envs[2] * modIndex * 0.5
        let op1 = sin(2 * .pi * phases[1] + op2) * envs[1] * modIndex * 0.5
        let carrier = sin(2 * .pi * phases[0] + op1 + fbk * 0.5) * envs[0]
        return carrier * 0.7
    }
}

// MARK: - Voice

/// Monophonic macro-oscillator voice. Holds one instance of every engine
/// (so per-model state persists across switches) but ticks ONLY the active
/// model each sample. Pitch + model are set per note from the sequencer;
/// harmonics/timbre/morph/level are global macros set from the UI / LFO.
final class MacroVoice {
    // Global macros (main thread writes, audio thread reads + smooths).
    var harmonics: Double = 0.3
    var timbre: Double = 0.3
    var morph: Double = 0.3
    var level: Double = 0.8

    private var sr: Double
    private let engines: [MacroEngine]
    private var model: MacroModel = .va
    private var currentFreq: Double = 261.6256

    private var smH = 0.3, smT = 0.3, smM = 0.3, smLevel = 0.8
    private var smoothCoeff: Double

    init(sampleRate: Double) {
        sr = sampleRate
        engines = [
            VAEngine(), WaveshapeEngine(), FM2OpEngine(), FM6OpEngine(),
            ChordEngine(), AdditiveEngine(), StringEngine(), ModalEngine(),
            KickEngine(), SnareEngine(), HihatEngine(), WavetableEngine(),
            GranularEngine(), SpeechEngine(),
        ]
        smoothCoeff = exp(-2 * .pi * 80 / sr)
        for e in engines { e.reset() }
    }

    func setSampleRate(_ newSr: Double) {
        guard newSr > 0, abs(newSr - sr) > 0.5 else { return }
        sr = newSr
        smoothCoeff = exp(-2 * .pi * 80 / sr)
    }

    /// Trigger a step: select the model + pitch. Percussive/plucked engines
    /// re-excite on the gate; tonal engines continue (no click).
    func noteOn(midiNote: Int, model: MacroModel) {
        self.model = model
        currentFreq = min(20000, max(1, 261.6256 * pow(2, Double(midiNote - 60) / 12)))
        if model.retriggersOnGate { engines[model.rawValue].reset() }
    }

    func noteOff() {}

    func reset() { for e in engines { e.reset() } }

    @inline(__always)
    func nextSample() -> Double {
        let a = 1 - smoothCoeff
        smH += a * (harmonics - smH)
        smT += a * (timbre - smT)
        smM += a * (morph - smM)
        smLevel += a * (level - smLevel)
        let s = engines[model.rawValue].render(freq: currentFreq,
                                                harmonics: clamp(smH, 0, 1),
                                                timbre: clamp(smT, 0, 1),
                                                morph: clamp(smM, 0, 1),
                                                sampleRate: sr)
        return s * smLevel
    }
}
