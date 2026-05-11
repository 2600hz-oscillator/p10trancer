import SwiftUI
import UniformTypeIdentifiers

/// Per-instrument sheet: WAVECEL controls + 16-step grid + 1-octave
/// keyboard with OCTAVE arrows + ADSR. Layout matches the WAVECEL
/// card from patchtogether.live — tune / fine / morph / spread / fold
/// plus a wavetable picker that supports the bundled tables or any
/// E352-format WAV from the Files picker.
struct InstrumentSettingsSheet: View {
    @ObservedObject var instrument: InstrumentSource
    @ObservedObject var sequencer: StepSequencer
    @Environment(\.dismiss) private var dismiss

    @State private var selectedStep: Int? = nil
    @State private var importerVisible: Bool = false
    @State private var tuneTick = UUID()  // forces re-render when the
    @State private var fineTick = UUID()  // synth's k-rate values change
    @State private var morphTick = UUID()
    @State private var spreadTick = UUID()
    @State private var foldTick = UUID()

    private static let semitoneLabels = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// Names of WAVs bundled under Resources/Wavetables.
    private static let bundledTables: [(label: String, resource: String)] = [
        ("VOXSYNTH", "VOXSYNTH"),
        ("ACID_RIN", "ACID_RIN"),
        ("DEFAULT (synth)", "")  // empty = use the synthesized default
    ]

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
                    waveCelSection
                    stepGridSection
                    keyboardSection
                    adsrSection
                    reverbSection
                }
                .padding(20)
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $importerVisible,
                      allowedContentTypes: [UTType.wav, UTType.audio],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let table = WaveCelTableLoader.load(url: url, label: url.deletingPathExtension().lastPathComponent) {
                    instrument.loadTable(table)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("WAVECEL — INSTRUMENT")
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white).tracking(2.0)
            Spacer()
            Button("CLOSE") { dismiss() }
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: - WAVECEL block

    private var waveCelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("WAVETABLE")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(instrument.wavetableLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.white.opacity(0.08))
                    .overlay(Rectangle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
            }
            HStack(spacing: 8) {
                ForEach(Self.bundledTables, id: \.label) { entry in
                    Button(entry.label) {
                        if entry.resource.isEmpty {
                            instrument.loadTable(WaveCelSynth.defaultTable())
                        } else if let t = WaveCelTableLoader.loadBundled(entry.resource) {
                            instrument.loadTable(t)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
                Button("Load WAV…") { importerVisible = true }
                    .buttonStyle(.bordered)
                    .tint(.blue)
            }
            .font(.system(size: 11, design: .monospaced))
            // Five WAVECEL params, two rows for breathing room.
            HStack(spacing: 12) {
                paramSlider(label: "TUNE", value: synthBinding(\.tune, tick: $tuneTick),
                            range: -36...36, unit: "st", format: "%+.0f")
                paramSlider(label: "FINE", value: synthBinding(\.fine, tick: $fineTick),
                            range: -100...100, unit: "¢", format: "%+.0f")
                paramSlider(label: "MORPH", value: synthBinding(\.morph, tick: $morphTick),
                            range: 0...1, unit: "", format: "%.2f")
            }
            HStack(spacing: 12) {
                paramSlider(label: "SPREAD", value: synthBinding(\.spread, tick: $spreadTick),
                            range: 1...5, unit: "", format: "%.1f")
                paramSlider(label: "FOLD", value: synthBinding(\.fold, tick: $foldTick),
                            range: 0...1, unit: "", format: "%.2f")
                Spacer().frame(maxWidth: .infinity)
            }
        }
    }

    /// WAVECEL params live on a non-@Published synth, so we go through
    /// a manual binding + UUID-tick re-render to keep the slider value
    /// in sync. (The synth isn't an ObservableObject because its
    /// fields are read from the audio thread; @Published would push
    /// objectWillChange notifications on every parameter tweak which
    /// is fine, but it would also force MainActor isolation. The
    /// UUID-tick is a small workaround.)
    private func synthBinding(_ keyPath: ReferenceWritableKeyPath<WaveCelSynth, Float>,
                              tick: Binding<UUID>) -> Binding<Float> {
        Binding(
            get: { instrument.synth[keyPath: keyPath] },
            set: { newValue in
                instrument.synth[keyPath: keyPath] = newValue
                tick.wrappedValue = UUID()
            }
        )
    }

    private func paramSlider(label: String,
                              value: Binding<Float>,
                              range: ClosedRange<Float>,
                              unit: String,
                              format: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
                Text("\(String(format: format, value.wrappedValue))\(unit)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Slider(value: value, in: range).tint(.orange)
        }
    }

    // MARK: - Step grid

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

    // MARK: - Keyboard

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
                HStack(spacing: 1) {
                    ForEach(0..<whiteCount, id: \.self) { wi in
                        let semi = whiteIndices[wi]
                        keyButton(semi: semi, isBlack: false)
                            .frame(width: whiteW - 1)
                    }
                }
                .frame(height: h)
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

    // MARK: - ADSR

    private var adsrSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADSR")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 12) {
                adsrSlider(label: "ATTACK",
                           value: adsrBinding(\.attack),
                           range: 0.001...2.0)
                adsrSlider(label: "DECAY",
                           value: adsrBinding(\.decay),
                           range: 0.001...2.0)
                adsrSlider(label: "SUSTAIN",
                           value: adsrBinding(\.sustain),
                           range: 0...1)
                adsrSlider(label: "RELEASE",
                           value: adsrBinding(\.release),
                           range: 0.001...3.0)
            }
        }
    }

    // MARK: - Reverb

    private var reverbSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("REVERB")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 12) {
                adsrSlider(label: "SIZE",
                           value: reverbBinding(\.size),
                           range: 0...1)
                adsrSlider(label: "DAMP",
                           value: reverbBinding(\.damp),
                           range: 0...1)
                adsrSlider(label: "WET/DRY",
                           value: reverbBinding(\.wet),
                           range: 0...1)
            }
        }
    }

    private func reverbBinding(_ keyPath: ReferenceWritableKeyPath<SimpleReverb, Float>) -> Binding<Float> {
        Binding(
            get: { instrument.reverb[keyPath: keyPath] },
            set: { instrument.reverb[keyPath: keyPath] = $0 }
        )
    }

    private func adsrBinding(_ keyPath: ReferenceWritableKeyPath<ADSREnvelope, Float>) -> Binding<Float> {
        Binding(
            get: { instrument.adsr[keyPath: keyPath] },
            set: { instrument.adsr[keyPath: keyPath] = $0 }
        )
    }

    private func adsrSlider(label: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
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
