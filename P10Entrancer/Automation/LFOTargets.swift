import Foundation

/// Factory functions that produce the LFO target list for each
/// slot kind. Kept separate from `LFOEngine` so the target catalogs
/// for pads / keyers / feedback can change independently of the LFO
/// math itself.
@MainActor
enum LFOTargets {

    // MARK: - Per source-pad

    /// Targets exposed by a regular source pad (file / camera / image
    /// / live-recording). Includes the pad's volume plus every
    /// parameter of every FX in the pad's FXChain.
    static func forSourcePad(index: Int, pad: PadSlot) -> [LFOTarget] {
        var targets: [LFOTarget] = []
        let padNumber = index + 1
        if let player = pad.audioPlayer {
            targets.append(LFOTarget(
                id: "pad.\(index).volume",
                displayName: "PAD \(padNumber): Volume",
                range: 0...1,
                getBase: { player.volume },
                setEffective: { player.volume = $0 }
            ))
        }
        for fx in pad.fxChain.effects {
            for param in fx.parameters {
                targets.append(LFOTarget(
                    id: "pad.\(index).fx.\(fx.name).\(param.name)",
                    displayName: "PAD \(padNumber): \(fx.name) — \(param.name)",
                    range: param.range,
                    getBase: { param.value },
                    setEffective: { param.value = $0 }
                ))
            }
        }
        return targets
    }

    // MARK: - Per keyer pad

    /// Targets on a keyer's params. Source pickers (FG/BG) aren't
    /// modulatable; their values are discrete enums, not floats.
    static func forKeyer(index: Int, state: KeyerState) -> [LFOTarget] {
        let label = "KEYER \(index + 1)"
        return [
            LFOTarget(
                id: "keyer.\(index).threshold",
                displayName: "\(label): Threshold",
                range: 0...1,
                getBase: { state.threshold },
                setEffective: { state.threshold = $0 }
            ),
            LFOTarget(
                id: "keyer.\(index).softness",
                displayName: "\(label): Softness",
                range: 0.001...0.5,
                getBase: { state.softness },
                setEffective: { state.softness = $0 }
            ),
            LFOTarget(
                id: "keyer.\(index).keyColorR",
                displayName: "\(label): Key R",
                range: 0...1,
                getBase: { state.keyColor.x },
                setEffective: { state.keyColor = SIMD3($0, state.keyColor.y, state.keyColor.z) }
            ),
            LFOTarget(
                id: "keyer.\(index).keyColorG",
                displayName: "\(label): Key G",
                range: 0...1,
                getBase: { state.keyColor.y },
                setEffective: { state.keyColor = SIMD3(state.keyColor.x, $0, state.keyColor.z) }
            ),
            LFOTarget(
                id: "keyer.\(index).keyColorB",
                displayName: "\(label): Key B",
                range: 0...1,
                getBase: { state.keyColor.z },
                setEffective: { state.keyColor = SIMD3(state.keyColor.x, state.keyColor.y, $0) }
            ),
        ]
    }

    // MARK: - Feedback pad

    static func forFeedback(state: FeedbackState) -> [LFOTarget] {
        return [
            LFOTarget(id: "feedback.zoom",
                      displayName: "FEEDBACK: Zoom", range: 0.5...2.0,
                      getBase: { state.zoom },
                      setEffective: { state.zoom = $0 }),
            LFOTarget(id: "feedback.panX",
                      displayName: "FEEDBACK: Pan X", range: -1...1,
                      getBase: { state.panX },
                      setEffective: { state.panX = $0 }),
            LFOTarget(id: "feedback.panY",
                      displayName: "FEEDBACK: Pan Y", range: -1...1,
                      getBase: { state.panY },
                      setEffective: { state.panY = $0 }),
            LFOTarget(id: "feedback.tilt",
                      displayName: "FEEDBACK: Tilt", range: -1...1,
                      getBase: { state.tilt },
                      setEffective: { state.tilt = $0 }),
            LFOTarget(id: "feedback.decay",
                      displayName: "FEEDBACK: Decay", range: 0.5...1.0,
                      getBase: { state.decay },
                      setEffective: { state.decay = $0 }),
            LFOTarget(id: "feedback.mix",
                      displayName: "FEEDBACK: Mix", range: 0...1,
                      getBase: { state.feedbackMix },
                      setEffective: { state.feedbackMix = $0 }),
            LFOTarget(id: "feedback.luminosity",
                      displayName: "FEEDBACK: Luminosity", range: 0...2,
                      getBase: { state.luminosity },
                      setEffective: { state.luminosity = $0 }),
            LFOTarget(id: "feedback.chromaBoost",
                      displayName: "FEEDBACK: Chroma Boost", range: 0...3,
                      getBase: { state.chromaBoost },
                      setEffective: { state.chromaBoost = $0 }),
        ]
    }

    // MARK: - Global (macro-only targets)

    /// Targets that are NOT scoped to a specific pad/keyer/feedback —
    /// e.g., the master mixer position fader. Only the two macro LFOs
    /// see these; per-pad LFOs are filtered out by id prefix.
    static func forMixer(_ mixer: MixerState) -> [LFOTarget] {
        return [
            LFOTarget(
                id: "mixer.position",
                displayName: "MASTER: Position",
                range: 0...1,
                getBase: { mixer.position },
                setEffective: { mixer.position = $0 }
            )
        ]
    }

    /// Stable slot id used by LFOEngine to find/create the LFOState
    /// for each modulatable surface.
    static func slotID(forPadIndex i: Int) -> String { "pad-\(i)" }
    static func slotID(forKeyerIndex i: Int) -> String { "keyer-\(i)" }
    static let feedbackSlotID = "feedback"
    static func slotID(forMacroIndex i: Int) -> String { "macro-\(i)" }
}
