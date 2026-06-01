import Foundation

// TB-303 voice — Swift port of inet.modular's TreeOhVox (treeohvox-dsp.ts),
// itself a slice of Robin Schmidt's Open303 (MIT). Powers the ACIDBASS pad
// instrument.
//
// FIDELITY: every coefficient/filter/envelope value is Double. The
// tb303Coeffs 6th-order Horner polynomial and the envModScalerOffset
// constants are calibrated for Float64 — using Float audibly shifts the
// resonance / self-oscillation shape and the env-mod sweep range. Only the
// final per-sample output is narrowed to Float.
//
// Ported verbatim from the reference: TbVoxFeedbackHp, TbVoxFilter (TB_303
// diode-feedback ladder), TbVoxDecayEnv, TbVoxAmpEnv, PolyBlepOsc (saw),
// tb303Coeffs / resonanceSkew / envModScalerOffset / pitchCvToFreq. Added
// on top (not in the reference slice): a band-limited square + saw↔square
// morph, slide/glide, and a post-filter overdrive.

// MARK: - Free functions / constants

let kTB303_C4_HZ: Double = 261.6255653005986

@inline(__always)
func tb303PitchCvToFreq(_ voltCv: Double, _ tuneSemitones: Double) -> Double {
    kTB303_C4_HZ * pow(2.0, voltCv + tuneSemitones / 12.0)
}

private let kTB303_SKEW_DENOM = 1.0 - exp(-3.0)

/// Exponential resonance skew (rosic setResonance): skew(0)=0, skew(0.5)=0.8176, skew(1)=1.
@inline(__always)
func tb303ResonanceSkew(_ resRaw01: Double) -> Double {
    let r = min(max(resRaw01, 0), 1)
    return (1 - exp(-3 * r)) / kTB303_SKEW_DENOM
}

struct TB303Coeffs { var b0: Double; var g: Double; var k: Double }

/// TB_303 branch of rosic::TeeBeeFilter::calculateCoefficientsApprox4().
/// resSkewed is already exp-skewed (pass through tb303ResonanceSkew first).
func tb303Coeffs(cutoffHz: Double, resSkewed: Double, sampleRate sr: Double) -> TB303Coeffs {
    var cutoff = cutoffHz
    if cutoff < 200 { cutoff = 200 } else if cutoff > 20000 { cutoff = 20000 }

    let oneOverSqrt2 = 1.0 / 2.0.squareRoot()
    let wc = (2.0 * Double.pi * cutoff) / sr
    let fx = (wc * oneOverSqrt2) / (2.0 * Double.pi)

    let b0 = (0.00045522346 + 6.1922189 * fx) / (1.0 + 12.358354 * fx + 4.4156345 * fx * fx)

    // 6th-order Horner — literals copied bit-for-bit from upstream.
    var k = fx * (fx * (fx * (fx * (fx * (fx + 7198.6997) - 5837.7917) - 476.47308) + 614.95611) + 213.87126) + 16.998792

    var g = k / 17.0
    let r = min(max(resSkewed, 0), 1)
    g = (g - 1.0) * r + 1.0
    g = g * (1.0 + r)
    k = k * r

    return TB303Coeffs(b0: b0, g: g, k: k)
}

struct TB303EnvModMap { var scaler: Double; var offset: Double }

private let kEnvModC0   = 3.138152786059267e+002
private let kEnvModC1   = 2.394411986817546e+003
private let kEnvModOF   = 0.048292930943553
private let kEnvModOC   = 0.294391201442418
private let kEnvModSLOF = 3.773996325111173
private let kEnvModSLOC = 0.736965594166206
private let kEnvModSHIF = 4.194548788411135
private let kEnvModSHIC = 0.864344900642434

/// rosic::Open303::calculateEnvModScalerAndOffset() (measured mapping).
/// envModPercent is 0..100 (envAmount01 * 100).
func tb303EnvModScalerOffset(cutoffHz: Double, envModPercent: Double) -> TB303EnvModMap {
    let e = envModPercent / 100.0
    let c = log(cutoffHz / kEnvModC0) / log(kEnvModC1 / kEnvModC0)
    let cc = min(max(c, 0), 1)
    let sLo = kEnvModSLOF * e + kEnvModSLOC
    let sHi = kEnvModSHIF * e + kEnvModSHIC
    return TB303EnvModMap(scaler: (1 - cc) * sLo + cc * sHi,
                          offset: kEnvModOF * cc + kEnvModOC)
}

