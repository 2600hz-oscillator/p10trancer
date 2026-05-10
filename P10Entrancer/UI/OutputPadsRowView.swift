import SwiftUI
import MetalKit

/// Row of three "output pads" — KEYER 1, KEYER 2, FEEDBACK — sitting
/// directly under the 3×3 source-pad grid. Each pad shows the unit's
/// rendered output, can be tapped to route that output to the active
/// channel, and exposes a gear icon (lower left) that opens a setup
/// sheet for inputs + parameters.
struct OutputPadsRowView: View {
    let keyerSystem: KeyerSystem
    let feedbackSystem: FeedbackSystem
    @ObservedObject var mixer: MixerState
    let renderers: OutputPadRenderers

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OutputPadRef.all, id: \.self) { ref in
                OutputPadCell(
                    ref: ref,
                    mixer: mixer,
                    keyerSystem: keyerSystem,
                    feedbackSystem: feedbackSystem,
                    renderers: renderers
                )
            }
        }
    }
}

/// References one of the three output pads. We keep this separate from
/// ChannelSource because ChannelSource lacks a single FEEDBACK case
/// (it uses an Int index from the old 2-feedback-unit days).
enum OutputPadRef: Hashable {
    case keyer(Int)   // 0 = Keyer 1, 1 = Keyer 2
    case feedback     // single feedback unit

    static let all: [OutputPadRef] = [.keyer(0), .keyer(1), .feedback]

    var label: String {
        switch self {
        case .keyer(let i): return "KEYER \(i + 1)"
        case .feedback: return "FEEDBACK"
        }
    }

    var tint: Color {
        switch self {
        case .keyer: return .green
        case .feedback: return .purple
        }
    }

    /// Maps to the corresponding ChannelSource for routing to channels.
    var channelSource: ChannelSource {
        switch self {
        case .keyer(let i): return .keyer(i)
        case .feedback: return .feedback(0)
        }
    }
}

/// Holds the renderers so OutputPadsRowView can hand them to each cell
/// (which uses them to construct an MTKView previewing the unit's
/// output texture).
struct OutputPadRenderers {
    let keyerRenderers: [KeyerRenderer]
    let feedbackRenderers: [FeedbackRenderer]
}

private struct OutputPadCell: View {
    let ref: OutputPadRef
    @ObservedObject var mixer: MixerState
    let keyerSystem: KeyerSystem
    let feedbackSystem: FeedbackSystem
    let renderers: OutputPadRenderers

    @State private var settingsPresented = false

    var body: some View {
        let isCh1 = mixer.ch1Source == ref.channelSource
        let isCh2 = mixer.ch2Source == ref.channelSource
        let routedColor: Color = isCh1 ? .cyan : (isCh2 ? .orange : ref.tint.opacity(0.5))

        ZStack(alignment: .topLeading) {
            preview
            Rectangle()
                .strokeBorder(routedColor, lineWidth: (isCh1 || isCh2) ? 4 : 1)
            VStack {
                HStack(alignment: .top) {
                    Text(ref.label)
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
                }
                Spacer()
                HStack {
                    Button {
                        settingsPresented = true
                    } label: {
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
            case .ch1: mixer.ch1Source = ref.channelSource
            case .ch2: mixer.ch2Source = ref.channelSource
            }
        }
        .sheet(isPresented: $settingsPresented) {
            outputPadSettings
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch ref {
        case .keyer(let i):
            if let r = renderers.keyerRenderers[safe: i] {
                OutputTexturePreview(texture: { r.outputTexture })
            } else {
                Color.black
            }
        case .feedback:
            if let r = renderers.feedbackRenderers.first {
                OutputTexturePreview(texture: { r.outputTexture })
            } else {
                Color.black
            }
        }
    }

    @ViewBuilder
    private var outputPadSettings: some View {
        switch ref {
        case .keyer(let i):
            if let state = keyerSystem.keyer(at: i) {
                KeyerSettingsSheet(keyer: state, keyerIndex: i)
            }
        case .feedback:
            if let state = feedbackSystem.unit(at: 0) {
                FeedbackSettingsSheet(state: state)
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
