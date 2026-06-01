import SwiftUI

/// Shared note-entry keyboard for sequenced instruments. The host grid puts
/// the cursor on a step (binds `selectedStep`); tapping a key here records
/// that note into the cursored step and advances the cursor (wrapping at
/// `stepCount`). With no cursor, keys audition live via the `audition`
/// closure. Extracted from InstrumentSettingsSheet so WAVETABLE, ACIDBASS,
/// and MULTIPLATES all use the identical mechanism.
struct StepKeyboardEntry: View {
    @Binding var selectedStep: Int?
    @Binding var octave: Int
    let stepCount: Int
    let octaveRange: ClosedRange<Int>
    /// (stepIndex, semitoneFromC) — record a note into a step.
    let assignNote: (Int, Int) -> Void
    /// (semitoneFromC) — audition a live note when no step is cursored.
    let audition: (Int) -> Void

    init(selectedStep: Binding<Int?>,
         octave: Binding<Int>,
         stepCount: Int,
         octaveRange: ClosedRange<Int> = 0...8,
         assignNote: @escaping (Int, Int) -> Void,
         audition: @escaping (Int) -> Void) {
        self._selectedStep = selectedStep
        self._octave = octave
        self.stepCount = stepCount
        self.octaveRange = octaveRange
        self.assignNote = assignNote
        self.audition = audition
    }

    private static let semitoneLabels = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            keyboard
        }
    }

    private var header: some View {
        HStack {
            Text("KEYBOARD")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text("OCTAVE")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            Button {
                octave = max(octaveRange.lowerBound, octave - 1)
            } label: {
                Image(systemName: "arrowtriangle.down.fill")
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(Color.white.opacity(0.08))
                    .overlay(Rectangle().strokeBorder(Color.white.opacity(0.3)))
            }
            .buttonStyle(.plain)
            Text("\(octave)")
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 22)
            Button {
                octave = min(octaveRange.upperBound, octave + 1)
            } label: {
                Image(systemName: "arrowtriangle.up.fill")
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(Color.white.opacity(0.08))
                    .overlay(Rectangle().strokeBorder(Color.white.opacity(0.3)))
            }
            .buttonStyle(.plain)
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
                // Record + advance the cursor so a melody can be walked in.
                assignNote(step, semi)
                selectedStep = (step + 1) % stepCount
            } else {
                audition(semi)
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
}
