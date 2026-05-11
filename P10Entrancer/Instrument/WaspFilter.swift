import Foundation

/// State-variable multimode filter with `tanh` saturation in the
/// resonance feedback path, loosely modeled on the Doepfer A-124
/// Wasp's CMOS-inverter character. Three outputs (LP/HP/BP) tap
/// different points of the same topology; a `mode` switch picks which
/// one we route. 12 dB/oct.
///
/// All public params can be written from the main thread; the audio
/// thread snapshots them once per buffer (k-rate). Cutoff is in Hz,
/// resonance is 0..1 (0 = flat, 1 = self-oscillation threshold).
///
/// Process is stereo via two independent instances of the same
/// topology (one per channel) so the per-channel state doesn't
/// crosstalk through the feedback.
final class WaspFilter {
    enum Mode: Int { case lowpass = 0, highpass = 1, bandpass = 2 }

    var mode: Mode = .lowpass
    /// Cutoff in Hz. Clamped at render time to [10, sampleRate/2].
    var cutoffHz: Float = 8000
    /// 0..1; mapped to a Q in 0.5..15 with `tanh` soft clip in the
    /// feedback path so high values dirty up like the Wasp rather
    /// than ringing forever.
    var resonance: Float = 0

    /// State for the two SVF integrators, per channel.
    private var lBuf1: Float = 0
    private var lBuf2: Float = 0
    private var rBuf1: Float = 0
    private var rBuf2: Float = 0

    func process(left: UnsafeMutablePointer<Float>,
                 right: UnsafeMutablePointer<Float>,
                 count: Int,
                 sampleRate: Double) {
        let sr = Float(sampleRate)
        let nyquist = sr * 0.5
        let cutoff = max(10, min(nyquist - 100, cutoffHz))
        // SVF "f" coefficient ≈ 2*sin(π*fc/sr). Clamped so the
        // discrete approximation stays stable.
        let f = min(1.5, 2 * sin(.pi * cutoff / sr))
        let resClamped = max(0, min(1, resonance))
        let q = 0.5 + (1 - resClamped) * 14.5  // Q in [0.5, 15]
        // Feedback gain = 1/Q. Lower Q = more feedback subtraction = more flat.
        let fb = 1 / q
        let m = mode

        for i in 0..<count {
            let l = left[i]
            let r = right[i]
            left[i]  = svfStep(input: l, f: f, fb: fb, buf1: &lBuf1, buf2: &lBuf2, mode: m)
            right[i] = svfStep(input: r, f: f, fb: fb, buf1: &rBuf1, buf2: &rBuf2, mode: m)
        }
    }

    /// One sample of the SVF. `buf1` accumulates band-pass, `buf2`
    /// accumulates low-pass; high-pass falls out as the residual.
    /// `tanh` soft-clip on the band-pass feedback gives the Wasp's
    /// characteristic snarl at high resonance — without it the
    /// filter would either ring forever or blow up at resonance = 1.
    @inline(__always)
    private func svfStep(input: Float,
                          f: Float, fb: Float,
                          buf1: inout Float, buf2: inout Float,
                          mode: Mode) -> Float {
        let saturatedFb = tanhf(buf1 * fb)
        let highpass = input - buf2 - saturatedFb
        buf1 += f * highpass
        let bandpass = buf1
        buf2 += f * bandpass
        let lowpass = buf2
        switch mode {
        case .lowpass:  return lowpass
        case .highpass: return highpass
        case .bandpass: return bandpass
        }
    }

    func reset() {
        lBuf1 = 0; lBuf2 = 0
        rBuf1 = 0; rBuf2 = 0
    }
}
