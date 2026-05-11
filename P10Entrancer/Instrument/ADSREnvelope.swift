import Foundation

/// Standard 4-stage envelope. Gate-on advances attack → decay → sustain
/// (held until gate-off); gate-off triggers release back to 0. Times
/// are in seconds; sustain is the 0..1 level held between decay and
/// release. The render method is real-time safe and multiplies the
/// envelope into an existing output buffer in-place.
///
/// State (stage + level) only mutates inside renderBlock or in the
/// gate setter — both are called from the audio thread or the sequencer
/// thread respectively. The sequencer writes gateOn on the main thread
/// and the render block reads it; for an MVP we accept the tiny race
/// since a one-sample mis-timed transition is inaudible.
final class ADSREnvelope {
    enum Stage { case idle, attack, decay, sustain, release }

    var attack: Float = 0.005   // seconds
    var decay: Float = 0.1
    var sustain: Float = 0.7
    var release: Float = 0.3

    private var gateOn: Bool = false
    private var stage: Stage = .idle
    private var level: Float = 0

    /// Set the gate. Transitioning false→true restarts attack; true→
    /// false triggers release from whatever the current level is.
    func setGate(_ on: Bool) {
        if on, !gateOn {
            stage = .attack
        } else if !on, gateOn {
            stage = .release
        }
        gateOn = on
    }

    /// True once the envelope has rendered all the way back to zero
    /// after a gate-off — useful for the sequencer to know "this step
    /// is fully silent now, safe to retrigger".
    var isIdle: Bool { stage == .idle }

    /// Multiply `count` samples in `buffer` by the envelope in-place.
    /// Advances envelope state by `count` samples.
    func applyBlock(buffer: UnsafeMutablePointer<Float>, count: Int, sampleRate: Double) {
        renderInto(buffer: buffer, count: count, sampleRate: sampleRate, multiply: true)
    }

    /// Fill `buffer` with the envelope shape directly (no input
    /// multiplication). Useful when applying the same envelope to
    /// multiple channels — render once, multiply L + R by the buffer.
    /// Advances envelope state by `count` samples.
    func fillEnvelope(into buffer: UnsafeMutablePointer<Float>, count: Int, sampleRate: Double) {
        renderInto(buffer: buffer, count: count, sampleRate: sampleRate, multiply: false)
    }

    @inline(__always)
    private func renderInto(buffer: UnsafeMutablePointer<Float>,
                            count: Int,
                            sampleRate: Double,
                            multiply: Bool) {
        let sr = Float(sampleRate)
        for i in 0..<count {
            switch stage {
            case .idle:
                level = 0
            case .attack:
                let inc = 1.0 / max(0.0001, attack * sr)
                level += inc
                if level >= 1 { level = 1; stage = .decay }
            case .decay:
                let inc = (sustain - 1.0) / max(0.0001, decay * sr)
                level += inc
                if level <= sustain { level = sustain; stage = .sustain }
            case .sustain:
                level = sustain
            case .release:
                let inc = -level / max(0.0001, release * sr)
                level += inc
                if level <= 0.0001 { level = 0; stage = .idle }
            }
            if multiply { buffer[i] *= level } else { buffer[i] = level }
        }
    }

    /// Immediately silence the envelope (used when the instrument is
    /// stopped wholesale, not from gate-off).
    func reset() {
        gateOn = false
        stage = .idle
        level = 0
    }
}
