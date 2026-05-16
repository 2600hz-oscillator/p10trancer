import SwiftUI

struct BottomControlBar: View {
    let pads: PadSystem
    @ObservedObject var mixer: MixerState
    @ObservedObject var keyerSystem: KeyerSystem
    @ObservedObject var feedbackSystem: FeedbackSystem
    @ObservedObject var ntsc: NTSCState
    @ObservedObject var thermal: ThermalMonitor
    @ObservedObject var recorder: MixerRecorder
    @ObservedObject var automation: AutomationEngine
    @ObservedObject var liveRecordings: LiveRecordingsStore
    @ObservedObject var sessions: SessionStore
    var onEndSession: () -> Void

    @State private var showInspector = false
    @State private var showMixer = false
    @State private var showAutomation = false
    @State private var showKeyerControls = false
    @State private var showFeedbackControls = false
    @State private var showSession = false
    @State private var endSessionAlertShown = false
    @State private var showSaveBeforeEndAlert = false
    @State private var endSessionSaveDraft: String = ""
    /// Save Session alert state. `saveDraft` survives across opens
    /// so re-saving an existing session is one tap.
    @State private var saveAlertShown = false
    @State private var saveDraft: String = ""
    /// Load Session picker state. Uses .confirmationDialog so a
    /// scrollable list of saved names fits cleanly (alerts can't).
    @State private var loadDialogShown = false

