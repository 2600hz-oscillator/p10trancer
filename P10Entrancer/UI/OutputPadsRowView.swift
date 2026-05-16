import SwiftUI
import MetalKit

/// Bottom row of three atomic FX pads: KEYER, FEEDBACK, XYZ. Each
/// slot is permanently bound to one FX type — there is no instance
/// index and no way to retype the slot. The gear icon opens that
/// FX type's settings sheet directly; the waveform icon opens the
/// per-slot LFO sheet.
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

/// Holds the three renderers so OutputPadsRowView can hand them to
/// each cell (which uses them to construct an MTKView previewing the
/// unit's output texture).
struct OutputPadRenderers {
    let keyer: KeyerRenderer
    let feedback: FeedbackRenderer
    let xyz: XYZRenderer
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
                    Button { settingsPresented = true } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
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
                title: "\(kind.displayLabel) LFO",
                lfo: AppState.shared.lfoEngine.lfo(for: slot.lfoSlotID),
                availableTargets: AppState.shared.lfoEngine.availableTargets(forSlot: slot.lfoSlotID),
                transport: AppState.shared.transport
            )
        }
    }

    @ViewBuilder
    private func preview(kind: FXPadKind) -> some View {
        switch kind {
        case .keyer:
            OutputTexturePreview(texture: { renderers.keyer.outputTexture })
        case .feedback:
            OutputTexturePreview(texture: { renderers.feedback.outputTexture })
        case .xyz:
            OutputTexturePreview(texture: { renderers.xyz.outputTexture })
        }
    }

    @ViewBuilder
    private func outputPadSettings(for kind: FXPadKind) -> some View {
        switch kind {
        case .keyer:
            KeyerSettingsSheet(keyer: keyerSystem.keyer)
        case .feedback:
            FeedbackSettingsSheet(state: feedbackSystem.unit)
        case .xyz:
            XYZSettingsSheet(state: xyzSystem.unit)
        }
    }
}
