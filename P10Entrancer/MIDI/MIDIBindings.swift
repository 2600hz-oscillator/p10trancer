import Foundation

/// Comprehensive MIDI control scheme. See MIDI.md at the repo root for the
/// full table; this file is the authoritative implementation. Channel-agnostic
/// (responds to messages on any MIDI channel).
@MainActor
final class MIDIBindings {
    private let mixer: MixerState
    private let pads: PadSystem
    private let keyer: KeyerState?
    private let ntsc: NTSCState?
    private let recorder: MixerRecorder?
    private let appState: AppState?
    weak var output: MIDIOutputBindings?

    init(
        mixer: MixerState,
        pads: PadSystem,
        keyer: KeyerState? = nil,
        ntsc: NTSCState? = nil,
        recorder: MixerRecorder? = nil,
        appState: AppState? = nil
    ) {
        self.mixer = mixer
        self.pads = pads
        self.keyer = keyer
        self.ntsc = ntsc
        self.recorder = recorder
        self.appState = appState
    }

    func attach(to router: MIDIRouter) {
        router.onNoteOn = { [weak self] note, _ in
            self?.handleNoteOn(note)
        }
        router.onControlChange = { [weak self] cc, value, channel in
            self?.handleCC(cc: cc, value: value, channel: channel)
        }
        router.onProgramChange = { [weak self] program in
            self?.handleProgramChange(program)
        }
    }

    /// All inbound dispatch methods funnel through this so they always set the
    /// output mute flag — prevents echo loops when a downstream subscriber
    /// would otherwise emit the same message back out.
    private func withMutedOutput(_ body: () -> Void) {
        output?.muted = true
        body()
        output?.muted = false
    }

    // MARK: - Note On (alternate pad triggers)

    func handleNoteOn(_ note: Int) {
        withMutedOutput {
            // Note 36-44: pads 1-9 (Akai-style pad layout, MPC convention).
            let padBase36 = 36
            let padIndex36 = note - padBase36
            if (0..<PadSystem.padCount).contains(padIndex36) {
                mixer.routeActivePad(padIndex36)
                return
            }
            // Note 60-68: pads 1-9 (middle-C upward, keyboard-style).
            let padBase60 = 60
            let padIndex60 = note - padBase60
            if (0..<PadSystem.padCount).contains(padIndex60) {
                mixer.routeActivePad(padIndex60)
                return
            }
            // Note 72-80: pad 1-9 PLAY/STOP toggle (file pads only).
            let padBase72 = 72
            let padPlayIndex = note - padBase72
            if (0..<PadSystem.padCount).contains(padPlayIndex) {
                togglePlay(at: padPlayIndex)
                return
            }
            // Note 84-92: pad 1-9 MUTE toggle.
            let padBase84 = 84
            let padMuteIndex = note - padBase84
            if (0..<PadSystem.padCount).contains(padMuteIndex) {
                toggleMute(at: padMuteIndex)
            }
        }
    }

    /// Toggle the file pad's play/stop state. No-op for non-file sources
    /// (cameras, keyers, feedback) — those don't have a meaningful
    /// stop concept.
    func togglePlay(at padIndex: Int) {
        guard pads.pads.indices.contains(padIndex) else { return }
        guard let video = pads.pads[padIndex].source as? VideoFileSource else { return }
        video.isPlaying.toggle()
    }

    /// Toggle the per-pad mute. Affects any pad that has an audioPlayer
    /// (file pads + camera/mic pads).
    func toggleMute(at padIndex: Int) {
        guard pads.pads.indices.contains(padIndex) else { return }
        guard let player = pads.pads[padIndex].audioPlayer else { return }
        player.isMuted.toggle()
    }

    // MARK: - Program Change (primary pad / mode triggers)

    func handleProgramChange(_ program: Int) {
        withMutedOutput { _handleProgramChange(program) }
    }

