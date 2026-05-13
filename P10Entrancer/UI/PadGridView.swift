import SwiftUI

struct PadGridView: View {
    @ObservedObject var pads: PadSystem
    @ObservedObject var mixer: MixerState
    @ObservedObject var liveRecordings: LiveRecordingsStore
    @ObservedObject var cameras: CameraRegistry
    @ObservedObject var transcodeManager: TranscodeManager = AppState.shared.transcodeManager
    @State private var importerVisible: Bool = false
    @State private var pendingPadIndex: Int = -1
    /// When non-nil, the pad index whose instrument settings sheet
    /// should be presented. Set by the upper-left gear on instrument
    /// pads. Kept here rather than per-cell so the sheet can survive
    /// pad-source changes without disappearing mid-edit.
    @State private var instrumentSheetPadIndex: Int? = nil
    @State private var acidkickSheetPadIndex: Int? = nil

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
        // Presented when the upper-left gear on an instrument pad is
        // tapped. Sheet binding identifies the active pad index so
        // sheet state survives a re-render.
        .sheet(item: Binding(
            get: { instrumentSheetPadIndex.map { InstrumentSheetTarget(id: $0) } },
            set: { instrumentSheetPadIndex = $0?.id }
        )) { target in
            if let inst = pads.pads[target.id].source as? InstrumentSource {
                InstrumentSettingsSheet(instrument: inst)
            }
        }
        .sheet(item: Binding(
            get: { acidkickSheetPadIndex.map { InstrumentSheetTarget(id: $0) } },
            set: { acidkickSheetPadIndex = $0?.id }
        )) { target in
            if let drums = pads.pads[target.id].source as? ACIDKICKSource {
                ACIDKICKSettingsSheet(source: drums)
            }
        }
    }

    private func cellOverlay(index: Int) -> some View {
        let isCh1 = mixer.ch1PadIndex == index
        let isCh2 = mixer.ch2PadIndex == index
        let isInspected = mixer.inspectedPadIndex == index
        let assignmentMode = liveRecordings.selectedID != nil
        // The Metal grid shader reserves the left `sliderStripFraction`
        // of each cell for the per-pad volume slider. The remaining
        // pad-video area lives to its right; all existing overlays
        // (CH chips, gear icons, footer controls, VideoPadOverlays)
        // stay anchored inside that right region by inset-padding the
        // overlay ZStack.
        let stripFrac = CGFloat(PadGridLayout.sliderStripFraction)
        return Color.clear
            .contentShape(Rectangle())
            .overlay(
                GeometryReader { geo in
                    let stripW = geo.size.width * stripFrac
                    HStack(spacing: 0) {
                        PadVolumeSlider(pad: pads.pads[index])
                            .frame(width: stripW)
                        padCellOverlays(index: index,
                                         isCh1: isCh1,
                                         isCh2: isCh2,
                                         isInspected: isInspected,
                                         assignmentMode: assignmentMode)
                    }
                }
            )
            .onTapGesture {
                if liveRecordings.loadIntoPad(index) { return }
                mixer.routeActivePad(index)
            }
            .contextMenu { padContextMenu(index: index) }
    }

    /// Long-press context menu for a pad cell. Surfaces the source
    /// picker (Load Video, Camera, Chain, Master Feedback, both
    /// instrument kinds, Reset) + Inspect FX. Lives on the outer
    /// cellOverlay (not the inner ZStack) so long-press anywhere in
    /// the cell — including the volume slider strip — opens it.
    @ViewBuilder
    private func padContextMenu(index: Int) -> some View {
        Button {
            // Block the importer if a transcode is in flight —
            // FFmpegKit serialises sessions internally and queueing
            // another would just stall both. Users see a no-op tap
            // here while the pad already shows the THINKING overlay.
            guard !transcodeManager.isAnyActive else {
                P10Logger.log("[PadGridView] Load Video blocked: transcode in flight")
                return
            }
            P10Logger.log("[PadGridView] Load Video tapped for pad \(index + 1)")
            pendingPadIndex = index
            importerVisible = true
        } label: {
            Label(transcodeManager.isAnyActive ? "Load Video… (transcoding…)" : "Load Video…",
                  systemImage: "folder")
        }
        .disabled(transcodeManager.isAnyActive)
        Menu {
            if cameras.devices.isEmpty {
                Text("No cameras detected")
            } else {
                ForEach(cameras.devices) { device in
                    Button {
                        AppState.shared.setCameraSource(deviceID: device.id, at: index)
                    } label: {
                        Label(device.label, systemImage: cameraIcon(for: device.kind))
                    }
                }
            }
        } label: {
            Label("Camera", systemImage: "camera")
        }
        Menu {
            ForEach(0..<PadSystem.padCount, id: \.self) { other in
                if other != index {
                    Button {
                        AppState.shared.setPadChainSource(
                            at: index, sourcePadIndex: other
                        )
                    } label: {
                        Label("Pad \(other + 1)", systemImage: "rectangle.connected.to.line.below")
                    }
                }
            }
        } label: {
            Label("Chain from another pad", systemImage: "link")
        }
        Button {
            AppState.shared.setMasterFeedbackSource(at: index)
        } label: {
            Label("Master Feedback", systemImage: "arrow.triangle.2.circlepath")
        }
        Button {
            AppState.shared.setInstrumentSource(at: index)
        } label: {
            Label("Instrument: Wavetable", systemImage: "pianokeys")
        }
        Button {
            AppState.shared.setACIDKICKSource(at: index)
        } label: {
            Label("Instrument: ACIDKICK", systemImage: "metronome")
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

    /// All the per-pad UI that lives over the pad's VIDEO area (to
    /// the right of the volume slider strip). Extracted so the
    /// outer cellOverlay can sit it next to the volume slider in
    /// an HStack.
    @ViewBuilder
    private func padCellOverlays(index: Int,
                                  isCh1: Bool, isCh2: Bool,
                                  isInspected: Bool,
                                  assignmentMode: Bool) -> some View {
        ZStack(alignment: .topLeading) {
                    if assignmentMode {
                        Rectangle()
                            .fill(Color.green.opacity(0.10))
                        Rectangle()
                            .strokeBorder(Color.green.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                    }
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
                    if let video = pads.pads[index].source as? VideoFileSource {
                        VideoPadOverlays(video: video)
                    }
                    // Upper-left gear: instrument settings — wavetable
                    // (WAVECEL) or drum sequencer (ACIDKICK). Only
                    // appears for instrument-kind sources.
                    if pads.pads[index].source is InstrumentSource
                       || pads.pads[index].source is ACIDKICKSource {
                        VStack {
                            HStack {
                                Button {
                                    if pads.pads[index].source is ACIDKICKSource {
                                        acidkickSheetPadIndex = index
                                    } else {
                                        instrumentSheetPadIndex = index
                                    }
                                } label: {
                                    Image(systemName: "gearshape.fill")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(6)
                                        .background(.black.opacity(0.6))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 6)
                                .padding(.leading, 6)
                                Spacer()
                            }
                            Spacer()
                        }
                    }
            PadFooterControls(pad: pads.pads[index], padIndex: index)
            // Transcode-in-flight overlay. Lives at the TOP of the
            // ZStack so it eats taps to the underlying pad while
            // ffmpeg is running — the pad's source isn't ready yet.
            if let job = transcodeManager.job(for: index) {
                TranscodeOverlayView(job: job)
            }
        }
    }

    private func cameraIcon(for kind: CameraDevice.Kind) -> String {
        switch kind {
        case .builtinFront: return "camera.rotate"
        case .builtinBack: return "camera"
        case .external: return "camera.viewfinder"
        }
    }

    /// Identifiable wrapper around a pad index so SwiftUI's
    /// `.sheet(item:)` can drive the instrument sheet from an
    /// optional Int.
    private struct InstrumentSheetTarget: Identifiable, Hashable {
        let id: Int
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
