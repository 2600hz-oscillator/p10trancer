import SwiftUI

struct KeyerControlsView: View {
    @ObservedObject var system: KeyerSystem
    @ObservedObject var mixer: MixerState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            ScrollView {
                KeyerEditor(keyer: system.keyer, mixer: mixer)
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("KEYER")
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
}

private struct KeyerEditor: View {
    @ObservedObject var keyer: KeyerState
    @ObservedObject var mixer: MixerState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                routeButton(channel: .ch1, label: "→ CH1", tint: .cyan)
                routeButton(channel: .ch2, label: "→ CH2", tint: .orange)
            }
            padPicker("FG", $keyer.foregroundPadIndex)
            padPicker("BG", $keyer.backgroundPadIndex)
            Picker("Kind", selection: $keyer.kind) {
                ForEach(KeyerKind.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented).colorScheme(.dark)
            slider("Threshold", $keyer.threshold, in: 0...1)
            slider("Softness", $keyer.softness, in: 0.001...0.5)
        }
        .padding(20)
    }

    private func routeButton(channel: ActiveChannel, label: String, tint: Color) -> some View {
        let active: Bool = {
            switch channel {
            case .ch1: return mixer.ch1IsKeyer
            case .ch2: return mixer.ch2IsKeyer
            }
        }()
        return Button(action: { mixer.routeKeyerTo(channel) }) {
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
                .frame(width: 30)
            Picker("", selection: binding) {
                ForEach(0..<PadSystem.padCount, id: \.self) { i in Text("\(i + 1)").tag(i) }
            }
            .pickerStyle(.segmented)
            .colorScheme(.dark)
        }
    }

    private func slider(_ label: String, _ binding: Binding<Float>, in range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(String(format: "%.2f", binding.wrappedValue))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Slider(value: binding, in: range).tint(.white)
        }
    }
}
