import SwiftUI

/// Source picker shared by keyer FG/BG and feedback input. Lets the
/// user choose any of the 9 source pads, the OTHER keyer (if currently
/// editing a keyer), or the FEEDBACK unit (if currently editing a
/// keyer). Cross-references resolve via 1-frame feedback in the
/// renderers — see KeyerRenderer.sourceResolver.
struct SourcePicker: View {
    let label: String
    @Binding var source: SourceRef
    /// When non-nil, this keyer's index is excluded from the picker
    /// (a keyer can't pick itself as input). Pass nil for feedback /
    /// xyz (which use their own exclusion fields).
    let editingKeyerIndex: Int?
    /// When non-nil, this XYZ unit's index is excluded.
    var editingXYZIndex: Int? = nil
    /// When false, hide the FEEDBACK option (e.g., editing the
    /// feedback unit itself).
    let allowFeedback: Bool
    /// When false, hide XYZ chips (no slot edits its own input from
    /// another XYZ — kept as a flexibility lever).
    var allowXYZ: Bool = true
    /// Number of XYZ units to expose chips for. Defaults to 3 to
    /// match `XYZSystem.units.count`.
    var xyzCount: Int = 3

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
                    ForEach([0, 1], id: \.self) { i in
                        if editingKeyerIndex != i {
                            chip(label: "K\(i + 1)", on: source == .keyer(i), tint: .green) {
                                source = .keyer(i)
                            }
                        }
                    }
                    if allowFeedback {
                        chip(label: "FB", on: source == .feedback, tint: .purple) {
                            source = .feedback
                        }
                    }
                    if allowXYZ {
                        ForEach(0..<xyzCount, id: \.self) { i in
                            if editingXYZIndex != i {
                                chip(label: "X\(i + 1)", on: source == .xyz(i), tint: .pink) {
                                    source = .xyz(i)
                                }
                            }
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
                .frame(width: 36, height: 28)
                .background(on ? tint : Color.white.opacity(0.06))
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Setup sheet for one keyer. Replaces the dispatched
/// KeyerControlsView when accessed via the new output-pad gear icon.
struct KeyerSettingsSheet: View {
    @ObservedObject var keyer: KeyerState
    let keyerIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var showLFO = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("KEYER \(keyerIndex + 1)")
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
                        editingKeyerIndex: keyerIndex,
                        allowFeedback: true
                    )
                    SourcePicker(
                        label: "BACKGROUND",
                        source: $keyer.backgroundSource,
                        editingKeyerIndex: keyerIndex,
                        allowFeedback: true
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
            let slot = LFOTargets.slotID(forKeyerIndex: keyerIndex)
            LFOSettingsSheet(
                title: "KEYER \(keyerIndex + 1)",
                lfo: AppState.shared.lfoEngine.lfo(for: slot),
                availableTargets: AppState.shared.lfoEngine.availableTargets(forSlot: slot),
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

    /// SwiftUI's system ColorPicker uses the native iOS color wheel
    /// (the same one used in Notes etc.) — full hue circle + sat/
    /// brightness sliders + recently used. Binding-bridged into the
    /// keyer's SIMD3<Float> RGB triplet.
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

/// Setup sheet for the single feedback unit.
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
                        editingKeyerIndex: nil,
                        allowFeedback: false
                    )
                    slider("Zoom", $state.zoom, in: 0.5...2.0)
                    slider("Pan X", $state.panX, in: -1...1)
                    slider("Pan Y", $state.panY, in: -1...1)
                    slider("Tilt", $state.tilt, in: -1...1)
                    // The additive-blend topology lets the full range
                    // be usable — old slider only went 0.5..1.0 because
                    // crossfade-style feedback would crush the source
                    // below that. Now 0 = no feedback, ~0.95 = CRT-
                    // phosphor trails, 0.99 = very long.
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
