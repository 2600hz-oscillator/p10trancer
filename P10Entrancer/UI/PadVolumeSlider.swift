import SwiftUI

/// Slim vertical volume slider drawn in the strip the Metal grid
/// reserves to the left of each pad's video. Adjusts the pad's
/// PadAudioPlayer.volume directly so the user can balance audio
/// without ever opening the mixer panel.
///
/// Pads with no audio player (image source, master-feedback source,
/// etc.) render a dimmed placeholder track that doesn't respond to
/// drags — keeps the layout consistent without giving the user a
/// dead control.
struct PadVolumeSlider: View {
    let pad: PadSlot

    var body: some View {
        if let player = pad.audioPlayer {
            ActiveVolumeBar(player: player)
        } else {
            DimmedTrack()
        }
    }
}

private struct ActiveVolumeBar: View {
    @ObservedObject var player: PadAudioPlayer
    @State private var dragging: Bool = false

    var body: some View {
        GeometryReader { geo in
            let trackInsetX: CGFloat = 4
            let trackInsetY: CGFloat = 8
            let trackW = max(2, geo.size.width - trackInsetX * 2)
            let trackH = max(10, geo.size.height - trackInsetY * 2)
            let level = CGFloat(max(0, min(1, player.volume)))
            ZStack(alignment: .bottom) {
                // Background pillar.
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    .frame(width: trackW, height: trackH)
                // Filled portion — green by default, orange while
                // user is actively dragging so the touch reads.
                RoundedRectangle(cornerRadius: 3)
                    .fill(dragging ? Color.orange : Color.green.opacity(0.75))
                    .frame(width: trackW, height: trackH * level)
                // Tick line at unity (top of the slider). Helpful
                // reference; volume defaults sit below this.
                Rectangle()
                    .fill(Color.white.opacity(0.4))
                    .frame(width: trackW, height: 1)
                    .offset(y: -(trackH - 1))
                // Thumb.
                Rectangle()
                    .fill(Color.white)
                    .frame(width: trackW, height: 3)
                    .offset(y: -(trackH * level - 1))
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        // Anchor drag y to the track region: y at
                        // bottom of track = 0, top = 1.
                        let yFromTop = drag.location.y - trackInsetY
                        let frac = 1 - (yFromTop / trackH)
                        let clamped = Float(max(0, min(1, frac)))
                        if abs(clamped - player.volume) > 0.001 {
                            player.volume = clamped
                        }
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .background(Color.black.opacity(0.4))
    }
}

private struct DimmedTrack: View {
    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.4))
            .overlay(
                Image(systemName: "speaker.slash")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.25))
            )
    }
}
