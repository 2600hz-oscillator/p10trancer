import SwiftUI
import MetalKit

/// Row of three FX pads — the bottom row of the 4×3 grid. Each cell
/// is driven by an `FXPadSlot` whose `kind` (keyer/feedback/xyz)
/// determines which renderer + settings sheet to show. The user can
/// retype a slot from its gear menu — first a "Change type" picker
/// is offered alongside the open-settings button.
struct OutputPadsRowView: View {
    let keyerSystem: KeyerSystem
    let feedbackSystem: FeedbackSystem
    let xyzSystem: XYZSystem
    @ObservedObject var fxPadSystem: FXPadSystem
    @ObservedObject var mixer: MixerState
    let renderers: OutputPadRenderers

    var body: some View {
        HStack(spacing: 6) {
            ForEach(fxPadSystem.slots) { slot in
                OutputPadCell(
                    slot: slot,
                    mixer: mixer,
                    keyerSystem: keyerSystem,
                    feedbackSystem: feedbackSystem,
                    xyzSystem: xyzSystem,
                    renderers: renderers
                )
            }
        }
    }
}

/// Holds the renderers so OutputPadsRowView can hand them to each cell
/// (which uses them to construct an MTKView previewing the unit's
/// output texture).
struct OutputPadRenderers {
    let keyerRenderers: [KeyerRenderer]
    let feedbackRenderers: [FeedbackRenderer]
    let xyzRenderers: [XYZRenderer]
}

private struct OutputPadCell: View {
    @ObservedObject var slot: FXPadSlot
    @ObservedObject var mixer: MixerState
    let keyerSystem: KeyerSystem
    let feedbackSystem: FeedbackSystem
    let xyzSystem: XYZSystem
    let renderers: OutputPadRenderers

    @State private var settingsPresented = false
    @State private var lfoPresented = false

    var body: some View {
        let kind = slot.kind
        let isCh1 = mixer.ch1Source == kind.channelSource
        let isCh2 = mixer.ch2Source == kind.channelSource
        let baseTint: Color = {
            switch kind {
            case .keyer: return .green
            case .feedback: return .purple
            case .xyz: return .pink
            }
        }()
        let routedColor: Color = isCh1 ? .cyan : (isCh2 ? .orange : baseTint.opacity(0.5))

        ZStack(alignment: .topLeading) {
            preview(kind: kind)
            Rectangle()
                .strokeBorder(routedColor, lineWidth: (isCh1 || isCh2) ? 4 : 1)
            VStack {
                HStack(alignment: .top) {
                    Text(kind.displayLabel)
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6))
                        .padding(6)
                    if isCh1 {
                        Text("CH1")
                            .font(.system(size: 11, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.cyan).foregroundStyle(.black)
                            .padding(.top, 6)
                    }
                    if isCh2 {
                        Text("CH2")
                            .font(.system(size: 11, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange).foregroundStyle(.black)
                            .padding(.top, 6)
                    }
                    Spacer()
                    // Per-slot LFO sheet — matches the waveform icon
                    // on video pads so the LFO is always one tap away
                    // (no need to dig through the gear menu).
                    Button { lfoPresented = true } label: {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                    .padding(.trailing, 6)
                }
                Spacer()
                HStack {
                    Menu {
                        Button("Open setup…") { settingsPresented = true }
                        Button("Open LFO…") { lfoPresented = true }
                        Divider()
                        Section("Change to") {
                            ForEach(typePickerOptions, id: \.self) { option in
                                Button(option.displayLabel) { slot.kind = option }
                            }
                        }
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .padding(6)
                    Spacer()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            switch mixer.activeChannel {
            case .ch1: mixer.ch1Source = kind.channelSource
            case .ch2: mixer.ch2Source = kind.channelSource
            }
        }
        .sheet(isPresented: $settingsPresented) {
            outputPadSettings(for: kind)
        }
        .sheet(isPresented: $lfoPresented) {
            LFOSettingsSheet(
                title: "\(kind.displayLabel) (slot \(slot.id + 1))",
                lfo: AppState.shared.lfoEngine.lfo(for: slot.lfoSlotID),
                availableTargets: AppState.shared.lfoEngine.availableTargets(forSlot: slot.lfoSlotID),
                transport: AppState.shared.transport
            )
        }
    }

    /// Every option offered in the "Change to" menu. Includes all
    /// instances of all three FX types so the user can swap a slot to
    /// e.g. XYZ 2 or Keyer 1 directly.
    private var typePickerOptions: [FXPadKind] {
        var opts: [FXPadKind] = []
        for i in keyerSystem.keyers.indices { opts.append(.keyer(i)) }
        for i in feedbackSystem.units.indices { opts.append(.feedback(i)) }
        for i in xyzSystem.units.indices { opts.append(.xyz(i)) }
        return opts
    }

    @ViewBuilder
    private func preview(kind: FXPadKind) -> some View {
        switch kind {
        case .keyer(let i):
            if let r = renderers.keyerRenderers[safe: i] {
                OutputTexturePreview(texture: { r.outputTexture })
            } else {
                Color.black
            }
        case .feedback(let i):
            if let r = renderers.feedbackRenderers[safe: i] {
                OutputTexturePreview(texture: { r.outputTexture })
            } else {
                Color.black
            }
        case .xyz(let i):
            if let r = renderers.xyzRenderers[safe: i] {
                OutputTexturePreview(texture: { r.outputTexture })
            } else {
                Color.black
            }
        }
    }

    @ViewBuilder
    private func outputPadSettings(for kind: FXPadKind) -> some View {
        switch kind {
        case .keyer(let i):
            if let state = keyerSystem.keyer(at: i) {
                KeyerSettingsSheet(keyer: state, keyerIndex: i)
            }
        case .feedback(let i):
            if let state = feedbackSystem.unit(at: i) {
                FeedbackSettingsSheet(state: state)
            }
        case .xyz(let i):
            if let state = xyzSystem.unit(at: i) {
                XYZSettingsSheet(state: state, xyzIndex: i)
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
