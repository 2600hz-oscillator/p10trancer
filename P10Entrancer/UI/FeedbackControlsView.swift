import SwiftUI

struct FeedbackControlsView: View {
    @ObservedObject var system: FeedbackSystem
    @ObservedObject var mixer: MixerState
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            picker
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            ScrollView {
                if let unit = system.unit(at: selected) {
                    FeedbackEditor(index: selected, state: unit, mixer: mixer)
                }
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("FEEDBACK CONTROLS")
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .tracking(2.0)
            Spacer()
            Button("CLOSE") { dismiss() }
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var picker: some View {
        HStack(spacing: 0) {
            ForEach(system.units.indices, id: \.self) { i in
                Button(action: { selected = i }) {
                    Text("FB \(i + 1)")
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .foregroundStyle(selected == i ? .black : .white)
                        .background(selected == i ? Color.purple : Color.white.opacity(0.06))
                        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct FeedbackEditor: View {
    let index: Int
    @ObservedObject var state: FeedbackState
    @ObservedObject var mixer: MixerState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                routeButton(channel: .ch1, label: "→ CH1", tint: .cyan)
                routeButton(channel: .ch2, label: "→ CH2", tint: .orange)
            }
            padPicker("Source pad", $state.sourcePadIndex)
            slider("Zoom",     $state.zoom,        in: 0.5...4.0,   format: "%.2f×")
            slider("Pan X",    $state.panX,        in: -1...1,      format: "%.2f")
            slider("Pan Y",    $state.panY,        in: -1...1,      format: "%.2f")
            slider("Tilt",     $state.tilt,        in: -1...1,      format: "%.2f")
            slider("Persistence", $state.decay,       in: 0...1.0,   format: "%.3f")
            slider("Input Gain",  $state.feedbackMix, in: 0...2.0,   format: "%.2f")
            slider("Bloom",       $state.luminosity,  in: 0.2...3.0, format: "%.2f×")
            slider("Chroma boost", $state.chromaBoost, in: 0...3, format: "%.2f×")
            Text("Persistence is the per-frame fade — 0.95+ gives camera-into-CRT trails. Input Gain decides how brightly the live signal punches through; >1 makes fresh frames overpower long trails. Bloom drives the highlight rolloff in the tonemap.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(20)
    }

    private func routeButton(channel: ActiveChannel, label: String, tint: Color) -> some View {
        let active: Bool = {
            switch channel {
            case .ch1: return mixer.ch1FeedbackIndex == index
            case .ch2: return mixer.ch2FeedbackIndex == index
            }
        }()
        return Button(action: { mixer.routeFeedbackTo(channel, feedbackIndex: index) }) {
            Text(label)
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                .foregroundStyle(active ? .black : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(active ? tint : Color.white.opacity(0.06))
                .overlay(Rectangle().strokeBorder(active ? tint : Color.white.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func padPicker(_ label: String, _ binding: Binding<Int>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 90, alignment: .leading)
            Picker("", selection: binding) {
                ForEach(0..<PadSystem.padCount, id: \.self) { i in Text("\(i + 1)").tag(i) }
            }
            .pickerStyle(.segmented)
            .colorScheme(.dark)
        }
    }

    private func slider(_ label: String, _ binding: Binding<Float>, in range: ClosedRange<Float>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(String(format: format, binding.wrappedValue))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Slider(value: binding, in: range).tint(.purple)
        }
    }
}
