import SwiftUI
import AVFoundation

struct ContentView: View {
    private let appState = AppState.shared
    @State private var entered: Bool = false
    @State private var showGlobalSettings: Bool = false

    var body: some View {
        if !entered {
            SplashView(onEnter: {
                entered = true
                appState.startIfNeeded()
            })
        } else {
            mainView
        }
    }

    private var mainView: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let isPortrait = h > w
            let barHeight: CGFloat = isPortrait ? 320 : 260
            let workH = max(h - barHeight, 100)

            // 4 rows × 3 cols, every cell 4:3. Find the largest cell
            // size that fits in (w, available-for-grid) and then trim
            // 20% so the master preview can take the rest. Same trim
            // applies in portrait and landscape — keeps aspect at 4:3
            // and the top preview from being squeezed.
            let cellByWidth = w / 3
            let cellByHeight = (workH * 0.78) / 4 * (4.0/3.0)
            let cellW = min(cellByWidth, cellByHeight) * 0.80
            let cellH = cellW * 3.0 / 4.0
            let gridW = cellW * 3
            let sourceH = cellH * 3
            let outputRowH = cellH
            let gridTotalH = sourceH + outputRowH
            let outputH = max(80, workH - gridTotalH - 2) // 2 px for the dividers
            // Width of each side strip = half of whatever's left of the
            // viewport after the grid centers itself horizontally. That's
            // the empty vertical band the user wanted to reclaim — fits
            // a macro card on top + a VU meter below.
            let sideStripW = max(0, (w - gridW) / 2)

            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    OutputPreviewView(mixerOffscreen: appState.masterMixerOffscreen)
                    statusOverlay
                    globalSettingsGear
                }
                .frame(height: outputH)
                .frame(maxWidth: .infinity)
                .background(.black)

                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)

                // 3-column work area: macro-1+CH1 VU | grid | macro-2+CH2 VU.
                // Reclaims the previously-empty letterbox space on
                // either side of the centered 4:3 grid.
                HStack(spacing: 0) {
                    if sideStripW > 40 {
                        VStack(spacing: 4) {
                            MacroSideStrip(
                                macroSlotID: LFOTargets.slotID(forMacroIndex: 0),
                                macroTitle: "MACRO 1",
                                channelTitle: "CH1",
                                channelAccent: .cyan,
                                engine: appState.lfoEngine,
                                transport: appState.transport
                            )
                            OutputFXSidePanel(
                                mode: .hd,
                                mixer: appState.mixer,
                                hdPost: appState.hdPostState,
                                ntsc: appState.ntscState
                            )
                            .frame(maxHeight: .infinity)
                        }
                        .frame(width: sideStripW)
                    } else {
                        Spacer().frame(width: sideStripW)
                    }
                    VStack(spacing: 0) {
                        PadGridView(pads: appState.pads, mixer: appState.mixer, liveRecordings: appState.liveRecordings, cameras: appState.cameras)
                            .frame(width: gridW, height: sourceH)
                        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
                        OutputPadsRowView(
                            keyerSystem: appState.keyerSystem,
                            feedbackSystem: appState.feedbackSystem,
                            xyzSystem: appState.xyzSystem,
                            fxPadSystem: appState.fxPadSystem,
                            mixer: appState.mixer,
                            renderers: OutputPadRenderers(
                                keyer: appState.keyerRenderer,
                                feedback: appState.feedbackRenderer,
                                xyz: appState.xyzRenderer
                            )
                        )
                        .frame(width: gridW, height: outputRowH)
                    }
                    if sideStripW > 40 {
                        VStack(spacing: 4) {
                            MacroSideStrip(
                                macroSlotID: LFOTargets.slotID(forMacroIndex: 1),
                                macroTitle: "MACRO 2",
                                channelTitle: "CH2",
                                channelAccent: .orange,
                                engine: appState.lfoEngine,
                                transport: appState.transport
                            )
                            OutputFXSidePanel(
                                mode: .ntsc,
                                mixer: appState.mixer,
                                hdPost: appState.hdPostState,
                                ntsc: appState.ntscState
                            )
                            .frame(maxHeight: .infinity)
                        }
                        .frame(width: sideStripW)
                    } else {
                        Spacer().frame(width: sideStripW)
                    }
                }
                .frame(height: gridTotalH + 1)
                .frame(maxWidth: .infinity)
                .background(.black)

                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)

                BottomControlBar(
                    pads: appState.pads,
                    mixer: appState.mixer,
                    keyerSystem: appState.keyerSystem,
                    feedbackSystem: appState.feedbackSystem,
                    ntsc: appState.ntscState,
                    thermal: appState.thermalMonitor,
                    recorder: appState.recorder,
                    automation: appState.automation,
                    liveRecordings: appState.liveRecordings,
                    sessions: appState.sessions,
                    onEndSession: { entered = false }
                )
                .frame(height: barHeight)
            }
        }
        .ignoresSafeArea()
        .background(.black)
    }

    private var statusOverlay: some View {
        Text("OUTPUT")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.5)
            .foregroundStyle(.white.opacity(0.6))
            .padding(14)
    }

    /// Big gear in the upper-right of the master preview. Opens the
    /// app-wide settings sheet (thumbnail quality, NTSC config, MIDI
    /// devices + traffic).
    private var globalSettingsGear: some View {
        VStack {
            HStack {
                Spacer()
                Button { showGlobalSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.55))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("global-settings-gear")
                .padding(14)
            }
            Spacer()
        }
        .sheet(isPresented: $showGlobalSettings) {
            GlobalSettingsSheet(
                appState: appState,
                ntsc: appState.ntscState,
                router: MIDIRouter.shared
            )
        }
    }
}

#Preview {
    ContentView()
}
