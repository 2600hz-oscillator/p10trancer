import SwiftUI

struct MixerPanelView: View {
    let pads: PadSystem
    @ObservedObject var mixer: MixerState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("MIXER")
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                Button("CLOSE") { dismiss() }
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16).padding(.top, 16)

            Text("Only pads routed to CH1 or CH2 emit audio. Set per-pad volumes here.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 16)

            HStack(alignment: .top, spacing: 8) {
                ForEach(0..<PadSystem.padCount, id: \.self) { i in
                    channelStrip(index: i)
                }
                Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1)
                masterStrip
            }
            .padding(.horizontal, 16)
            Spacer()
        }
        .background(.black)
        .preferredColorScheme(.dark)
    }

    private func channelStrip(index: Int) -> some View {
        let isCh1 = mixer.ch1PadIndex == index
        let isCh2 = mixer.ch2PadIndex == index
        let pad = pads.pads[index]
        let routedColor: Color = isCh1 ? .cyan : (isCh2 ? .orange : Color.white.opacity(0.18))
        let routedLabel: String = isCh1 ? "CH1" : (isCh2 ? "CH2" : "—")
        return VStack(spacing: 6) {
            Text(routedLabel)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(routedColor)
                .frame(width: 56, height: 16)
                .background(routedColor.opacity(isCh1 || isCh2 ? 0.25 : 0))
            VerticalSlider(
                value: Binding(
                    get: { pad.audioPlayer?.volume ?? 0 },
                    set: { pad.audioPlayer?.volume = $0 }
                ),
                tint: routedColor
            )
            .frame(width: 56, height: 220)
            Text(String(format: "%.2f", pad.audioPlayer?.volume ?? 0))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
            Text("PAD \(index + 1)")
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
        }
    }

    private var masterStrip: some View {
        VStack(spacing: 6) {
            Text("MASTER")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 64, height: 16)
            VerticalSlider(
                value: Binding(
                    get: { mixer.masterVolume },
                    set: { v in mixer.masterVolume = v; AudioEngine.shared.masterVolume = v }
                ),
                tint: .white
            )
            .frame(width: 64, height: 220)
            Text(String(format: "%.2f", mixer.masterVolume))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            Text("OUT")
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
        }
    }
}

private struct VerticalSlider: View {
    @Binding var value: Float
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            let knobY = (1.0 - CGFloat(max(0, min(1, value)))) * (h - 14)
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                    .frame(maxWidth: .infinity, alignment: .center)
                Rectangle()
                    .fill(tint.opacity(0.7))
                    .frame(width: 4, height: max(0, h - knobY - 7))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .offset(y: knobY + 7)
                RoundedRectangle(cornerRadius: 3)
                    .fill(tint)
                    .frame(width: w - 12, height: 14)
                    .offset(y: knobY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let clamped = max(0, min(h - 14, drag.location.y - 7))
                        value = Float(1.0 - clamped / (h - 14))
                    }
            )
        }
    }
}
