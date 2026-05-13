import SwiftUI

/// Setup sheet for one XYZ unit. Input picker + the per-axis shaped-
/// ramp morph + the Rutt-Etra displacement/intensity/tint controls.
/// Frequency/phase live under an "Advanced" disclosure so the
/// default surface stays clean.
struct XYZSettingsSheet: View {
    @ObservedObject var state: XYZState
    let xyzIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var showLFO = false
    @State private var advancedOpen = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("XYZ \(xyzIndex + 1)")
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white).tracking(2.0)
                Spacer()
                Button { showLFO = true } label: {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(.trailing, 16)
                Button("CLOSE") { dismiss() }
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SourcePicker(
                        label: "INPUT (Z)",
                        source: $state.inputSource,
                        editingKeyerIndex: nil,
                        editingXYZIndex: xyzIndex,
                        allowFeedback: true
                    )

                    shapeRow(label: "X SHAPE", binding: $state.xShape)
                    shapeRow(label: "Y SHAPE", binding: $state.yShape)

                    slider("X Disp", $state.xDisp, in: -1...1)
                    slider("Y Disp", $state.yDisp, in: -1...1)
                    slider("Intensity", $state.intensity, in: 0...2)

                    HStack {
                        smallSlider("R", $state.tintR, tint: .red)
                        smallSlider("G", $state.tintG, tint: .green)
                        smallSlider("B", $state.tintB, tint: .blue)
                    }

                    DisclosureGroup(isExpanded: $advancedOpen) {
                        VStack(alignment: .leading, spacing: 10) {
                            slider("X Freq", $state.xFreq, in: 0.25...8)
                            slider("Y Freq", $state.yFreq, in: 0.25...8)
                            slider("X Phase", $state.xPhase, in: 0...1)
                            slider("Y Phase", $state.yPhase, in: 0...1)
                        }
                        .padding(.top, 4)
                    } label: {
                        Text("ADVANCED")
                            .font(.system(size: 11, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(20)
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showLFO) {
            LFOSettingsSheet(
                title: "XYZ \(xyzIndex + 1)",
                lfo: AppState.shared.lfoEngine.lfo(for: LFOTargets.slotID(forXYZIndex: xyzIndex)),
                availableTargets: AppState.shared.lfoEngine.availableTargets(forSlot: LFOTargets.slotID(forXYZIndex: xyzIndex)),
                transport: AppState.shared.transport
            )
        }
    }

    private func shapeRow(label: String, binding: Binding<Float>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                Text(shapeName(binding.wrappedValue))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Slider(value: binding, in: 0...1).tint(.pink)
            HStack {
                Text("linear")
                Spacer()
                Text("triangle")
                Spacer()
                Text("soft")
                Spacer()
                Text("radial")
            }
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(.white.opacity(0.4))
        }
    }

    private func shapeName(_ v: Float) -> String {
        let m = max(0, min(1, v))
        if m < 0.083 { return "linear" }
        if m < 0.25 { return "linear↔triangle" }
        if m < 0.416 { return "triangle" }
        if m < 0.583 { return "triangle↔soft" }
        if m < 0.75 { return "soft" }
        if m < 0.916 { return "soft↔radial" }
        return "radial"
    }

    private func slider(_ label: String, _ binding: Binding<Float>, in range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(String(format: "%.2f", binding.wrappedValue))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
            }
            Slider(value: binding, in: range).tint(.white)
        }
    }

    private func smallSlider(_ label: String, _ binding: Binding<Float>, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(tint)
                Spacer()
                Text(String(format: "%.2f", binding.wrappedValue))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Slider(value: binding, in: 0...1).tint(tint)
        }
    }
}
