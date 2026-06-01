import SwiftUI

/// Per-ACIDBASS-pad sheet: a 16-step grid (gate / note / accent / slide),
/// the TB-303 voice knobs, and the background controls. The voice knobs
/// aren't @Published (they're read from the audio thread) so slider writes
/// bump a UUID tick to re-read, mirroring ACIDKICKSettingsSheet.
struct ACIDBASSSettingsSheet: View {
    @ObservedObject var source: ACIDBASSSource
    @ObservedObject var sequencer: BassSequencer
    @Environment(\.dismiss) private var dismiss
    @State private var voiceParamTick = UUID()

    init(source: ACIDBASSSource) {
        self.source = source
        self.sequencer = source.sequencer
    }

    private let noteLo = 24   // C1
    private let noteHi = 60   // C4

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sequencerSection
                    knobSection
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
            Text("16-STEP SEQUENCER — gate / note / accent / slide")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            labeledRow("GATE") { gateCell($0) }
            labeledRow("NOTE") { noteCell($0) }
            labeledRow("ACC")  { flagCell($0, keyPath: \.accent, color: .orange) }
            labeledRow("SLD")  { flagCell($0, keyPath: \.slide, color: .cyan) }
        }
    }

    private func labeledRow<Cell: View>(_ label: String,
                                        @ViewBuilder cell: @escaping (Int) -> Cell) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 34, alignment: .leading)
            ForEach(0..<BassSequencer.stepCount, id: \.self) { i in cell(i) }
        }
        .frame(height: 30)
    }

    private func gateCell(_ i: Int) -> some View {
        let on = sequencer.steps[i].enabled
        let isCurrent = sequencer.currentStep == i
        let beat = i % 4 == 0
        return Button {
            sequencer.steps[i].enabled.toggle()
        } label: {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(on ? Color.green.opacity(isCurrent ? 0.9 : 0.55)
                               : (beat ? Color.white.opacity(0.10) : Color.white.opacity(0.05)))
                .overlay(Rectangle().strokeBorder(isCurrent ? .white : .white.opacity(0.3),
                                                  lineWidth: isCurrent ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private func noteCell(_ i: Int) -> some View {
        Menu {
            ForEach((noteLo...noteHi).reversed(), id: \.self) { n in
                Button(noteName(n)) { sequencer.steps[i].note = n }
            }
        } label: {
            Text(noteName(sequencer.steps[i].note))
                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(sequencer.steps[i].enabled ? 1 : 0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.06))
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
        }
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
                knob("Tune", \.tuneSemitones, -12...12, "%.0f st")
                knob("Cutoff", \.cutoffHz, 40...6000, "%.0f Hz")
                knob("Resonance", \.resonance, 0...1, "%.2f")
                knob("Env Mod", \.envAmount01, 0...1, "%.2f")
                knob("Decay", \.decayMs, 50...3000, "%.0f ms")
                knob("Accent", \.accentAmount01, 0...1, "%.2f")
                knob("Waveform", \.waveform, 0...1, "%.2f")
                knob("Overdrive", \.overdrive, 0...1, "%.2f")
                knob("Glide", \.glideTime, 0.005...0.2, "%.3f s")
            }
        }
        .id(voiceParamTick)
    }

    private func knob(_ label: String,
                      _ kp: ReferenceWritableKeyPath<TB303Voice, Double>,
                      _ range: ClosedRange<Double>,
                      _ fmt: String) -> some View {
        let v = source.voice
        let binding = Binding<Double>(
            get: { v[keyPath: kp] },
            set: { v[keyPath: kp] = $0; voiceParamTick = UUID() }
        )
        return VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(String(format: fmt, binding.wrappedValue))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Slider(value: binding, in: range).tint(.orange)
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

    private func noteName(_ midi: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[((midi % 12) + 12) % 12] + "\(midi / 12 - 1)"
    }
}