// MARK: - DSP primitives

/// 150 Hz one-pole highpass in the filter feedback path.
struct TbVoxFeedbackHp {
    private var a1 = 0.0
    private var b0 = 0.5
    private var x1 = 0.0
    private var y1 = 0.0

    init(sampleRate sr: Double, cutoffHz: Double = 150) { setCutoff(cutoffHz, sampleRate: sr) }

    mutating func setCutoff(_ cutoffHz: Double, sampleRate sr: Double) {
        let t = tan(Double.pi * cutoffHz / sr)
        let a = 1.0 / (1.0 + t)
        b0 = a
        a1 = -a * (1.0 - t)
    }
    mutating func reset() { x1 = 0; y1 = 0 }
    mutating func step(_ x: Double) -> Double {
        let y = b0 * (x - x1) - a1 * y1
        x1 = x; y1 = y
        return y
    }
}

/// TB_303 diode-feedback ladder (rosic::TeeBeeFilter, TB_303 mode).
struct TbVoxFilter {
    private var y1 = 0.0, y2 = 0.0, y3 = 0.0, y4 = 0.0
    private var b0 = 0.0, g = 1.0, k = 0.0
    private var feedbackHp: TbVoxFeedbackHp
    private let sr: Double

    init(sampleRate sr: Double) {
        self.sr = sr
        feedbackHp = TbVoxFeedbackHp(sampleRate: sr)
    }
    mutating func reset() { y1 = 0; y2 = 0; y3 = 0; y4 = 0; feedbackHp.reset() }

    /// Recompute coefficients. resRaw01 is the raw 0..1 knob (skewed inside).
    mutating func setCutoffRes(_ cutoffHz: Double, _ resRaw01: Double) {
        let c = tb303Coeffs(cutoffHz: cutoffHz, resSkewed: tb303ResonanceSkew(resRaw01), sampleRate: sr)
        b0 = c.b0; g = c.g; k = c.k
    }
    mutating func step(_ input: Double) -> Double {
        let y0 = input - feedbackHp.step(k * y4)
        y1 += 2.0 * b0 * (y0 - y1 + y2)
        y2 += b0 * (y1 - 2.0 * y2 + y3)
        y3 += b0 * (y2 - 2.0 * y3 + y4)
        y4 += b0 * (y3 - 2.0 * y4)
        return 2.0 * g * y4
    }
}

/// Single-decay filter envelope (y *= c). decays to 1/e in decayMs.
struct TbVoxDecayEnv {
    private var y = 0.0
    private var c = 0.0
    private let sr: Double

    init(sampleRate sr: Double, decayMs: Double = 600) { self.sr = sr; setDecay(decayMs) }
    mutating func setDecay(_ decayMs: Double) {
        let tauSamples = max(0.1, decayMs) * 1e-3 * sr
        c = exp(-1.0 / tauSamples)
    }
    mutating func trigger() { y = 1.0 }
    func peek() -> Double { y }
    mutating func step() -> Double { let out = y; y *= c; return out }
}

/// Attack-decay amp envelope (fixed fast attack + long decay; no sustain).
struct TbVoxAmpEnv {
    private var y = 0.0
    private var peak = 1.0
    private var attackCoeff = 0.0
    private var decayCoeff = 0.0
    private var inAttack = false
    private var samplesInPhase = 0
    private var attackSamples = 1
    private var active = false
    private let sr: Double

