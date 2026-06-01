import SwiftUI

/// Per-ACIDBASS-pad sheet: a 16-step grid (gate / note / accent / slide),
/// the TB-303 voice knobs, and the background controls. The voice knobs
/// aren't @Published (they're read from the audio thread) so slider writes
/// bump a UUID tick to re-read, mirroring ACIDKICKSettingsSheet.
struct ACIDBASSSettingsSheet: View {
    @ObservedObject var source: ACIDBASSSource
    @ObservedObject var sequencer: BassSequencer
    @Environment(\.dismiss) private var dismiss

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
