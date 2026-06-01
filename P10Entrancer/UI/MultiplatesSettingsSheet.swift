import SwiftUI

/// Per-MULTIPLATES-pad sheet: a 16-step grid (GATE cursor-select + per-step
/// MODEL dropdown), the shared keyboard for note entry, global macro knobs
/// (harmonics/timbre/morph/level), and background controls.
struct MultiplatesSettingsSheet: View {
    @ObservedObject var source: MultiplatesSource
    @ObservedObject var sequencer: MultiplatesSequencer
    @Environment(\.dismiss) private var dismiss
    @State private var selectedStep: Int? = nil

    init(source: MultiplatesSource) {
        self.source = source
        self.sequencer = source.sequencer
    }

    /// Compact per-step model labels (full names shown in the dropdown).
    private static let shortNames = ["VA", "WS", "F2", "F6", "CH", "AD", "ST", "MO",
                                     "KK", "SN", "HH", "WT", "GR", "SP"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sequencerSection
                    StepKeyboardEntry(
                        selectedStep: $selectedStep,
                        octave: $source.octave,
                        stepCount: MultiplatesSequencer.stepCount,
                        octaveRange: 1...6,
                        assignNote: { step, semi in source.assignNote(stepIndex: step, semitoneFromC: semi) },
                        audition: { semi in source.audition(semitoneFromC: semi, stepIndex: selectedStep) }
                    )
                    macroSection
                    vizSection
                }
                .padding(20)
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("MULTIPLATES — MACRO OSC")
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white).tracking(2.0)
            Spacer()
            Button("CLOSE") { dismiss() }
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: - Sequencer

    private var sequencerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("16-STEP — tap GATE to cursor a step + a key for its note; pick a MODEL per step")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            labeledRow("GATE", height: 38) { gateCell($0) }
            labeledRow("MODEL", height: 28) { modelCell($0) }
        }
    }

    private func labeledRow<Cell: View>(_ label: String,
                                        height: CGFloat,
                                        @ViewBuilder cell: @escaping (Int) -> Cell) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 38, alignment: .leading)
            ForEach(0..<MultiplatesSequencer.stepCount, id: \.self) { i in cell(i) }
        }
        .frame(height: height)
    }

    private func gateCell(_ i: Int) -> some View {
        let step = sequencer.steps[i]
        let isCurrent = sequencer.currentStep == i
        let isSelected = selectedStep == i
        let bg: Color = step.enabled ? Color.cyan.opacity(isCurrent ? 0.9 : 0.5) : Color.white.opacity(0.06)
        let border: Color = isSelected ? .yellow : (isCurrent ? .white : .white.opacity(0.3))
        return Button {
            if selectedStep == i { source.toggleStep(i); selectedStep = nil }
            else { selectedStep = i }
        } label: {
            VStack(spacing: 1) {
                Text("\(i + 1)")
                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Text(step.enabled ? noteName(step.note) : "—")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(bg)
            .overlay(Rectangle().strokeBorder(border, lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private func modelCell(_ i: Int) -> some View {
        let m = sequencer.steps[i].model
        return Menu {
            Button("— (hold last)") { sequencer.steps[i].model = nil }
            ForEach(MacroModel.allCases) { model in
                Button(model.displayName) { sequencer.steps[i].model = model.rawValue }
            }
        } label: {
            Text(m.map { Self.shortNames[$0] } ?? "—")
                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                .foregroundStyle(m == nil ? .white.opacity(0.4) : .white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.06))
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
        }
    }

    // MARK: - Macros

    private var macroSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MACROS")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            MacroKnob(label: "Harmonics", voice: source.voice, keyPath: \.harmonics)
            MacroKnob(label: "Timbre", voice: source.voice, keyPath: \.timbre)
            MacroKnob(label: "Morph", voice: source.voice, keyPath: \.morph)
            MacroKnob(label: "Level", voice: source.voice, keyPath: \.level)
        }
    }

    // MARK: - Background

    private var vizSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BACKGROUND")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            vizSlider("Warp speed", $source.vizWarpSpeed, 0...4)
            vizSlider("Hue speed", $source.vizHueSpeed, 0...1)
            vizSlider("Zoom", $source.vizZoom, 0.3...2.5)
        }
    }

    private func vizSlider(_ label: String, _ b: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(String(format: "%.2f", b.wrappedValue))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Slider(value: b, in: range).tint(.purple)
        }
    }

    private func noteName(_ midi: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[((midi % 12) + 12) % 12] + "\(midi / 12 - 1)"
    }
}

/// Slider for a non-observable MacroVoice Double macro (local @State so the
/// drag stays smooth; writes to the voice via onChange).
private struct MacroKnob: View {
    let label: String
    let voice: MacroVoice
    let keyPath: ReferenceWritableKeyPath<MacroVoice, Double>
    @State private var value: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(String(format: "%.2f", value))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Slider(value: $value, in: 0...1)
                .tint(.cyan)
                .onChange(of: value) { _, newValue in voice[keyPath: keyPath] = newValue }
        }
        .onAppear { value = voice[keyPath: keyPath] }
    }
}
