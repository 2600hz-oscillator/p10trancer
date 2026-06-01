import Foundation
import Combine

/// 16-step sequencer for MULTIPLATES. Per step: gate (enabled), note (MIDI),
/// and an optional model index (nil = hold the last selected model, matching
/// inet's MACSEQ HOLD-LAST policy). Advances on Transport ticks at 6 ticks
/// per step (24 PPQ), locking to the other sequencers.
@MainActor
final class MultiplatesSequencer: ObservableObject {
    static let stepCount = 16
    static let ticksPerStep = 6

    struct Step: Equatable, Codable {
        var enabled: Bool = false
        /// MIDI note. 60 = C4 (0 V). Default 48 = C3 (MACSEQ default).
        var note: Int = 48
        /// MacroModel rawValue, or nil to hold the previous step's model.
        var model: Int? = nil
    }

    @Published var steps: [Step] = Array(repeating: Step(), count: MultiplatesSequencer.stepCount)
    @Published private(set) var currentStep: Int = 0

    /// Fires on every step (enabled or not). Host decides: enabled → trigger
    /// (note + resolved model), disabled → rest (gate off).
    var onStepTrigger: ((Step) -> Void)?

    private var tickCounter: Int = 0

    func resetPlayhead() {
        tickCounter = 0
        currentStep = 0
    }

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
}
