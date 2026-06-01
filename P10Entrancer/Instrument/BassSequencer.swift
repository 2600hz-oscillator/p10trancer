import Foundation
import Combine

/// 16-step monophonic pitched sequencer for ACIDBASS. Modeled on
/// StepSequencer but each step carries TB-303 performance flags: accent
/// (louder + brighter) and slide (tie/glide into the note). Advances on
/// Transport ticks at 1/16-note resolution (6 ticks per step at 24 PPQ),
/// matching every other sequencer in the app so it locks to ACIDKICK.
@MainActor
final class BassSequencer: ObservableObject {
    static let stepCount = 16
    static let ticksPerStep = 6

    struct Step: Equatable, Codable {
        var enabled: Bool = false
        /// MIDI note number. 60 = C4 (0 V). Default 36 = C2 (bass range).
        var note: Int = 36
        var accent: Bool = false
        var slide: Bool = false
    }

    @Published var steps: [Step] = Array(repeating: Step(), count: BassSequencer.stepCount)
    @Published private(set) var currentStep: Int = 0

    /// Fires on every step (enabled or not). The host decides: enabled →
    /// trigger a note (with accent/slide), disabled → a rest.
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

    /// MIDI note → V/oct CV with 0 V = C4 (MIDI 60), matching Open303's
    /// tuning convention used by TB303Voice/pitchCvToFreq.
    static func noteCv(forNote note: Int) -> Double {
        Double(note - 60) / 12.0
    }
}
