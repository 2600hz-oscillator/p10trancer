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
            // In portrait, give ~50/50 to output and grid (both can be 16:9 friendly).
            // In landscape we'd ideally have side-by-side, but a clean stack is fine for now.
            let outputH = isPortrait ? workH * 0.50 : workH * 0.55
            let gridH = workH - outputH
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    OutputPreviewView(mixerOffscreen: appState.masterMixerOffscreen)
                    statusOverlay
                }
                .frame(height: outputH)
                .frame(maxWidth: .infinity)
                .background(.black)

                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)

                PadGridView(pads: appState.pads, mixer: appState.mixer, liveRecordings: appState.liveRecordings, cameras: appState.cameras)
                    .frame(height: gridH)
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
