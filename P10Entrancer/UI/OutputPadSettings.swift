import SwiftUI

/// Source picker shared by the keyer's FG/BG inputs, the feedback
/// input, and the xyz input. Lets the user choose any of the 9 source
/// pads, or any of the OTHER atomic FX units (no self-references —
/// the renderer reads its own prior frame internally for the recursive
/// part).
struct SourcePicker: View {
    let label: String
    @Binding var source: SourceRef
    /// When true, the KEYER chip is suppressed — used when picking
    /// the keyer's own FG/BG so it can't self-reference.
    var hideKeyer: Bool = false
    /// When true, the FEEDBACK chip is suppressed — used when picking
    /// the feedback unit's own input.
    var hideFeedback: Bool = false
    /// When true, the XYZ chip is suppressed — used when picking
    /// XYZ's own input.
    var hideXYZ: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(0..<PadSystem.padCount, id: \.self) { i in
                        chip(label: "\(i + 1)", on: source == .pad(i)) {
                            source = .pad(i)
                        }
                    }
                    Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 28)
                    if !hideKeyer {
                        chip(label: "KEY", on: source == .keyer, tint: .green) {
                            source = .keyer
                        }
                    }
                    if !hideFeedback {
                        chip(label: "FB", on: source == .feedback, tint: .purple) {
                            source = .feedback
                        }
                    }
                    if !hideXYZ {
                        chip(label: "XYZ", on: source == .xyz, tint: .pink) {
                            source = .xyz
                        }
                    }
                }
            }
        }
    }

    private func chip(label: String, on: Bool, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(on ? .black : .white)
                .frame(width: 44, height: 28)
                .background(on ? tint : Color.white.opacity(0.06))
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Setup sheet for the single keyer. Opened directly from the
/// KEYER pad's gear icon.
struct KeyerSettingsSheet: View {
    @ObservedObject var keyer: KeyerState
    @Environment(\.dismiss) private var dismiss
    @State private var showLFO = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("KEYER")
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
                        label: "FOREGROUND",
                        source: $keyer.foregroundSource,
                        hideKeyer: true
                    )
                    SourcePicker(
                        label: "BACKGROUND",
                        source: $keyer.backgroundSource,
                        hideKeyer: true
                    )
                    Picker("Kind", selection: $keyer.kind) {
                        ForEach(KeyerKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented).colorScheme(.dark)
                    if keyer.kind == .chroma {
                        keyColorRow
                    }
                    slider(keyer.kind == .chroma ? "Tolerance" : "Threshold",
                           $keyer.threshold, in: 0...1)
                    slider("Softness", $keyer.softness, in: 0.001...0.5)
                    if keyer.kind == .chroma {
                        slider("Spill", $keyer.spill, in: 0...1)
                    }
                    Toggle(isOn: $keyer.invert) {
                        Text("INVERT")
                            .font(.system(size: 11, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                    .tint(.green)
                }
                .padding(20)
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showLFO) {
            LFOSettingsSheet(
                title: "KEYER",
                lfo: AppState.shared.lfoEngine.lfo(for: LFOTargets.keyerSlotID),
                availableTargets: AppState.shared.lfoEngine.availableTargets(forSlot: LFOTargets.keyerSlotID),
                transport: AppState.shared.transport
            )
        }
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

    /// Native iOS color wheel bound to the keyer's RGB triplet.
    private var keyColorRow: some View {
        HStack {
            Text("KEY COLOR")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            ColorPicker("", selection: Binding<Color>(
                get: { Color(red: Double(keyer.keyColor.x),
                             green: Double(keyer.keyColor.y),
                             blue: Double(keyer.keyColor.z)) },
                set: { newColor in
                    let comps = UIColor(newColor).cgColor.components ?? [0, 1, 0, 1]
                    keyer.keyColor = SIMD3(
                        Float(comps[safe: 0] ?? 0),
                        Float(comps[safe: 1] ?? 0),
                        Float(comps[safe: 2] ?? 0)
                    )
                }
            ), supportsOpacity: false)
                .labelsHidden()
        }
    }
}

private extension Array where Element == CGFloat {
    subscript(safe i: Int) -> CGFloat? {
        indices.contains(i) ? self[i] : nil
    }
}

/// Setup sheet for the single feedback unit. Opened directly from
/// the FEEDBACK pad's gear icon.
struct FeedbackSettingsSheet: View {
    @ObservedObject var state: FeedbackState
    @Environment(\.dismiss) private var dismiss
    @State private var showLFO = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("FEEDBACK")
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
                        label: "INPUT",
                        source: $state.inputSource,
                        hideFeedback: true
                    )
                    slider("Zoom", $state.zoom, in: 0.5...2.0)
                    slider("Pan X", $state.panX, in: -1...1)
                    slider("Pan Y", $state.panY, in: -1...1)
                    slider("Tilt", $state.tilt, in: -1...1)
                    slider("Persistence", $state.decay, in: 0...1.0)
                    slider("Input Gain", $state.feedbackMix, in: 0...2.0)
                    slider("Bloom", $state.luminosity, in: 0.2...3.0)
                    slider("Chroma Boost", $state.chromaBoost, in: 0...3)
                }
                .padding(20)
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showLFO) {
            LFOSettingsSheet(
                title: "FEEDBACK",
                lfo: AppState.shared.lfoEngine.lfo(for: LFOTargets.feedbackSlotID),
                availableTargets: AppState.shared.lfoEngine.availableTargets(forSlot: LFOTargets.feedbackSlotID),
                transport: AppState.shared.transport
            )
        }
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
}
