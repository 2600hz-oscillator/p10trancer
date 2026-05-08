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
        router.onControlChange = { [weak self] cc, value in
            self?.handleCC(cc: cc, value: value)
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
            }
        }
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
        case 21:
            recorder?.toggle()
        case 22...30:
            // Select which pad subsequent FX-param CCs (23-34) target.
            mixer.inspectedPadIndex = program - 22
        default:
            break
        }
    }

    // MARK: - Control Change (continuous controllers)

    func handleCC(cc: Int, value: Int) {
        withMutedOutput { _handleCC(cc: cc, value: value) }
    }

    private func _handleCC(cc: Int, value: Int) {
        let v = Float(value) / 127.0
        switch cc {
        case 1:
            mixer.position = v
        case 2:
            mixer.masterVolume = v
            AudioEngine.shared.masterVolume = v
        case 3:
            mixer.keyThreshold = v
            keyer?.threshold = v
        case 4:
            mixer.keySoftness = max(0.001, v * 0.5)
            keyer?.softness = max(0.001, v * 0.5)
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

    private func setPadFX(name: String, paramIndex: Int, normalized: Float, range: ClosedRange<Float>) {
        let padIdx = mixer.inspectedPadIndex
        guard pads.pads.indices.contains(padIdx) else { return }
        let chain = pads.pads[padIdx].fxChain
        guard let effect = chain.effects.first(where: { $0.name == name }) else { return }
        let params = effect.parameters
        guard paramIndex < params.count else { return }
        let scaled = range.lowerBound + normalized * (range.upperBound - range.lowerBound)
        params[paramIndex].value = scaled
        // Auto-enable when any param is non-zero (treating 0 as "off").
        // Special-case Feedback's decay/zoom which have non-zero defaults at "off".
        let mainOn: Bool
        switch name {
        case "Feedback":
            // Treat feedback as on whenever Mix (param 0) is non-zero.
            mainOn = (effect.parameters.first?.value ?? 0) > 0.001
        default:
            mainOn = effect.parameters.contains { $0.value > 0.001 }
        }
        effect.isEnabled = mainOn
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
