import SwiftUI

struct PadGridView: View {
    let pads: PadSystem
    @ObservedObject var mixer: MixerState
    @State private var importerVisible: Bool = false
    @State private var pendingPadIndex: Int = -1

    var body: some View {
        ZStack {
            PadGridMetalView(pads: pads)
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<3, id: \.self) { col in
                            let i = row * 3 + col
                            cellOverlay(index: i)
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $importerVisible,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            let index = pendingPadIndex
            P10Logger.log("[PadGridView] fileImporter completion fired, index=\(index)")
            switch result {
            case .success(let urls):
                P10Logger.log("[PadGridView] picker success, \(urls.count) urls")
                if let url = urls.first, index >= 0 {
                    P10Logger.log("[PadGridView] picked: \(url.path)")
                    AppState.shared.loadUserVideo(from: url, at: index)
                }
            case .failure(let error):
                P10Logger.log("[PadGridView] file import failed: \(error)")
            }
            pendingPadIndex = -1
        }
    }

    private func cellOverlay(index: Int) -> some View {
        let isCh1 = mixer.ch1PadIndex == index
        let isCh2 = mixer.ch2PadIndex == index
        let isInspected = mixer.inspectedPadIndex == index
        return Color.clear
            .contentShape(Rectangle())
            .overlay(
                ZStack(alignment: .topLeading) {
                    if isInspected {
                        Rectangle()
                            .strokeBorder(Color.yellow.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                    }
                    if isCh1 {
                        Rectangle()
                            .strokeBorder(Color.cyan, lineWidth: 4)
                        chip("CH1", color: .cyan)
                    }
                    if isCh2 {
                        Rectangle()
                            .strokeBorder(Color.orange, lineWidth: 4)
                        chip("CH2", color: .orange)
                    }
                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.5))
                        .padding([.bottom, .trailing], 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            )
            .onTapGesture {
                mixer.routeActivePad(index)
            }
            .contextMenu {
                Button {
                    P10Logger.log("[PadGridView] Load Video tapped for pad \(index + 1)")
                    pendingPadIndex = index
                    importerVisible = true
                } label: {
                    Label("Load Video…", systemImage: "folder")
                }
                Button {
                    AppState.shared.setMasterFeedbackSource(at: index)
                } label: {
                    Label("Master Feedback", systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    AppState.shared.reloadVideoSource(at: index)
                } label: {
                    Label("Reset to Bundled", systemImage: "arrow.counterclockwise")
                }
                Divider()
                Button {
                    mixer.inspectedPadIndex = index
                } label: {
                    Label("Inspect FX", systemImage: "slider.horizontal.3")
                }
            }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color)
            .foregroundStyle(.black)
            .padding(6)
    }
}
