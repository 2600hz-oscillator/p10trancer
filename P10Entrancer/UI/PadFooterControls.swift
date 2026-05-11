import SwiftUI

/// The play/stop + mute icon pair in each pad's lower-right corner.
/// Re-renders on changes by observing the pad's source (`isPlaying`)
/// and audio player (`isMuted`). Tap targets stop event propagation
/// so they don't also trigger the pad's tap-to-route gesture.
struct PadFooterControls: View {
    let pad: PadSlot
    let padIndex: Int

    @State private var lfoSheet = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Top-right gear (waveform) — opens the per-pad LFO sheet.
            // Instrument-pad settings (steps / keyboard / ADSR) live
            // in their own gear icon in the upper-LEFT of the pad,
            // wired from PadGridView.
            VStack {
                HStack {
                    Spacer()
                    Button { lfoSheet = true } label: {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(.black.opacity(0.55))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                    .padding(.trailing, 6)
                }
                Spacer()
            }
            .sheet(isPresented: $lfoSheet) {
                if pad.source is InstrumentSource || pad.source is EIGHTOHSource {
                    // Instrument-kind pads ship with three LFOs (the
                    // sheet handles tabs across them).
                    MultiLFOSheet(padIndex: padIndex,
                                  lfoCount: 3,
                                  engine: AppState.shared.lfoEngine,
                                  transport: AppState.shared.transport)
                } else {
                    let slot = LFOTargets.slotID(forPadIndex: padIndex)
                    LFOSettingsSheet(
                        title: "PAD \(padIndex + 1)",
                        lfo: AppState.shared.lfoEngine.lfo(for: slot),
                        availableTargets: AppState.shared.lfoEngine.availableTargets(forSlot: slot),
                        transport: AppState.shared.transport
                    )
                }
            }
            // VU meter on camera pads — confirms the mic is picking up
            // signal so the user knows whether their voice is being
            // captured into recordings.
            if pad.source is CameraSource || pad.source is BuiltInCameraSource {
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

    /// File pads control AVPlayer playback; instrument pads control
    /// whether the step sequencer advances on Transport ticks.
    /// Cameras / keyers / feedback / image sources show the icon
    /// greyed out and tappable-but-no-op.
    @ViewBuilder
    private var playStopButton: some View {
        if let video = pad.source as? VideoFileSource {
            VideoPlayStopIcon(video: video, padIndex: padIndex)
        } else if let inst = pad.source as? InstrumentSource {
            InstrumentPlayStopIcon(instrument: inst, padIndex: padIndex)
        } else if let drums = pad.source as? EIGHTOHSource {
            EIGHTOHPlayStopIcon(source: drums, padIndex: padIndex)
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

/// Play/stop the EIGHTOH drum sequencer loop.
private struct EIGHTOHPlayStopIcon: View {
    @ObservedObject var source: EIGHTOHSource
    let padIndex: Int

    var body: some View {
        let icon = source.isPlaying ? "pause.fill" : "play.fill"
        Button {
            source.isPlaying.toggle()
            P10Logger.log("[PadFooter] pad \(padIndex + 1) EIGHTOH play=\(source.isPlaying)")
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

/// Play/stop the instrument's 16-step sequencer loop. Pause cleanly
/// gates the ADSR off and parks the playhead at step 0.
private struct InstrumentPlayStopIcon: View {
    @ObservedObject var instrument: InstrumentSource
    let padIndex: Int

    var body: some View {
        let icon = instrument.isPlaying ? "pause.fill" : "play.fill"
        Button {
            instrument.isPlaying.toggle()
            P10Logger.log("[PadFooter] pad \(padIndex + 1) instrument play=\(instrument.isPlaying)")
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