    init(sampleRate sr: Double, attackMs: Double = 3, decayMs: Double = 1230) {
        self.sr = sr; setAttack(attackMs); setDecay(decayMs)
    }
    mutating func setAttack(_ attackMs: Double) {
        let tau = max(0.1, attackMs) * 1e-3 * sr
        attackCoeff = 1.0 - exp(-1.0 / tau)
        attackSamples = max(1, Int((sr * max(0.1, attackMs) * 1e-3).rounded()))
    }
    mutating func setDecay(_ decayMs: Double) {
        let tau = max(0.1, decayMs) * 1e-3 * sr
        decayCoeff = 1.0 - exp(-1.0 / tau)
    }
    /// peakLevel is 1 for normal notes, >1 for accented (amp boost).
    mutating func trigger(_ peakLevel: Double = 1) {
        peak = peakLevel; inAttack = true; samplesInPhase = 0; active = true
        // Do NOT zero y — glide from current level keeps retriggers click-free.
    }
    var isActive: Bool { active && y > 1e-6 }
    mutating func step() -> Double {
        if inAttack {
            y += attackCoeff * (peak - y)
            samplesInPhase += 1
            if samplesInPhase >= attackSamples { inAttack = false }
        } else {
            y += decayCoeff * (0 - y)
            if y < 1e-6 { y = 0; active = false }
        }
        return y
    }
}

/// PolyBLEP oscillator with a continuous saw↔square morph (morph 0 = saw,
/// 1 = square). The saw path is the verbatim reference; the square path +
/// blend are added for ACIDBASS.
struct PolyBlepOsc {
    private var phase = 0.0
    private let sr: Double

    init(sampleRate sr: Double) { self.sr = sr }
    mutating func resetPhase() { phase = 0 }

    @inline(__always) private func blep(_ t: Double, _ dt: Double) -> Double {
        if t < dt { let x = t / dt; return x + x - x * x - 1.0 }
        if t > 1.0 - dt { let x = (t - 1.0) / dt; return x * x + x + x + 1.0 }
        return 0.0
    }

    mutating func step(_ freqHz: Double, morph: Double) -> Double {
        let dt = freqHz / sr
        let t = phase
        let saw = (2.0 * t - 1.0) - blep(t, dt)
        var sq = (t < 0.5 ? 1.0 : -1.0) + blep(t, dt)
        var t2 = t + 0.5
        if t2 >= 1.0 { t2 -= 1.0 }
        sq -= blep(t2, dt)
        let out = (1.0 - morph) * saw + morph * sq
        var next = t + dt
        if next >= 1.0 { next -= 1.0 }
        phase = next
        return out
    }
}

// MARK: - Assembled voice

/// Monophonic TB-303 voice. Knob properties are written from the main thread
/// and read (then one-pole smoothed at ~80 Hz) from the audio thread; this
/// matches the existing WaspFilter k-rate-snapshot precedent. Note triggers
/// come from the sequencer via noteOn(); 303 rests are simply "no trigger"
/// (the amp env keeps decaying — authentic behavior).
final class TB303Voice {
    // Continuous knobs (main thread writes, audio thread reads).
    var tuneSemitones: Double = 0      // -12 ... 12
    var cutoffHz: Double = 1000        // 40 ... 6000
    var resonance: Double = 0.5        // 0 ... 1 (raw)
    var envAmount01: Double = 0.5      // 0 ... 1 -> envMod 0..100%
    var decayMs: Double = 600          // 50 ... 3000 (filter env only)
    var accentAmount01: Double = 0.5   // 0 ... 1
    var waveform: Double = 0           // 0 saw ... 1 square
    var overdrive: Double = 0          // 0 ... 1 (post-filter soft clip)
    var glideTime: Double = 0.06       // seconds

    private let sr: Double
    private var osc: PolyBlepOsc
    private var filter: TbVoxFilter
    private var decayEnv: TbVoxDecayEnv
    private var ampEnv: TbVoxAmpEnv

    // Smoothed audio-thread copies of the continuous knobs.
    private var smCutoff: Double
    private var smResonance: Double
    private var smEnv: Double
    private var smDecay: Double
    private var smTune: Double
    private var smWaveform: Double
    private var smOverdrive: Double
    private let smoothCoeff: Double

    // Note state.
    private var currentNoteCv: Double = 0
    private var currentFreq: Double
    private var glideActive = false
    private var accentGain = 0.0

