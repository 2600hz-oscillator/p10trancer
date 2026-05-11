import SwiftUI
import AVFoundation

struct ContentView: View {
    private let appState = AppState.shared
    @State private var entered: Bool = false

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
            let macroBarH: CGFloat = 64
            let workHForGrid = workH - macroBarH
            let cellByWidth = w / 3
            let cellByHeight = (workHForGrid * 0.78) / 4 * (4.0/3.0)
            let cellW = min(cellByWidth, cellByHeight) * 0.80
            let cellH = cellW * 3.0 / 4.0
            let gridW = cellW * 3
            let sourceH = cellH * 3
            let outputRowH = cellH
            let gridTotalH = sourceH + outputRowH
            let outputH = max(80, workH - gridTotalH - macroBarH - 4) // 4 px for the dividers

            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    OutputPreviewView(mixerOffscreen: appState.masterMixerOffscreen)
                    statusOverlay
                }
                .frame(height: outputH)
                .frame(maxWidth: .infinity)
                .background(.black)

                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)

                MacroLFOBar(engine: appState.lfoEngine, transport: appState.transport)
                    .frame(height: macroBarH)
                    .frame(maxWidth: .infinity)
                    .background(.black)

                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)

                PadGridView(pads: appState.pads, mixer: appState.mixer, liveRecordings: appState.liveRecordings, cameras: appState.cameras)
                    .frame(width: gridW, height: sourceH)
                    .frame(maxWidth: .infinity)
                    .background(.black)

                Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)

                OutputPadsRowView(
                    keyerSystem: appState.keyerSystem,
                    feedbackSystem: appState.feedbackSystem,
                    mixer: appState.mixer,
                    renderers: OutputPadRenderers(
                        keyerRenderers: appState.keyerRenderers,
                        feedbackRenderers: appState.feedbackRenderers
                    )
                )
                .frame(width: gridW, height: outputRowH)
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
}

#Preview {
    ContentView()
}
