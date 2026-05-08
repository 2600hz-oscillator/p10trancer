import SwiftUI
import AVFoundation

struct ContentView: View {
    private let appState = AppState.shared

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let isPortrait = h > w
            let barHeight: CGFloat = isPortrait ? 220 : 160
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

                PadGridView(pads: appState.pads, mixer: appState.mixer)
                    .frame(height: gridH)
                    .frame(maxWidth: .infinity)
                    .background(.black)

                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)

                BottomControlBar(
                    pads: appState.pads,
                    mixer: appState.mixer,
                    keyer: appState.keyerState,
                    ntsc: appState.ntscState,
                    thermal: appState.thermalMonitor,
                    recorder: appState.recorder,
                    automation: appState.automation
                )
                .frame(height: barHeight)
            }
        }
        .ignoresSafeArea()
        .background(.black)
        .onAppear { appState.startIfNeeded() }
    }

    private var statusOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OUTPUT")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.6))
            Text("Phase 10b — bottom controls")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(14)
    }
}

#Preview {
    ContentView()
}
