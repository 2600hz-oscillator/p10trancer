import Foundation
import Combine

/// 4-track × 16-step drum sequencer. Each track holds a voice type
/// (kick/snare/hat/tom) and 16 on/off step bools. Like the WAVECEL
/// step sequencer it advances on Transport ticks at 1/16 resolution
/// (6 ticks per step at 24 PPQ).
@MainActor
final class DrumSequencer: ObservableObject {
    static let trackCount = 4
    static let stepCount = 16
    static let ticksPerStep = 6

    struct Track: Equatable, Codable {
        var voiceType: DrumVoiceType = .kick
        var steps: [Bool] = Array(repeating: false, count: DrumSequencer.stepCount)
    }

    @Published var tracks: [Track] = [
        Track(voiceType: .kick,  steps: Array(repeating: false, count: DrumSequencer.stepCount)),
        Track(voiceType: .snare, steps: Array(repeating: false, count: DrumSequencer.stepCount)),
        Track(voiceType: .hat,   steps: Array(repeating: false, count: DrumSequencer.stepCount)),
        Track(voiceType: .tom,   steps: Array(repeating: false, count: DrumSequencer.stepCount)),
    ]
    @Published private(set) var currentStep: Int = 0

    /// Called at every step boundary with the array of track indices
    /// whose step at currentStep is enabled. ACIDKICKSource uses this
    /// to trigger the right voices.
    var onStepTrigger: (([Int]) -> Void)?

    private var tickCounter: Int = 0

    func resetPlayhead() {
        tickCounter = 0
        currentStep = 0
    }

    func handleTick() {
        if tickCounter == 0 {
            currentStep = currentStep % Self.stepCount
            var firing: [Int] = []
            for (i, track) in tracks.enumerated() where track.steps[currentStep] {
                firing.append(i)
            }
            onStepTrigger?(firing)
        }
        tickCounter += 1
        if tickCounter >= Self.ticksPerStep {
            tickCounter = 0
            currentStep = (currentStep + 1) % Self.stepCount
        }
    }
}