    init(sampleRate: Double) {
        sr = sampleRate
        osc = PolyBlepOsc(sampleRate: sr)
        filter = TbVoxFilter(sampleRate: sr)
        decayEnv = TbVoxDecayEnv(sampleRate: sr, decayMs: 600)
        ampEnv = TbVoxAmpEnv(sampleRate: sr, attackMs: 3, decayMs: 1230)
        smCutoff = 1000; smResonance = 0.5; smEnv = 0.5; smDecay = 600
        smTune = 0; smWaveform = 0; smOverdrive = 0
        smoothCoeff = exp(-2.0 * Double.pi * 80.0 / sr)   // 80 Hz one-pole
        currentFreq = kTB303_C4_HZ
        filter.setCutoffRes(1000, 0.5)
    }

    /// Trigger a step. `glide` true means tie/slide INTO this note (pitch
    /// glides from the current note, envelopes are NOT retriggered) — the
    /// sequencer passes glide = (previous step had slide).
    func noteOn(noteCv: Double, accented: Bool, glide: Bool) {
        currentNoteCv = noteCv
        if glide {
            glideActive = true
            accentGain = accented ? accentAmount01 : 0
            // no phase reset, no envelope retrigger (legato)
        } else {
            currentFreq = tb303PitchCvToFreq(noteCv, tuneSemitones)
            glideActive = false
            osc.resetPhase()
            filter.reset()
            decayEnv.trigger()
            ampEnv.trigger(accented ? 1.0 + accentAmount01 : 1.0)
            accentGain = accented ? accentAmount01 : 0
        }
    }

    /// 303s have no user gate-off; a rest just stops triggering. Provided for
    /// API symmetry / future use.
    func noteOff() {}

    /// Silence everything (used when the pad stops).
    func reset() {
        filter.reset()
        decayEnv = TbVoxDecayEnv(sampleRate: sr, decayMs: smDecay)
        ampEnv = TbVoxAmpEnv(sampleRate: sr, attackMs: 3, decayMs: 1230)
        osc.resetPhase()
        glideActive = false
        accentGain = 0
    }

    var isActive: Bool { ampEnv.isActive }

    /// One sample of voice output. Inlines the reference TreeohvoxVoice.step
    /// plus the morph/glide/overdrive additions.
    @inline(__always)
    func nextSample() -> Double {
        // Smooth continuous knobs toward their targets (80 Hz one-pole).
        let a = 1.0 - smoothCoeff
        smCutoff += a * (cutoffHz - smCutoff)
        smResonance += a * (resonance - smResonance)
        smEnv += a * (envAmount01 - smEnv)
        smDecay += a * (decayMs - smDecay)
        smTune += a * (tuneSemitones - smTune)
        smWaveform += a * (waveform - smWaveform)
        smOverdrive += a * (overdrive - smOverdrive)

        decayEnv.setDecay(smDecay)

        // Pitch (tracks tune continuously; glides on slide).
        let target = tb303PitchCvToFreq(currentNoteCv, smTune)
        if glideActive {
            let gc = exp(-1.0 / (max(0.001, glideTime) * sr))
            currentFreq = target + (currentFreq - target) * gc
            if abs(currentFreq - target) < 0.01 { currentFreq = target; glideActive = false }
        } else {
            currentFreq = target
        }

        let env = decayEnv.step()
        let map = tb303EnvModScalerOffset(cutoffHz: smCutoff, envModPercent: smEnv * 100.0)
        let cutoffMod = map.scaler * (env - map.offset) + accentGain * env
        var instCutoff = smCutoff * pow(2.0, cutoffMod)
        if instCutoff < 200 { instCutoff = 200 } else if instCutoff > 20000 { instCutoff = 20000 }
        filter.setCutoffRes(instCutoff, smResonance)

        let oscOut = -osc.step(currentFreq, morph: min(max(smWaveform, 0), 1))
        var filtered = filter.step(oscOut)

        if smOverdrive > 1e-4 {
            let drive = 1.0 + smOverdrive * 6.0
            let wet = tanh(filtered * drive)
            filtered = filtered * (1.0 - smOverdrive) + wet * smOverdrive
        }

        return filtered * ampEnv.step()
    }
}
