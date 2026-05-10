import SwiftUI

/// The play/stop + mute icon pair in each pad's lower-right corner.
/// Re-renders on changes by observing the pad's source (`isPlaying`)
/// and audio player (`isMuted`). Tap targets stop event propagation
/// so they don't also trigger the pad's tap-to-route gesture.
struct PadFooterControls: View {
    let pad: PadSlot
    let padIndex: Int

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // VU meter on camera pads — confirms the mic is picking up
            // signal so the user knows whether their voice is being
            // captured into recordings.
            if let cam = pad.source as? CameraSource {
                CameraAudioStrip(cam: cam)
            } else if pad.source is BuiltInCameraSource {
                VStack {
                    Spacer()
                    HStack(spacing: 4) {
                        Text("MIC")
                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.6))
                        MicVUMeter()
                            .frame(width: 80, height: 14)
                        Spacer()
                    }
                    .padding(.bottom, 24)
                    .padding(.leading, 6)
                }
            }
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

/// Camera-pad audio strip: shows MIC or HDMI label + VU meter + a
/// tap target on the label to toggle embedded audio (when the camera
/// has a paired UVC audio device).
private struct CameraAudioStrip: View {
    @ObservedObject var cam: CameraSource

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 4) {
                Button {
                    if cam.hasEmbeddedAudio { cam.useEmbeddedAudio.toggle() }
                } label: {
                    Text(cam.useEmbeddedAudio ? "HDMI" : "MIC")
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(cam.useEmbeddedAudio
                                    ? Color.green.opacity(0.8)
                                    : Color.black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .disabled(!cam.hasEmbeddedAudio)
                .opacity(cam.hasEmbeddedAudio ? 1.0 : 0.5)
                if cam.useEmbeddedAudio {
                    CameraEmbeddedVUMeter(capture: cam.audioCapture)
                        .frame(width: 80, height: 14)
                } else {
                    MicVUMeter()
                        .frame(width: 80, height: 14)
                }
                Spacer()
            }
            .padding(.bottom, 24)
            .padding(.leading, 6)
        }
    }
}

/// VU meter driven by a specific CameraAudioCapture's `inputLevel`.
/// Same visual as MicVUMeter; different source.
private struct CameraEmbeddedVUMeter: View {
    @ObservedObject var capture: CameraAudioCapture

    var body: some View {
        GeometryReader { geo in
            let level = min(1.0, max(0, capture.inputLevel * 6.0))
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.black.opacity(0.7))
                    .overlay(Rectangle().strokeBorder(.white.opacity(0.4), lineWidth: 1))
                LinearGradient(
                    colors: [.green, .yellow, .red],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: geo.size.width * CGFloat(level))
                .padding(1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }
}

/// Tiny live VU meter for the iPad mic, sourced from
/// MicCapture.shared.inputLevel. Fills left-to-right with a soft
/// gradient; pure visual indicator, no interaction.
private struct MicVUMeter: View {
    @ObservedObject var mic = MicCapture.shared

    var body: some View {
        GeometryReader { geo in
            // Mic RMS sits in a small range under normal speech (~0.05).
            // Scale by 6× and clamp so quiet voices still show movement.
            let level = min(1.0, max(0, mic.inputLevel * 6.0))
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.black.opacity(0.7))
                    .overlay(
                        Rectangle()
                            .strokeBorder(.white.opacity(0.4), lineWidth: 1)
                    )
                LinearGradient(
                    colors: [.green, .yellow, .red],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geo.size.width * CGFloat(level))
                .padding(1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
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
