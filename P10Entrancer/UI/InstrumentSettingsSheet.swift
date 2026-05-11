import SwiftUI

/// Per-instrument sheet: 16-step grid + 1-octave keyboard + OCTAVE
/// arrows + ADSR + wavetable position. Workflow:
///   1. Tap a step → step becomes the "selected" target
///   2. Tap a key → that note is assigned to the selected step and
///      the step turns on
///   3. Tap a step again to toggle its enabled state
struct InstrumentSettingsSheet: View {
    @ObservedObject var instrument: InstrumentSource
    @ObservedObject var sequencer: StepSequencer
    @Environment(\.dismiss) private var dismiss

    @State private var selectedStep: Int? = nil

    /// SF-style note labels for the bottom row of the keyboard.
    private static let semitoneLabels = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private static let blackKeys: Set<Int> = [1, 3, 6, 8, 10]

    init(instrument: InstrumentSource) {
        self.instrument = instrument
        self.sequencer = instrument.sequencer
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    stepGridSection
                    keyboardSection
                    waveAndADSRSection
                }
                .padding(20)
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("INSTRUMENT — WAVETABLE")
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white).tracking(2.0)
            Spacer()
            Button("CLOSE") { dismiss() }
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var stepGridSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STEPS — tap to toggle on/off; tap a key to assign a note to a selected step")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 4) {
                ForEach(0..<StepSequencer.stepCount, id: \.self) { i in
                    stepCell(i)
                }
            }
            .frame(height: 56)
        }
    }

    private func stepCell(_ i: Int) -> some View {
        let step = sequencer.steps[i]
        let isCurrent = sequencer.currentStep == i
        let isSelected = selectedStep == i
        let bg: Color = step.enabled ? Color.green.opacity(isCurrent ? 0.85 : 0.55) : Color.white.opacity(0.06)
        let border: Color = isSelected ? .yellow : (isCurrent ? .white : .white.opacity(0.3))
        return Button {
            if selectedStep == i {
                // Tapping the already-selected step toggles its state.
                instrument.toggleStep(i)
                selectedStep = nil
            } else {
                selectedStep = i
            }
        } label: {
            VStack(spacing: 2) {
                Text("\(i + 1)")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
                Text(step.enabled ? Self.noteLabel(midi: step.note) : "—")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(bg)
            .overlay(Rectangle().strokeBorder(border, lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private static func noteLabel(midi: Int) -> String {
        let octave = midi / 12 - 1
        let semi = midi % 12
        return "\(semitoneLabels[semi])\(octave)"
    }

    private var keyboardSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("KEYBOARD")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text("OCTAVE")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Button {
                    instrument.octave = max(0, instrument.octave - 1)
                } label: {
                    Image(systemName: "arrowtriangle.down.fill")
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(Color.white.opacity(0.08))
                        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.3)))
                }
                .buttonStyle(.plain)
                Text("\(instrument.octave)")
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 22)
                Button {
                    instrument.octave = min(8, instrument.octave + 1)
                } label: {
                    Image(systemName: "arrowtriangle.up.fill")
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(Color.white.opacity(0.08))
                        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.3)))
                }
                .buttonStyle(.plain)
            }
            keyboard
        }
    }

    private var keyboard: some View {
        // 12 keys laid out as a 1-octave piano. Black keys are
        // rendered as smaller, taller-z overlays so they look like
        // actual sharps; white keys handle the gaps. Picking a key
        // when a step is selected assigns that note to the step.
        GeometryReader { geo in
            let whiteIndices = [0, 2, 4, 5, 7, 9, 11]
            let blackPositions: [(semi: Int, after: Int)] = [
                (1, 0), (3, 1), (6, 3), (8, 4), (10, 5)
            ]
            let whiteCount = whiteIndices.count
            let whiteW = geo.size.width / CGFloat(whiteCount)
            let h = geo.size.height
            let blackW = whiteW * 0.6
            let blackH = h * 0.6
            ZStack(alignment: .topLeading) {
                // White keys
                HStack(spacing: 1) {
                    ForEach(0..<whiteCount, id: \.self) { wi in
                        let semi = whiteIndices[wi]
                        keyButton(semi: semi, isBlack: false)
                            .frame(width: whiteW - 1)
                    }
                }
                .frame(height: h)
                // Black keys overlaid at proper positions
                ForEach(0..<blackPositions.count, id: \.self) { bi in
                    let pos = blackPositions[bi]
                    keyButton(semi: pos.semi, isBlack: true)
                        .frame(width: blackW, height: blackH)
                        .position(x: CGFloat(pos.after + 1) * whiteW - blackW / 2 + blackW / 2,
                                  y: blackH / 2)
                        .offset(x: -blackW / 2)
                }
            }
        }
        .frame(height: 90)
    }

    private func keyButton(semi: Int, isBlack: Bool) -> some View {
        let label = Self.semitoneLabels[semi]
        return Button {
            if let step = selectedStep {
                instrument.assignNote(stepIndex: step, semitoneFromC: semi)
                selectedStep = nil
            } else {
                // Preview: temporarily play the note via a single
                // gate cycle. Quick on/off so the user can audition
                // without assigning.
                instrument.synth.frequencyHz = StepSequencer.frequencyHz(
                    forNote: (instrument.octave + 1) * 12 + semi)
                instrument.adsr.setGate(true)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    instrument.adsr.setGate(false)
                }
            }
        } label: {
            VStack {
                Spacer()
                Text(label)
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(isBlack ? .white : .black)
                    .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isBlack ? Color.black : Color.white)
            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var waveAndADSRSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("WAVE POSITION")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Slider(value: $instrument.wavePosition, in: 0...1).tint(.orange)
            }
            HStack(spacing: 12) {
                adsrKnob(label: "ATTACK",
                         value: Binding(get: { instrument.adsr.attack },
                                        set: { instrument.adsr.attack = $0 }),
                         range: 0.001...2.0)
                adsrKnob(label: "DECAY",
                         value: Binding(get: { instrument.adsr.decay },
                                        set: { instrument.adsr.decay = $0 }),
                         range: 0.001...2.0)
                adsrKnob(label: "SUSTAIN",
                         value: Binding(get: { instrument.adsr.sustain },
                                        set: { instrument.adsr.sustain = $0 }),
                         range: 0...1)
                adsrKnob(label: "RELEASE",
                         value: Binding(get: { instrument.adsr.release },
                                        set: { instrument.adsr.release = $0 }),
                         range: 0.001...3.0)
            }
        }
    }

    private func adsrKnob(label: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
            Slider(value: value, in: range).tint(.cyan)
            Text(String(format: "%.3f", value.wrappedValue))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}