    private func _handleProgramChange(_ program: Int) {
        switch program {
        case 1...9:
            mixer.routeActivePad(program - 1)
        case 10:
            mixer.activeChannel = .ch1
        case 11:
            mixer.activeChannel = .ch2
        case 12...16:
            let kindIndex = program - 12
            if let kind = TransitionKind.allCases[safe: kindIndex] {
                mixer.transition = kind
            }
        case 17:
            mixer.outputMode = (mixer.outputMode == .hd720p) ? .ntsc4_3 : .hd720p
        case 18:
            keyer?.isEnabled.toggle()
        case 19:
            mixer.routeKeyerTo(.ch1)
        case 20:
            mixer.routeKeyerTo(.ch2)
        // Note: PC 40-42 / 50-52 below are the explicit ch1/ch2 → keyer/
        // feedback/xyz routing emitted by MIDIOutputBindings on user
        // gestures so automation can round-trip them.
        case 21:
            recorder?.toggle()
        case 22...30:
            // Select which pad subsequent FX-param CCs (23-34) target.
            mixer.inspectedPadIndex = program - 22
        case 40:
            mixer.ch1Source = .keyer
        case 41:
            mixer.ch1Source = .feedback
        case 42:
            mixer.ch1Source = .xyz
        case 50:
            mixer.ch2Source = .keyer
        case 51:
            mixer.ch2Source = .feedback
        case 52:
            mixer.ch2Source = .xyz
        // Explicit setters for binary modes — stateless controllers
        // (Electra One) can send a single PC to drive the iPad to an
        // exact state, vs. toggling and having to track current state.
        case 60:
            mixer.outputMode = .hd720p
        case 61:
            mixer.outputMode = .ntsc4_3
        case 62:
            keyer?.isEnabled = true
        case 63:
            keyer?.isEnabled = false
        default:
            break
        }
    }

    // MARK: - Control Change (continuous controllers)

    /// Inbound CC dispatch. `channel` is 0-15 (MIDI ch 1-16); defaults to
    /// 15 so legacy callers without channel info land in the
    /// inspectedPadIndex code path (channels 9-15) rather than
    /// accidentally targeting pad 0.
    func handleCC(cc: Int, value: Int, channel: Int = 15) {
        withMutedOutput { _handleCC(cc: cc, value: value, channel: channel) }
    }

    private func _handleCC(cc: Int, value: Int, channel: Int) {
        let v = Float(value) / 127.0
        // CC 23-34 on channels 0-8 (MIDI ch 1-9) target pad N's FX
        // directly, bypassing inspectedPadIndex. Lets stateless
        // controllers (Electra One) put every pad on its own page.
        // Channels 9-15 fall through to the original inspectedPadIndex
        // path so existing controllers keep working.
        if (23...34).contains(cc), (0...8).contains(channel) {
            dispatchPadFX(cc: cc, normalized: v, padIndex: channel)
            return
        }
        // Channel-keyed FX on/off (CC 35-40 on channels 0-8). Explicit
        // setters per (pad, effect) — value >= 64 = on, < 64 = off.
        // No auto-enable on param changes; the bit is the only thing
        // that flips isEnabled.
        if (35...40).contains(cc), (0...8).contains(channel) {
            dispatchPadFXEnable(cc: cc, on: value >= 64, padIndex: channel)
            return
        }
        switch cc {
        case 1:
            mixer.position = v
        case 2:
            mixer.masterVolume = v
            AudioEngine.shared.masterVolume = v
        case 3:
            // Drives ONLY the master-mixer chroma-transition key.
            // Keyer 1/2 have their own threshold/softness sliders in
            // their setup sheets — those are independent of the
            // crossfade transition.
            mixer.keyThreshold = v
        case 4:
            mixer.keySoftness = max(0.001, v * 0.5)
        case 5...13:
            let padIndex = cc - 5
            pads.pads[padIndex].audioPlayer?.volume = v
        case 14:
            ntsc?.chromaBoost = v * 3.0
        case 15:
            ntsc?.hsyncWobble = v
        case 16:
            ntsc?.subcarrierDrift = v * 0.5
        case 17:
            ntsc?.burstPhaseShift = (v - 0.5)
        case 18:
            ntsc?.ycDelay = (v - 0.5) * 16.0
        case 19:
            ntsc?.dropoutRate = v
        case 20:
            ntsc?.lumaNoise = v * 0.3
        case 21:
            ntsc?.chromaNoise = v * 0.3
        case 22:
            ntsc?.lumaPeaking = v * 3.0

        // Per-pad FX params for the currently-inspected pad. Each CC drives
        // one parameter; setting > 0 implicitly enables the effect, setting
        // to 0 disables it.
        case 23:
            setPadFX(name: "Blur", paramIndex: 0, normalized: v, range: 0...6)
        case 24:
            setPadFX(name: "Chroma", paramIndex: 0, normalized: v, range: 0...1)
        case 25:
            setPadFX(name: "Chroma", paramIndex: 1, normalized: v, range: 0...3)
        case 26:
            setPadFX(name: "Chroma", paramIndex: 2, normalized: v, range: 0...3)
        case 27:
            setPadFX(name: "YUV Phaser", paramIndex: 0, normalized: v, range: 0...1)
        case 28:
            setPadFX(name: "YUV Phaser", paramIndex: 1, normalized: v, range: 0...1)
        case 29:
            setPadFX(name: "Luma Phaser", paramIndex: 1, normalized: v, range: 0...1)
        case 30:
            setPadFX(name: "Luma Phaser", paramIndex: 2, normalized: v, range: 0.5...8)
        case 31:
            setPadFX(name: "Edge Enhance", paramIndex: 0, normalized: v, range: 0...3)
        case 32:
            setPadFX(name: "Feedback", paramIndex: 0, normalized: v, range: 0...1)
        case 33:
            setPadFX(name: "Feedback", paramIndex: 1, normalized: v, range: 0.85...1.15)
        case 34:
            setPadFX(name: "Feedback", paramIndex: 3, normalized: v, range: 0.5...1.0)

        default:
            break
        }
    }

