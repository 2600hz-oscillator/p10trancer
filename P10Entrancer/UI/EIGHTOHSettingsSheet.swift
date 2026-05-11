import SwiftUI

/// Per-EIGHTOH-pad sheet: 4 tracks × 16 steps + per-track voice
/// picker. Tap a step to toggle it; tap the voice chip on a track
/// to cycle through Kick / Snare / Hat / Tom.
struct EIGHTOHSettingsSheet: View {
    @ObservedObject var source: EIGHTOHSource
    @ObservedObject var sequencer: DrumSequencer
    @Environment(\.dismiss) private var dismiss

    init(source: EIGHTOHSource) {
        self.source = source
        self.sequencer = source.sequencer
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("DRUM SEQUENCER — tap steps to toggle; tap a voice chip to cycle types")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                    ForEach(0..<DrumSequencer.trackCount, id: \.self) { trackIdx in
                        trackRow(trackIdx)
                    }
                }
                .padding(20)
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("EIGHTOH — 4×16 DRUMS")
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white).tracking(2.0)
            Spacer()
            Button("CLOSE") { dismiss() }
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func trackRow(_ trackIdx: Int) -> some View {
        let track = sequencer.tracks[trackIdx]
        return HStack(spacing: 6) {
            voiceChip(trackIdx: trackIdx, type: track.voiceType)
                .frame(width: 90)
            HStack(spacing: 3) {
                ForEach(0..<DrumSequencer.stepCount, id: \.self) { stepIdx in
                    stepButton(trackIdx: trackIdx, stepIdx: stepIdx)
                }
            }
        }
        .frame(height: 40)
    }

    private func voiceChip(trackIdx: Int, type: DrumVoiceType) -> some View {
        let color: Color = {
            switch type {
            case .kick:  return .red
            case .snare: return .orange
            case .hat:   return .yellow
            case .tom:   return .purple
            }
        }()
        return Button {
            // Cycle to the next voice type.
            let next = DrumVoiceType(rawValue: (type.rawValue + 1) % DrumVoiceType.allCases.count)
                       ?? .kick
            sequencer.tracks[trackIdx].voiceType = next
        } label: {
            Text(type.label)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(color.opacity(0.6))
                .overlay(Rectangle().strokeBorder(color, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func stepButton(trackIdx: Int, stepIdx: Int) -> some View {
        let on = sequencer.tracks[trackIdx].steps[stepIdx]
        let isCurrent = sequencer.currentStep == stepIdx
        let isBeatMark = stepIdx % 4 == 0  // visual emphasis every 4 steps
        let fill: Color = on ? Color.green.opacity(isCurrent ? 0.9 : 0.55)
                              : (isBeatMark ? Color.white.opacity(0.10) : Color.white.opacity(0.05))
        let border: Color = isCurrent ? .white : .white.opacity(0.3)
        return Button {
            sequencer.tracks[trackIdx].steps[stepIdx].toggle()
        } label: {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(fill)
                .overlay(Rectangle().strokeBorder(border, lineWidth: isCurrent ? 2 : 1))
        }
        .buttonStyle(.plain)
    }
}
