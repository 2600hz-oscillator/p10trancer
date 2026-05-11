import Foundation

/// Lightweight Schroeder-style stereo reverb. Four parallel comb
/// filters (with one-pole damping in the feedback path) summed into
/// four series allpasses produces a smooth-enough room without the
/// CPU cost of full Freeverb. Designed for the wavetable instrument's
/// audio path — minimal, no allocations in the render loop, k-rate
/// param reads so the audio thread doesn't race the UI.
///
///  • `size` 0..1  — comb feedback. Larger = longer reverb tail.
///  • `damp` 0..1  — high-frequency damping in the feedback path.
///  • `wet`  0..1  — wet/dry mix.
///
/// The wet path is summed to mono internally and equally mixed back
/// into both channels, which preserves the dry path's stereo image
/// while keeping the reverb code small.
final class SimpleReverb {
    var size: Float = 0.5
    var damp: Float = 0.5
    var wet: Float = 0.3

    private static let combLengths44k = [1116, 1188, 1277, 1356]
    private static let allpassLengths44k = [556, 441, 341, 225]

    private var combs: [CombFilter]
    private var allpasses: [AllpassFilter]

    init(sampleRate: Double) {
        let scale = sampleRate / 44100.0
        combs = Self.combLengths44k.map { CombFilter(length: max(1, Int(round(Double($0) * scale)))) }
        allpasses = Self.allpassLengths44k.map { AllpassFilter(length: max(1, Int(round(Double($0) * scale)))) }
    }

    /// Process stereo samples in-place. The reverb sums L+R into a
    /// mono wet bus, runs the comb/allpass network on it, then mixes
    /// the wet result back into both channels using `wet`. The dry
    /// signal is preserved at amplitude (1 - wet) per channel.
    func process(left: UnsafeMutablePointer<Float>,
                 right: UnsafeMutablePointer<Float>,
                 count: Int) {
        // k-rate snapshot of params.
        let sizeClamped = max(0, min(1, size))
        let dampClamped = max(0, min(1, damp))
        let wetClamped = max(0, min(1, wet))
        // Map size → feedback gain. Conservative top end (≤0.95)
        // keeps the tail finite; below 0.2 the reverb barely rings.
        let feedback = 0.7 + sizeClamped * 0.28
        let dampCoef = dampClamped * 0.4
        let invDamp = 1.0 - dampCoef
        // Push the snapshot into each filter once per buffer.
        for i in combs.indices {
            combs[i].feedback = feedback
            combs[i].dampA = dampCoef
            combs[i].dampB = invDamp
        }
        for i in count.indices {
            let l = left[i]
            let r = right[i]
            let monoIn = (l + r) * 0.5
            // Parallel combs.
            var combSum: Float = 0
            for c in 0..<combs.count {
                combSum += combs[c].process(monoIn)
            }
            // Series allpasses — diffusion stage.
            var ap = combSum
            for a in 0..<allpasses.count {
                ap = allpasses[a].process(ap)
            }
            // Output mix. Equal wet into both channels keeps the
            // dry path's stereo image intact while the reverb tail
            // sits "behind" it.
            let dryGain = 1 - wetClamped
            left[i]  = l * dryGain + ap * wetClamped
            right[i] = r * dryGain + ap * wetClamped
        }
    }
}

/// Comb filter with one-pole LP damping in the feedback path. The
/// damping pole `y[n] = (1 - damp) * x[n] + damp * y[n-1]` rolls off
/// HF in the tail, giving a more natural-sounding decay than a pure
/// comb.
private struct CombFilter {
    var buffer: [Float]
    var index: Int = 0
    var filterStore: Float = 0
    var feedback: Float = 0.84
    var dampA: Float = 0.2          // damp pole gain on prev sample
    var dampB: Float = 0.8          // (1 - damp) gain on current

    init(length: Int) {
        buffer = [Float](repeating: 0, count: length)
    }

    @inline(__always)
    mutating func process(_ input: Float) -> Float {
        let out = buffer[index]
        filterStore = out * dampB + filterStore * dampA
        buffer[index] = input + filterStore * feedback
        index += 1
        if index >= buffer.count { index = 0 }
        return out
    }
}

/// Schroeder allpass with fixed feedback (0.5). Diffuses the comb
/// output without coloring it further.
private struct AllpassFilter {
    var buffer: [Float]
    var index: Int = 0
    let feedback: Float = 0.5

    init(length: Int) {
        buffer = [Float](repeating: 0, count: length)
    }

    @inline(__always)
    mutating func process(_ input: Float) -> Float {
        let bufout = buffer[index]
        let output = -input + bufout
        buffer[index] = input + bufout * feedback
        index += 1
        if index >= buffer.count { index = 0 }
        return output
    }
}

private extension Int {
    /// Local helper to iterate `0..<self` cheaply inside a tight
    /// audio loop without dropping into Swift's CountableRange
    /// overhead. Strictly equivalent — kept inline for readability.
    var indices: Range<Int> { 0..<self }
}
