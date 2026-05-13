import SwiftUI

struct FXInspectorView: View {
    let pads: PadSystem
    @ObservedObject var mixer: MixerState

    var body: some View {
        let pad = pads.pads[mixer.inspectedPadIndex]
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PAD \(mixer.inspectedPadIndex + 1)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(.yellow)
                Spacer()
            }
            if pad.audioPlayer != nil {
                padVolumeSlider(pad: pad)
            }
            ForEach(Array(pad.fxChain.effects.enumerated()), id: \.offset) { _, effect in
                FXSection(effect: effect, mixer: mixer)
            }
        }
    }

    private func padVolumeSlider(pad: PadSlot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("VOLUME")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            Slider(value: Binding(
                get: { pad.audioPlayer?.volume ?? 0 },
                set: { pad.audioPlayer?.volume = $0 }
            ), in: 0...1)
            .tint(.green)
        }
    }
}

private struct FXSection: View {
    let effect: FXEffect
    @ObservedObject var mixer: MixerState
    @State private var isEnabled: Bool = false
    @State private var values: [Float] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $isEnabled) {
                Text(effect.name)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .toggleStyle(.switch)
            .tint(.green)
            .onChange(of: isEnabled) { _, newValue in
                effect.isEnabled = newValue
            }

            if isEnabled {
                ForEach(Array(effect.parameters.enumerated()), id: \.offset) { idx, param in
                    paramRow(idx: idx, param: param)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color.white.opacity(0.04))
        .onAppear {
            isEnabled = effect.isEnabled
            values = effect.parameters.map { $0.value }
        }
    }

    private func paramRow(idx: Int, param: FXParameter) -> some View {
        let binding = Binding<Float>(
            get: { idx < values.count ? values[idx] : param.value },
            set: { newValue in
                if idx < values.count { values[idx] = newValue }
                param.value = newValue
            }
        )
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(param.name)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(String(format: "%.2f", binding.wrappedValue))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Slider(value: binding, in: param.range)
                .tint(.white.opacity(0.85))
        }
    }
}
