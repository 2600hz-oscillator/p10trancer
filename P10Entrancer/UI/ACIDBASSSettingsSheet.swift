import SwiftUI

/// Per-ACIDBASS-pad sheet: a 16-step grid (gate / note / accent / slide),
/// the TB-303 voice knobs, and the background controls. The voice knobs
/// aren't @Published (they're read from the audio thread) so slider writes
/// bump a UUID tick to re-read, mirroring ACIDKICKSettingsSheet.
struct ACIDBASSSettingsSheet: View {
    @ObservedObject var source: ACIDBASSSource
    @ObservedObject var sequencer: BassSequencer
    @ObservedObject var sidechain: SidechainState
    let padIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var selectedStep: Int? = nil

    init(source: ACIDBASSSource, padIndex: Int) {
        self.source = source
        self.sequencer = source.sequencer
        self.sidechain = source.sidechain
        self.padIndex = padIndex
    }

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
                        stepCount: BassSequencer.stepCount,
                        octaveRange: 1...6,
                        assignNote: { step, semi in source.assignNote(stepIndex: step, semitoneFromC: semi) },
                        audition: { semi in source.audition(semitoneFromC: semi) }
                    )
                    knobSection
                    sidechainSection
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
            Text("ACIDBASS — TB-303")
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
            Text("16-STEP SEQUENCER — tap GATE to cursor a step, then a key to set its note")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            labeledRow("GATE", height: 38) { gateCell($0) }
            labeledRow("ACC")  { flagCell($0, keyPath: \.accent, color: .orange) }
            labeledRow("SLD")  { flagCell($0, keyPath: \.slide, color: .cyan) }
        }
    }

    private func labeledRow<Cell: View>(_ label: String,
                                        height: CGFloat = 30,
                                        @ViewBuilder cell: @escaping (Int) -> Cell) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 34, alignment: .leading)
            ForEach(0..<BassSequencer.stepCount, id: \.self) { i in cell(i) }
        }
        .frame(height: height)
    }

    private func gateCell(_ i: Int) -> some View {
        let step = sequencer.steps[i]
        let isCurrent = sequencer.currentStep == i
        let isSelected = selectedStep == i
        let bg: Color = step.enabled ? Color.green.opacity(isCurrent ? 0.9 : 0.55)
                                     : Color.white.opacity(0.06)
        let border: Color = isSelected ? .yellow : (isCurrent ? .white : .white.opacity(0.3))
        return Button {
            // First tap cursors the step (so the keyboard records into it);
            // second tap on the cursored step toggles its gate.
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

    private func flagCell(_ i: Int,
                          keyPath: WritableKeyPath<BassSequencer.Step, Bool>,
                          color: Color) -> some View {
        let on = sequencer.steps[i][keyPath: keyPath]
        return Button {
            sequencer.steps[i][keyPath: keyPath].toggle()
        } label: {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(on ? color.opacity(0.6) : Color.white.opacity(0.05))
                .overlay(Rectangle().strokeBorder(on ? color : Color.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 303 voice knobs

    private var knobSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("303 VOICE")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            Group {
                VoiceKnob(label: "Tune", voice: source.voice, keyPath: \.tuneSemitones, range: -12...12, format: "%.0f st")
                VoiceKnob(label: "Cutoff", voice: source.voice, keyPath: \.cutoffHz, range: 40...6000, format: "%.0f Hz")
                VoiceKnob(label: "Resonance", voice: source.voice, keyPath: \.resonance, range: 0...1, format: "%.2f")
                VoiceKnob(label: "Env Mod", voice: source.voice, keyPath: \.envAmount01, range: 0...1, format: "%.2f")
                VoiceKnob(label: "Decay", voice: source.voice, keyPath: \.decayMs, range: 50...3000, format: "%.0f ms")
                VoiceKnob(label: "Accent", voice: source.voice, keyPath: \.accentAmount01, range: 0...1, format: "%.2f")
                VoiceKnob(label: "Waveform", voice: source.voice, keyPath: \.waveform, range: 0...1, format: "%.2f")
                VoiceKnob(label: "Overdrive", voice: source.voice, keyPath: \.overdrive, range: 0...1, format: "%.2f")
                VoiceKnob(label: "Glide", voice: source.voice, keyPath: \.glideTime, range: 0.005...0.2, format: "%.3f s")
            }
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
            vizSlider("Ring zoom", $source.vizZoom, 0.3...2.5)
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

    // MARK: - Sidechain

    private var sidechainSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SIDECHAIN")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text("DUCK UNDER")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                Menu {
                    Button("None") { sidechain.triggerPad = nil; sidechain.enabled = false }
                    ForEach(0..<9, id: \.self) { j in
                        if j != padIndex {
                            Button("PAD \(j + 1)") { sidechain.triggerPad = j; sidechain.enabled = true }
                        }
                    }
                } label: {
                    Text(sidechain.triggerPad.map { "PAD \($0 + 1)" } ?? "None")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundStyle(sidechain.enabled ? .green : .white.opacity(0.6))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .overlay(Rectangle().strokeBorder(sidechain.enabled ? Color.green : Color.white.opacity(0.3), lineWidth: 1))
                }
            }
            if sidechain.enabled {
                scSlider("Amount", $sidechain.amount, 0...1, "%.2f")
                scSlider("Attack", $sidechain.attackMs, 0.5...100, "%.0f ms")
                scSlider("Release", $sidechain.releaseMs, 5...1000, "%.0f ms")
                scSlider("Threshold", $sidechain.thresholdDb, -60...0, "%.0f dB")
                scSlider("Ratio", $sidechain.ratio, 1...20, "%.1f")
                scSlider("SC HPF", $sidechain.scHpfHz, 20...1000, "%.0f Hz")
            }
        }
    }

    private func scSlider(_ label: String, _ b: Binding<Float>, _ range: ClosedRange<Float>, _ fmt: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(String(format: fmt, b.wrappedValue))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Slider(value: b, in: range).tint(.green)
        }
    }

    private func noteName(_ midi: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[((midi % 12) + 12) % 12] + "\(midi / 12 - 1)"
    }
}

/// A slider for a non-observable TB303Voice Double knob. Mirrors the value
/// in local @State so dragging stays smooth — writing straight to the voice
/// and bumping a UUID `.id` mid-drag tore down and rebuilt the Slider every
/// change, destroying the in-flight gesture (the reason the knobs couldn't
/// be dragged). Changes are pushed to the voice via onChange.
private struct VoiceKnob: View {
    let label: String
    let voice: TB303Voice
    let keyPath: ReferenceWritableKeyPath<TB303Voice, Double>
    let range: ClosedRange<Double>
    let format: String
    @State private var value: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(String(format: format, value))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Slider(value: $value, in: range)
                .tint(.orange)
                .onChange(of: value) { _, newValue in voice[keyPath: keyPath] = newValue }
        }
        .onAppear { value = voice[keyPath: keyPath] }
    }
}
