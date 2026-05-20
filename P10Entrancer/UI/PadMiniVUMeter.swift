import SwiftUI
import Combine

/// Slim per-pad VU meter. Mirrors the per-pad volume slider on the
/// opposite edge of the pad cell. Taps the pad's audio player
/// `instantRMS` — which is measured at the per-pad mixerNode output,
/// i.e. POST per-pad volume and POST mute. Lowering the volume slider
/// drops the meter in real time; clipping at the source shows as red
/// only when the user has the slider high enough for it to matter.
///
/// 12-segment LED strip, green → yellow → red. Pads with no audio
/// player (image source / master-feedback / etc.) render an
/// empty dimmed track that doesn't react.
struct PadMiniVUMeter: View {
    let pad: PadSlot

    var body: some View {
        if let player = pad.audioPlayer {
            ActiveMiniVU(player: player)
        } else {
            DimmedMiniVU()
        }
    }
}

private struct ActiveMiniVU: View {
    @ObservedObject var player: PadAudioPlayer
    @State private var displayLevel: Float = 0
    @State private var peakLevel: Float = 0
    @State private var peakHoldUntil: Date = .distantPast

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/15.0)) { context in
            VUSegments(level: CGFloat(displayLevel),
                       peak: CGFloat(peakLevel))
                .onChange(of: context.date) { _, now in
                    // Same headroom factor (6×) as the channel meter
                    // so a mid-volume hot signal hits the yellow zone.
                    let target = min(1, max(0, player.instantRMS * 6))
                    update(to: target, now: now)
                }
        }
    }

    private func update(to target: Float, now: Date) {
        if target > displayLevel {
            displayLevel = displayLevel + (target - displayLevel) * 0.55
        } else {
            displayLevel = max(0, displayLevel * 0.80)
        }
        if displayLevel >= peakLevel {
            peakLevel = displayLevel
            peakHoldUntil = now.addingTimeInterval(0.7)
        } else if now > peakHoldUntil {
            peakLevel = max(0, peakLevel - 0.025)
        }
    }
}

private struct DimmedMiniVU: View {
    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.4))
    }
}

private struct VUSegments: View {
    let level: CGFloat
    let peak: CGFloat
    private static let segmentCount = 12

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            let gap: CGFloat = 1
            let segH = (h - gap * CGFloat(Self.segmentCount - 1)) / CGFloat(Self.segmentCount)
            let lit = Int(level * CGFloat(Self.segmentCount) + 0.001)
            let peakIdx = Int(peak * CGFloat(Self.segmentCount) + 0.001) - 1
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.4)
                VStack(spacing: gap) {
                    ForEach(0..<Self.segmentCount, id: \.self) { i in
                        // Segments are numbered 0=top, N-1=bottom in
                        // the VStack — we render bottom-first by
                        // flipping the index here.
                        let segFromBottom = Self.segmentCount - 1 - i
                        let isLit = segFromBottom < lit
                        let isPeak = segFromBottom == peakIdx
                        Rectangle()
                            .fill(color(for: segFromBottom,
                                        lit: isLit,
                                        isPeak: isPeak))
                            .frame(width: w, height: segH)
                    }
                }
            }
        }
    }

    private func color(for index: Int, lit: Bool, isPeak: Bool) -> Color {
        if !lit && !isPeak { return Color.white.opacity(0.06) }
        // Top-third = red, mid = yellow, bottom = green.
        let frac = Double(index) / Double(Self.segmentCount - 1)
        let base: Color
        if frac > 0.83 { base = .red }
        else if frac > 0.58 { base = .yellow }
        else { base = .green }
        if isPeak { return base }
        return base.opacity(0.85)
    }
}
