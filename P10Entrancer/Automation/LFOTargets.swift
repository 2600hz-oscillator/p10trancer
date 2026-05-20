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
        // When the pad is an instrument, the synth + ADSR live
        // ON THIS PAD — surface them so the per-pad LFO can sweep
        // their params (tune / fine / morph / spread / fold) and
        // the four ADSR stages.
        if let inst = pad.source as? InstrumentSource {
            let synth = inst.synth
            let adsr = inst.adsr
            // WAVECEL params.
            targets += [
                LFOTarget(id: "pad.\(index).synth.tune",
                          displayName: "PAD \(padNumber): SYNTH — Tune",
                          range: -36...36,
                          getBase: { synth.tune },
                          setEffective: { synth.tune = $0 }),
                LFOTarget(id: "pad.\(index).synth.fine",
                          displayName: "PAD \(padNumber): SYNTH — Fine",
                          range: -100...100,
                          getBase: { synth.fine },
                          setEffective: { synth.fine = $0 }),
                LFOTarget(id: "pad.\(index).synth.morph",
                          displayName: "PAD \(padNumber): SYNTH — Morph",
                          range: 0...1,
                          getBase: { synth.morph },
                          setEffective: { synth.morph = $0 }),
                LFOTarget(id: "pad.\(index).synth.spread",
                          displayName: "PAD \(padNumber): SYNTH — Spread",
                          range: 1...5,
                          getBase: { synth.spread },
                          setEffective: { synth.spread = $0 }),
                LFOTarget(id: "pad.\(index).synth.fold",
                          displayName: "PAD \(padNumber): SYNTH — Fold",
                          range: 0...1,
                          getBase: { synth.fold },
                          setEffective: { synth.fold = $0 }),
                LFOTarget(id: "pad.\(index).adsr.attack",
                          displayName: "PAD \(padNumber): ADSR — Attack",
                          range: 0.001...2.0,
                          getBase: { adsr.attack },
                          setEffective: { adsr.attack = $0 }),
                LFOTarget(id: "pad.\(index).adsr.decay",
                          displayName: "PAD \(padNumber): ADSR — Decay",
                          range: 0.001...2.0,
                          getBase: { adsr.decay },
                          setEffective: { adsr.decay = $0 }),
                LFOTarget(id: "pad.\(index).adsr.sustain",
                          displayName: "PAD \(padNumber): ADSR — Sustain",
                          range: 0...1,
                          getBase: { adsr.sustain },
                          setEffective: { adsr.sustain = $0 }),
                LFOTarget(id: "pad.\(index).adsr.release",
                          displayName: "PAD \(padNumber): ADSR — Release",
                          range: 0.001...3.0,
                          getBase: { adsr.release },
                          setEffective: { adsr.release = $0 }),
            ]
            // Reverb params.
            let reverb = inst.reverb
            targets += [
                LFOTarget(id: "pad.\(index).reverb.size",
                          displayName: "PAD \(padNumber): REVERB — Size",
                          range: 0...1,
                          getBase: { reverb.size },
                          setEffective: { reverb.size = $0 }),
                LFOTarget(id: "pad.\(index).reverb.damp",
                          displayName: "PAD \(padNumber): REVERB — Damp",
                          range: 0...1,
                          getBase: { reverb.damp },
                          setEffective: { reverb.damp = $0 }),
                LFOTarget(id: "pad.\(index).reverb.wet",
                          displayName: "PAD \(padNumber): REVERB — Wet/Dry",
                          range: 0...1,
                          getBase: { reverb.wet },
                          setEffective: { reverb.wet = $0 }),
            ]
            // Filter (Wasp) params.
            let filter = inst.filter
            targets += [
                LFOTarget(id: "pad.\(index).filter.cutoff",
                          displayName: "PAD \(padNumber): FILTER — Cutoff",
                          range: 20...18000,
                          getBase: { filter.cutoffHz },
                          setEffective: { filter.cutoffHz = $0 }),
                LFOTarget(id: "pad.\(index).filter.resonance",
                          displayName: "PAD \(padNumber): FILTER — Resonance",
                          range: 0...1,
                          getBase: { filter.resonance },
                          setEffective: { filter.resonance = $0 }),
            ]
            // Visualizer params — these don't affect audio but they
            // make great LFO targets for syncing on-screen motion to
            // the music.
            targets += [
                LFOTarget(id: "pad.\(index).viz.zoom",
                          displayName: "PAD \(padNumber): VIZ — Zoom",
                          range: 0.3...2.5,
                          getBase: { inst.vizZoom },
                          setEffective: { inst.vizZoom = $0 }),
                LFOTarget(id: "pad.\(index).viz.rotation",
                          displayName: "PAD \(padNumber): VIZ — Rotate",
                          range: 0...1,
                          getBase: { inst.vizRotation },
                          setEffective: { inst.vizRotation = $0 }),
                LFOTarget(id: "pad.\(index).viz.colorCycle",
                          displayName: "PAD \(padNumber): VIZ — Color Cycle",
                          range: 0...1,
                          getBase: { inst.vizColorCycle },
                          setEffective: { inst.vizColorCycle = $0 }),
            ]
        }
        return targets
    }

    // MARK: - Per keyer pad

    /// Targets on the atomic keyer's params. Source pickers (FG/BG)
    /// aren't modulatable; their values are discrete enums, not floats.
    static func forKeyer(state: KeyerState) -> [LFOTarget] {
        return [
            LFOTarget(
                id: "keyer.threshold",
                displayName: "KEYER: Threshold",
                range: 0...1,
                getBase: { state.threshold },
                setEffective: { state.threshold = $0 }
            ),
            LFOTarget(
                id: "keyer.softness",
                displayName: "KEYER: Softness",
                range: 0.001...0.5,
                getBase: { state.softness },
                setEffective: { state.softness = $0 }
            ),
            LFOTarget(
                id: "keyer.keyColorR",
                displayName: "KEYER: Key R",
                range: 0...1,
                getBase: { state.keyColor.x },
                setEffective: { state.keyColor = SIMD3($0, state.keyColor.y, state.keyColor.z) }
            ),
            LFOTarget(
                id: "keyer.keyColorG",
                displayName: "KEYER: Key G",
                range: 0...1,
                getBase: { state.keyColor.y },
                setEffective: { state.keyColor = SIMD3(state.keyColor.x, $0, state.keyColor.z) }
            ),
            LFOTarget(
                id: "keyer.keyColorB",
                displayName: "KEYER: Key B",
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

    // MARK: - Atomic XYZ unit

    static func forXYZ(state: XYZState) -> [LFOTarget] {
        return [
            LFOTarget(id: "xyz.xShape",
                      displayName: "XYZ: X Shape", range: 0...1,
                      getBase: { state.xShape }, setEffective: { state.xShape = $0 }),
            LFOTarget(id: "xyz.yShape",
                      displayName: "XYZ: Y Shape", range: 0...1,
                      getBase: { state.yShape }, setEffective: { state.yShape = $0 }),
            LFOTarget(id: "xyz.xDisp",
                      displayName: "XYZ: X Disp", range: -1...1,
                      getBase: { state.xDisp }, setEffective: { state.xDisp = $0 }),
            LFOTarget(id: "xyz.yDisp",
                      displayName: "XYZ: Y Disp", range: -1...1,
                      getBase: { state.yDisp }, setEffective: { state.yDisp = $0 }),
            LFOTarget(id: "xyz.intensity",
                      displayName: "XYZ: Intensity", range: 0...2,
                      getBase: { state.intensity }, setEffective: { state.intensity = $0 }),
            LFOTarget(id: "xyz.tintR",
                      displayName: "XYZ: Tint R", range: 0...1,
                      getBase: { state.tintR }, setEffective: { state.tintR = $0 }),
            LFOTarget(id: "xyz.tintG",
                      displayName: "XYZ: Tint G", range: 0...1,
                      getBase: { state.tintG }, setEffective: { state.tintG = $0 }),
            LFOTarget(id: "xyz.tintB",
                      displayName: "XYZ: Tint B", range: 0...1,
                      getBase: { state.tintB }, setEffective: { state.tintB = $0 }),
            LFOTarget(id: "xyz.xFreq",
                      displayName: "XYZ: X Freq", range: 0.25...8,
                      getBase: { state.xFreq }, setEffective: { state.xFreq = $0 }),
            LFOTarget(id: "xyz.yFreq",
                      displayName: "XYZ: Y Freq", range: 0.25...8,
                      getBase: { state.yFreq }, setEffective: { state.yFreq = $0 }),
            LFOTarget(id: "xyz.xPhase",
                      displayName: "XYZ: X Phase", range: 0...1,
                      getBase: { state.xPhase }, setEffective: { state.xPhase = $0 }),
            LFOTarget(id: "xyz.yPhase",
                      displayName: "XYZ: Y Phase", range: 0...1,
                      getBase: { state.yPhase }, setEffective: { state.yPhase = $0 })
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

    /// HD output post-processing targets. Like the NTSC sliders, these
    /// are global and intended for the macro LFOs.
    static func forHDPost(_ state: HDPostState) -> [LFOTarget] {
        return [
            LFOTarget(id: "hd.gamma",
                      displayName: "HD: Gamma", range: 0.5...2.5,
                      getBase: { state.gamma }, setEffective: { state.gamma = $0 }),
            LFOTarget(id: "hd.contrast",
                      displayName: "HD: Contrast", range: 0.5...2.0,
                      getBase: { state.contrast }, setEffective: { state.contrast = $0 }),
            LFOTarget(id: "hd.saturation",
                      displayName: "HD: Saturation", range: 0...2,
                      getBase: { state.saturation }, setEffective: { state.saturation = $0 }),
            LFOTarget(id: "hd.brightness",
                      displayName: "HD: Brightness", range: -0.5...0.5,
                      getBase: { state.brightness }, setEffective: { state.brightness = $0 }),
            LFOTarget(id: "hd.bloom",
                      displayName: "HD: Bloom", range: 0...1,
                      getBase: { state.bloom }, setEffective: { state.bloom = $0 }),
        ]
    }

    /// Stable slot id used by LFOEngine to find/create the LFOState
    /// for each modulatable surface.
    static func slotID(forPadIndex i: Int) -> String { "pad-\(i)" }
    /// Pad LFO N (1-indexed externally; 0 = primary). Instrument
    /// pads expose three LFOs (0/1/2). Slot 0 keeps the bare
    /// `pad-N` form for backward compat with anything that already
    /// references it; slots 1+ get the `-lfo-K` suffix.
    static func slotID(forPadIndex i: Int, lfoIndex k: Int) -> String {
        k == 0 ? "pad-\(i)" : "pad-\(i)-lfo-\(k)"
    }
    static let keyerSlotID = "keyer"
    static let feedbackSlotID = "feedback"
    static let xyzSlotID = "xyz"
    static func slotID(forMacroIndex i: Int) -> String { "macro-\(i)" }
}