    /// Channel-keyed FX dispatch. Maps CC 23-34 to the same (FX name,
    /// param index, range) triple as the inspectedPadIndex path but
    /// writes to `padIndex` directly.
    private func dispatchPadFX(cc: Int, normalized v: Float, padIndex: Int) {
        switch cc {
        case 23: setPadFX(name: "Blur", paramIndex: 0, normalized: v, range: 0...6, padIndex: padIndex)
        case 24: setPadFX(name: "Chroma", paramIndex: 0, normalized: v, range: 0...1, padIndex: padIndex)
        case 25: setPadFX(name: "Chroma", paramIndex: 1, normalized: v, range: 0...3, padIndex: padIndex)
        case 26: setPadFX(name: "Chroma", paramIndex: 2, normalized: v, range: 0...3, padIndex: padIndex)
        case 27: setPadFX(name: "YUV Phaser", paramIndex: 0, normalized: v, range: 0...1, padIndex: padIndex)
        case 28: setPadFX(name: "YUV Phaser", paramIndex: 1, normalized: v, range: 0...1, padIndex: padIndex)
        case 29: setPadFX(name: "Luma Phaser", paramIndex: 1, normalized: v, range: 0...1, padIndex: padIndex)
        case 30: setPadFX(name: "Luma Phaser", paramIndex: 2, normalized: v, range: 0.5...8, padIndex: padIndex)
        case 31: setPadFX(name: "Edge Enhance", paramIndex: 0, normalized: v, range: 0...3, padIndex: padIndex)
        case 32: setPadFX(name: "Feedback", paramIndex: 0, normalized: v, range: 0...1, padIndex: padIndex)
        case 33: setPadFX(name: "Feedback", paramIndex: 1, normalized: v, range: 0.85...1.15, padIndex: padIndex)
        case 34: setPadFX(name: "Feedback", paramIndex: 3, normalized: v, range: 0.5...1.0, padIndex: padIndex)
        default: break
        }
    }

    private func setPadFX(name: String, paramIndex: Int, normalized: Float, range: ClosedRange<Float>, padIndex: Int? = nil) {
        let padIdx = padIndex ?? mixer.inspectedPadIndex
        guard pads.pads.indices.contains(padIdx) else { return }
        let chain = pads.pads[padIdx].fxChain
        guard let effect = chain.effects.first(where: { $0.name == name }) else { return }
        let params = effect.parameters
        guard paramIndex < params.count else { return }
        let scaled = range.lowerBound + normalized * (range.upperBound - range.lowerBound)
        params[paramIndex].value = scaled
        // No auto-enable: the user must explicitly enable an effect
        // via the per-pad FX sheet OR via MIDI CC 35-40. Param values
        // can be pre-set while the effect is off; flipping on then
        // applies them. This matches the behavior of the new sheet UI
        // and gives stateless controllers (Electra One) a clean
        // separation between "set param" and "turn it on".
    }

    /// Maps the six per-pad FX on/off CCs to the matching effect
    /// inside `padIndex`'s FX chain.
    private static let fxEnableCCNames: [Int: String] = [
        35: "Blur",
        36: "Chroma",
        37: "YUV Phaser",
        38: "Luma Phaser",
        39: "Edge Enhance",
        40: "Feedback",
    ]

    private func dispatchPadFXEnable(cc: Int, on: Bool, padIndex: Int) {
        guard let name = Self.fxEnableCCNames[cc] else { return }
        guard pads.pads.indices.contains(padIndex) else { return }
        let chain = pads.pads[padIndex].fxChain
        guard let effect = chain.effects.first(where: { $0.name == name }) else { return }
        effect.isEnabled = on
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
