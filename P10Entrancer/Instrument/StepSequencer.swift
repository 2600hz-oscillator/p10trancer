import Foundation
import Combine

/// 16-step sequencer. Each step has an enabled flag and a MIDI note
/// number. Advances on Transport ticks at 1/16-note resolution (1 step
/// per 6 ticks at the 24 PPQ standard the rest of the app uses).
///
/// On reaching an enabled step the sequencer publishes a trigger via
/// `onStepTrigger` carrying the note. The host (InstrumentSource)
/// uses that to retune its synth and gate its ADSR. Disabled steps
/// trigger a gate-off so the envelope releases naturally.
@MainActor
final class StepSequencer: ObservableObject {
    static let stepCount = 16
    /// 6 ticks per 16th note at 24 PPQ.
    static let ticksPerStep = 6

    struct Step: Equatable, Codable {
        var enabled: Bool = false
        /// MIDI note number. 60 = C4. Used to compute synth frequency
        /// via 440 * 2^((note-69)/12).
        var note: Int = 60
    }

    @Published var steps: [Step] = Array(repeating: Step(), count: StepSequencer.stepCount)
    @Published private(set) var currentStep: Int = 0

    /// Called when the sequencer lands on a step. enabled=true means
    /// "play this note"; enabled=false means "release any ringing
    /// envelope" (handed to ADSR as gate-off).
    var onStepTrigger: ((Step) -> Void)?

    private var tickCounter: Int = 0

    /// Reset the playhead to the start of the pattern. Called when
    /// Transport.isRunning toggles, so each run starts cleanly at step 1.
    func resetPlayhead() {
        tickCounter = 0
        currentStep = 0
    }

    /// Drive one tick of the master clock. The sequencer eats ticks
    /// internally; every `ticksPerStep` ticks it advances by one step
    /// and fires the trigger callback.
    func handleTick() {
        if tickCounter == 0 {
            currentStep = currentStep % Self.stepCount
            onStepTrigger?(steps[currentStep])
        }
        tickCounter += 1
        if tickCounter >= Self.ticksPerStep {
            tickCounter = 0
            currentStep = (currentStep + 1) % Self.stepCount
        }
    }

    /// MIDI note → frequency in Hz. Equal-tempered, A4=440.
    static func frequencyHz(forNote note: Int) -> Float {
        Float(440.0 * pow(2.0, Double(note - 69) / 12.0))
    }
}