    var body: some View {
        VStack(spacing: 0) {
            primaryRow
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            secondaryRow
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            LiveRecordingsRowView(store: liveRecordings)
        }
        .background(.black)
        .sheet(isPresented: $showInspector) {
            InspectorSheet(pads: pads, mixer: mixer, ntsc: ntsc, thermal: thermal)
        }
        .sheet(isPresented: $showMixer) {
            MixerPanelView(pads: pads, mixer: mixer)
        }
        .sheet(isPresented: $showAutomation) {
            AutomationPanelView(engine: automation, transport: AppState.shared.transport)
        }
        .sheet(isPresented: $showKeyerControls) {
            KeyerControlsView(system: keyerSystem, mixer: mixer)
        }
        .sheet(isPresented: $showFeedbackControls) {
            FeedbackControlsView(system: feedbackSystem, mixer: mixer)
        }
        .sheet(isPresented: $showSession) {
            SessionPanelView(store: sessions, performances: AppState.shared.performances)
        }
        .alert("End session?", isPresented: $endSessionAlertShown) {
            Button("Cancel", role: .cancel) {}
            if sessions.hasUnsavedChanges {
                Button("Save & End") {
                    endSessionSaveDraft = ""
                    showSaveBeforeEndAlert = true
                }
                Button("End Without Saving", role: .destructive) { onEndSession() }
            } else {
                Button("End") { onEndSession() }
            }
        } message: {
            Text(sessions.hasUnsavedChanges
                 ? "You have unsaved changes. Save before ending?"
                 : "Returns to the splash screen and stops cameras / MIDI / render.")
        }
        .alert("Save session before ending", isPresented: $showSaveBeforeEndAlert) {
            TextField("Session name", text: $endSessionSaveDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save & End") {
                let trimmed = endSessionSaveDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    _ = AppState.shared.saveCurrentSession(as: trimmed)
                }
                onEndSession()
            }
        }
        .alert("Save Session", isPresented: $saveAlertShown) {
            TextField("Session name", text: $saveDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = saveDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    _ = AppState.shared.saveCurrentSession(as: trimmed)
                }
            }
        } message: {
            Text("Saves pads, sources, FX params, channel routing, NTSC settings — everything except play state and live LFO phase.")
        }
        .confirmationDialog("Load Session",
                            isPresented: $loadDialogShown,
                            titleVisibility: .visible) {
            ForEach(sessions.savedNames, id: \.self) { name in
                Button(name) {
                    AppState.shared.loadSession(named: name)
                    saveDraft = name
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var primaryRow: some View {
        HStack(alignment: .center, spacing: 12) {
            channelBlock
            verticalDivider
            transitionBlock
            verticalDivider
            faderBlock(label: "POSITION", value: $mixer.position, in: 0...1)
            verticalDivider
            faderBlock(label: "MASTER VOL", value: Binding(
                get: { mixer.masterVolume },
                set: { v in mixer.masterVolume = v; AudioEngine.shared.masterVolume = v }
            ), in: 0...1)
            verticalDivider
            MasterTransportButton(transport: AppState.shared.transport)
            recordButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: 90)
    }

    private var recordButton: some View {
        Button(action: { recorder.toggle() }) {
            VStack(spacing: 2) {
                Circle()
                    .fill(recorder.isRecording ? Color.red : Color.red.opacity(0.4))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                Text(recorder.isRecording ? "STOP" : "REC")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .frame(width: 70, height: 60)
            .background(recorder.isRecording ? Color.red.opacity(0.18) : Color.white.opacity(0.08))
            .overlay(Rectangle().strokeBorder(recorder.isRecording ? Color.red : Color.white.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var secondaryRow: some View {
        HStack(spacing: 12) {
            hdmiBlock
            verticalDivider
            ntscBlock
            verticalDivider
            mixerButton
            automationButton
            inspectButton
            sessionButton
            saveSessionButton
            loadSessionButton
            verticalDivider
            endSessionButton
            Spacer(minLength: 8)
            automationStatus
            recAutoButton
            thermalIndicator
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: 70)
    }

    private var sessionButton: some View {
        Button(action: { showSession = true }) {
            Text("SESSION…")
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .overlay(Rectangle().strokeBorder(Color.purple, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var endSessionButton: some View {
        Button(action: { endSessionAlertShown = true }) {
            Text("END SESSION")
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .overlay(Rectangle().strokeBorder(Color.red, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// Direct "save current state" button. Opens an alert with a
    /// text field, pre-filled with the last name the user saved
    /// or loaded so re-saving an existing session is one tap.
    private var saveSessionButton: some View {
        Button(action: {
            if saveDraft.isEmpty,
               let prefilled = sessions.savedNames.last,
               prefilled != SessionStore.factoryName {
                saveDraft = prefilled
            }
            saveAlertShown = true
        }) {
            Text("SAVE")
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .overlay(Rectangle().strokeBorder(Color.green, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// Direct "load saved state" button. Opens a confirmation dialog
    /// listing every saved session by name. Tapping a name applies
    /// it via SessionCapture.
    private var loadSessionButton: some View {
        Button(action: { loadDialogShown = true }) {
            Text("LOAD")
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .overlay(Rectangle().strokeBorder(Color.cyan, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(sessions.savedNames.isEmpty)
        .opacity(sessions.savedNames.isEmpty ? 0.4 : 1)
    }

    private var channelBlock: some View {
        HStack(spacing: 8) {
            bigChannelButton(channel: .ch1, label: "CH 1", tint: .cyan, source: mixer.ch1Source)
            bigChannelButton(channel: .ch2, label: "CH 2", tint: .orange, source: mixer.ch2Source)
        }
        .frame(width: 220)
    }

    private func bigChannelButton(channel: ActiveChannel, label: String, tint: Color, source: ChannelSource) -> some View {
        let isActive = mixer.activeChannel == channel
        let sub: String
        switch source {
        case .pad(let i): sub = "PAD \(i + 1)"
        case .keyer: sub = "KEYER"
        case .feedback: sub = "FB"
        case .xyz: sub = "XYZ"
        }
        return Button(action: { mixer.activeChannel = channel }) {
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                Text(sub)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .opacity(0.9)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isActive ? tint : Color.white.opacity(0.10))
            .foregroundStyle(isActive ? Color.black : Color.white)
            .overlay(
                Rectangle().strokeBorder(isActive ? tint : Color.white.opacity(0.3), lineWidth: isActive ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var transitionBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TRANSITION")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .tracking(1.5)
            Picker("", selection: $mixer.transition) {
                ForEach(TransitionKind.allCases) { k in Text(k.displayName).tag(k) }
            }
            .pickerStyle(.segmented)
            .colorScheme(.dark)
        }
        .frame(width: 280)
    }

    private func faderBlock(label: String, value: Binding<Float>, in range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .tracking(1.5)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Slider(value: value, in: range).tint(.white)
        }
        .frame(maxWidth: .infinity)
    }

    private var hdmiBlock: some View {
        HStack(spacing: 6) {
            Text("HDMI")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .tracking(1.5)
            outputModeButton(.hd720p, label: "HD")
            outputModeButton(.ntsc4_3, label: "NTSC 4:3")
        }
    }

    private func outputModeButton(_ mode: OutputMode, label: String) -> some View {
        let isActive = mixer.outputMode == mode
        return Button(action: { mixer.outputMode = mode }) {
            Text(label)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(isActive ? .black : .white)
                .frame(minWidth: 64)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isActive ? Color.green : Color.white.opacity(0.08))
                .overlay(Rectangle().strokeBorder(isActive ? Color.green : Color.white.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var keyerControlsButton: some View {
        Button(action: { showKeyerControls = true }) {
            Text("KEYER CONTROLS…")
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .overlay(Rectangle().strokeBorder(Color.green, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var feedbackControlsButton: some View {
        Button(action: { showFeedbackControls = true }) {
            Text("FB CONTROL…")
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .overlay(Rectangle().strokeBorder(Color.purple, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var ntscBlock: some View {
        HStack(spacing: 4) {
            Circle().fill(mixer.outputMode == .ntsc4_3 ? Color.green : Color.white.opacity(0.3)).frame(width: 8, height: 8)
            Text("NTSC")
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(mixer.outputMode == .ntsc4_3 ? .white : .white.opacity(0.5))
        }
    }

    private var inspectButton: some View {
        Button(action: { showInspector = true }) {
            Text("INSPECT…")
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .overlay(Rectangle().strokeBorder(Color.yellow, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var mixerButton: some View {
        Button(action: { showMixer = true }) {
            Text("MIXER…")
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .overlay(Rectangle().strokeBorder(Color.green, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var automationButton: some View {
        Button(action: { showAutomation = true }) {
            Text("AUTO…")
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .overlay(Rectangle().strokeBorder(Color.cyan, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// Bottom-right primary control for recording automation. When
    /// recording is in flight (including the arm-waiting-for-clock
    /// state) shows STOP REC AUTO; otherwise shows START REC AUTO.
    /// Tapping toggles `engine.startRecordingNow()` / `engine.disarm()`.
    private var recAutoButton: some View {
        let isRecOrArmed = automation.state == .recording || automation.state == .armedRecord
        let title = isRecOrArmed ? "STOP REC AUTO" : "START REC AUTO"
        let tint: Color = isRecOrArmed ? .red : .red.opacity(0.7)
        return Button(action: {
            if isRecOrArmed {
                automation.disarm()
            } else {
                automation.startRecordingNow()
            }
        }) {
            Text(title)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(isRecOrArmed ? .black : .white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(isRecOrArmed ? Color.red : Color.red.opacity(0.18))
                .overlay(Rectangle().strokeBorder(tint, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("rec-auto-button")
    }

    private var automationStatus: some View {
        let (label, color): (String, Color) = {
            switch automation.state {
            case .idle: return ("AUTO IDLE", .white.opacity(0.3))
            case .armedRecord: return ("ARMED REC", .red)
            case .recording: return ("REC ●", .red)
            case .armedPlayback: return ("ARMED PLAY", .yellow)
            case .playing: return ("PLAY ▶", .green)
            }
        }()
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    private var thermalIndicator: some View {
        let color: Color
        switch thermal.indicatorColor {
        case .nominal: color = .green
        case .warm: color = .yellow
        case .hot: color = .orange
        case .critical: color = .red
        }
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(thermal.label)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var verticalDivider: some View {
        Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1)
    }
}

/// Master transport (play / stop). Sits next to the REC button so
/// the two top-level "start the world running" controls live
/// together. The full transport panel (BPM, tap, clock source) is
/// still available via the AUTO… button.
private struct MasterTransportButton: View {
    @ObservedObject var transport: Transport

    var body: some View {
        Button(action: { transport.toggleRunning() }) {
            VStack(spacing: 2) {
                Image(systemName: transport.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(transport.isRunning ? .red : .green)
                Text(transport.isRunning ? "STOP" : "PLAY")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .frame(width: 70, height: 60)
            .background(transport.isRunning ? Color.green.opacity(0.18) : Color.white.opacity(0.08))
            .overlay(Rectangle().strokeBorder(transport.isRunning ? Color.green : Color.white.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct InspectorSheet: View {
    let pads: PadSystem
    @ObservedObject var mixer: MixerState
    @ObservedObject var ntsc: NTSCState
    @ObservedObject var thermal: ThermalMonitor
    @ObservedObject var appState: AppState = .shared
    @Environment(\.dismiss) private var dismiss
    @State private var showVideoImporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("INSPECTOR")
                        .font(.system(size: 14, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("CLOSE") { dismiss() }
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white)
                }
                if mixer.outputMode == .ntsc4_3 { ntscSection }
                performanceSection
                fxSection
                Spacer()
            }
            .padding(20)
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $showVideoImporter,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    AppState.shared.loadUserVideo(from: url, at: mixer.inspectedPadIndex)
                }
            case .failure(let error):
                P10Logger.log("[InspectorSheet] file import failed: \(error)")
            }
        }
    }

    /// Per-pad preview thumbnail quality — cuts visualizer fps +
    /// video preview copy rate at lower settings. Audio playback
    /// and sequencer timing are unaffected; only the on-screen
    /// pad previews scale back.
    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("THUMBNAIL QUALITY")
            HStack(spacing: 0) {
                ForEach(ThumbnailQuality.allCases) { q in
                    let selected = appState.thumbnailQuality == q
                    Button(action: { appState.thumbnailQuality = q }) {
                        Text(q.label)
                            .font(.system(size: 11, weight: .heavy, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .foregroundStyle(selected ? .black : .white)
                            .background(selected ? Color.white : Color.white.opacity(0.06))
                            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Affects only the per-pad preview render rate. Doesn't change audio or sequencer timing.")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var ntscSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("NTSC FX")
            slider("Chroma boost", $ntsc.chromaBoost, in: 0...3)
            slider("Luma peak", $ntsc.lumaPeaking, in: 0...3)
            slider("HSync wobble", $ntsc.hsyncWobble, in: 0...1)
            slider("Burst phase", $ntsc.burstPhaseShift, in: -0.5...0.5)
            slider("Subcarrier drift", $ntsc.subcarrierDrift, in: 0...0.5)
            slider("Y/C delay", $ntsc.ycDelay, in: -8...8)
            slider("Dropout", $ntsc.dropoutRate, in: 0...1)
            slider("Luma noise", $ntsc.lumaNoise, in: 0...0.3)
            slider("Chroma noise", $ntsc.chromaNoise, in: 0...0.3)
        }
    }

    private var fxSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("PER-PAD FX")
            HStack {
                Text("Pad").foregroundStyle(.white).font(.system(size: 12, design: .monospaced))
                Picker("", selection: $mixer.inspectedPadIndex) {
                    ForEach(0..<PadSystem.padCount, id: \.self) { i in Text("\(i + 1)").tag(i) }
                }.pickerStyle(.segmented).colorScheme(.dark)
            }
            sourcePicker
            FXInspectorView(pads: pads, mixer: mixer)
        }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SOURCE")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 8) {
                Button("Load Video…") {
                    showVideoImporter = true
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                Button("Master Feedback") {
                    AppState.shared.setMasterFeedbackSource(at: mixer.inspectedPadIndex)
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                Button("Instrument") {
                    AppState.shared.setInstrumentSource(at: mixer.inspectedPadIndex)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                Button("Reset to Bundled") {
                    AppState.shared.reloadVideoSource(at: mixer.inspectedPadIndex)
                }
                .buttonStyle(.bordered)
                .tint(.gray)
            }
            .font(.system(size: 11, design: .monospaced))
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy, design: .monospaced))
            .tracking(2.0)
            .foregroundStyle(.white)
    }

    private func padPicker(_ label: String, _ binding: Binding<Int>) -> some View {
        HStack {
            Text(label).font(.system(size: 11, weight: .heavy, design: .monospaced)).foregroundStyle(.white).frame(width: 30)
            Picker("", selection: binding) {
                ForEach(0..<PadSystem.padCount, id: \.self) { i in Text("\(i + 1)").tag(i) }
            }.pickerStyle(.segmented).colorScheme(.dark)
        }
    }

    private func slider(_ label: String, _ binding: Binding<Float>, in range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(String(format: "%.2f", binding.wrappedValue))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
            }
            Slider(value: binding, in: range).tint(.white)
        }
    }
}
