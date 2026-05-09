import SwiftUI

/// The play/stop + mute icon pair in each pad's lower-right corner.
/// Re-renders on changes by observing the pad's source (`isPlaying`)
/// and audio player (`isMuted`). Tap targets stop event propagation
/// so they don't also trigger the pad's tap-to-route gesture.
struct PadFooterControls: View {
    let pad: PadSlot
    let padIndex: Int

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                playStopButton
                muteButton
            }
            .padding(.bottom, 24) // clear of the pad-number chip
            .padding(.trailing, 6)
        }
    }

    /// Only file pads support play/stop. Cameras, keyers, feedback
    /// sources show the icon greyed out and tappable-but-no-op.
    @ViewBuilder
    private var playStopButton: some View {
        if let video = pad.source as? VideoFileSource {
            VideoPlayStopIcon(video: video, padIndex: padIndex)
        } else {
            Image(systemName: "play.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.25))
                .padding(6)
                .background(.black.opacity(0.4))
                .clipShape(Circle())
        }
    }

    /// Mute is available whenever the pad has any audio player —
    /// file or mic. Pads with no audio (keyer/feedback) get the
    /// disabled state.
    @ViewBuilder
    private var muteButton: some View {
        if let player = pad.audioPlayer {
            PadMuteIcon(player: player, padIndex: padIndex)
        } else {
            Image(systemName: "speaker.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.25))
                .padding(6)
                .background(.black.opacity(0.4))
                .clipShape(Circle())
        }
    }
}

private struct VideoPlayStopIcon: View {
    @ObservedObject var video: VideoFileSource
    let padIndex: Int

    var body: some View {
        let icon = video.isPlaying ? "pause.fill" : "play.fill"
        Button {
            video.isPlaying.toggle()
            P10Logger.log("[PadFooter] pad \(padIndex + 1) play=\(video.isPlaying)")
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .padding(6)
                .background(.black.opacity(0.55))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct PadMuteIcon: View {
    @ObservedObject var player: PadAudioPlayer
    let padIndex: Int

    var body: some View {
        let icon = player.isMuted ? "speaker.slash.fill" : "speaker.fill"
        Button {
            player.isMuted.toggle()
            P10Logger.log("[PadFooter] pad \(padIndex + 1) muted=\(player.isMuted)")
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(player.isMuted ? .red : .white)
                .padding(6)
                .background(.black.opacity(0.55))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
