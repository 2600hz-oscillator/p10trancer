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
    /// (a keyer can't pick itself as input). Pass nil for feedback
    /// (which never picks itself either).
    let editingKeyerIndex: Int?
    /// When false, hide the FEEDBACK option (e.g., editing the
    /// feedback unit itself).
    let allowFeedback: Bool

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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("KEYER \(keyerIndex + 1)")
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white).tracking(2.0)
                Spacer()
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
                    slider("Threshold", $keyer.threshold, in: 0...1)
                    slider("Softness", $keyer.softness, in: 0.001...0.5)
                }
                .padding(20)
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
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

/// Setup sheet for the single feedback unit.
struct FeedbackSettingsSheet: View {
    @ObservedObject var state: FeedbackState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("FEEDBACK")
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white).tracking(2.0)
                Spacer()
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
                    slider("Decay", $state.decay, in: 0.5...1.0)
                    slider("Feedback Mix", $state.feedbackMix, in: 0...1)
                    slider("Luminosity", $state.luminosity, in: 0...2)
                    slider("Chroma Boost", $state.chromaBoost, in: 0...3)
                }
                .padding(20)
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
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
