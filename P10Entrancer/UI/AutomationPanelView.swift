import SwiftUI

struct AutomationPanelView: View {
    @ObservedObject var engine: AutomationEngine
    @ObservedObject var transport: Transport
    @Environment(\.dismiss) private var dismiss
    @State private var renameDraft: String = ""
    @State private var renaming: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            transportRow
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            controls
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            takesList
        }
        .background(.black)
        .preferredColorScheme(.dark)
    }

    private var transportRow: some View {
        HStack(spacing: 12) {
            // Start/stop — drives the internal clock and any
            // tempo-synced LFOs. Plays back received external clock
            // when source = external.
            Button {
                transport.toggleRunning()
            } label: {
                Image(systemName: transport.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 56, height: 32)
                    .background(transport.isRunning ? Color.red : Color.green)
            }
            .buttonStyle(.plain)

            // BPM readout — editable when internal, display-only when
            // external (external clock dictates BPM).
            VStack(alignment: .leading, spacing: 2) {
                Text("BPM").font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                Text(String(format: "%.1f", transport.bpm))
                    .font(.system(size: 18, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .frame(width: 80, alignment: .leading)

            // Tap tempo — only meaningful for internal clock.
            Button {
                transport.tapTempo()
            } label: {
                Text("TAP")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 32)
                    .background(Color.white.opacity(0.08))
                    .overlay(Rectangle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(transport.clockSource == .externalClock)
            .opacity(transport.clockSource == .externalClock ? 0.3 : 1)

            Spacer()

            // INT / EXT switch.
            HStack(spacing: 0) {
                clockButton("INT", source: .internalClock)
                clockButton("EXT", source: .externalClock)
            }

            // External clock presence indicator.
            HStack(spacing: 4) {
                Circle()
                    .fill(transport.clockSource == .externalClock
                          ? (transport.hasExternalClock ? Color.green : Color.red)
                          : Color.white.opacity(0.2))
                    .frame(width: 8, height: 8)
                Text(transport.clockSource == .externalClock
                     ? (transport.hasExternalClock ? "EXT LIVE" : "NO EXT")
                     : "—")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func clockButton(_ label: String, source: Transport.ClockSource) -> some View {
        let active = transport.clockSource == source
        return Button { transport.clockSource = source } label: {
            Text(label)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(active ? .black : .white)
                .frame(width: 50, height: 32)
                .background(active ? Color.white : Color.white.opacity(0.06))
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack {
            Text("AUTOMATION")
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .tracking(2.0)
            Spacer()
            stateBadge
            Button("CLOSE") { dismiss() }
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var stateBadge: some View {
        let (label, color): (String, Color) = {
            switch engine.state {
            case .idle: return ("IDLE", .white.opacity(0.5))
            case .armedRecord: return ("ARMED REC", .red)
            case .recording: return ("RECORDING", .red)
            case .armedPlayback: return ("ARMED PLAY", .yellow)
            case .playing: return ("PLAYING", .green)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color.white.opacity(0.06))
        .overlay(Rectangle().strokeBorder(color.opacity(0.5), lineWidth: 1))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                actionButton(
                    title: engine.state == .recording ? "RECORDING…" : (engine.overdubEnabled && engine.selectedTakeId != nil ? "ARM OVERDUB" : "ARM REC"),
                    tint: .red,
                    isActive: engine.state == .armedRecord || engine.state == .recording
                ) {
                    if engine.state == .armedRecord || engine.state == .recording {
                        engine.disarm()
                    } else {
                        engine.armRecord()
                    }
                }
                actionButton(title: "START REC", tint: .red, isActive: false) {
                    engine.startRecordingNow()
                }
                actionButton(
                    title: engine.state == .playing ? "PLAYING…" : "ARM PLAY",
                    tint: .green,
                    isActive: engine.state == .armedPlayback || engine.state == .playing,
                    disabled: engine.selectedTakeId == nil
                ) {
                    if engine.state == .armedPlayback || engine.state == .playing {
                        engine.disarm()
                    } else {
                        engine.armPlayback()
                    }
                }
                actionButton(title: "START PLAY", tint: .green, isActive: false, disabled: engine.selectedTakeId == nil) {
                    engine.startPlaybackNow()
                }
                Spacer()
                loopToggle
                overdubToggle
            }
            HStack(spacing: 10) {
                Text("ARM = wait for external MIDI Clock + Start. START = run on internal clock @ 90 BPM.")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text("Tick: \(engine.currentTick)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var loopToggle: some View {
        Button(action: { engine.loopEnabled.toggle() }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(engine.loopEnabled ? Color.cyan : Color.white.opacity(0.25))
                    .frame(width: 9, height: 9)
                Text("LOOP")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(engine.loopEnabled ? Color.cyan.opacity(0.18) : Color.white.opacity(0.06))
            .overlay(Rectangle().strokeBorder(engine.loopEnabled ? Color.cyan : Color.white.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var overdubToggle: some View {
        Button(action: { engine.overdubEnabled.toggle() }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(engine.overdubEnabled ? Color.purple : Color.white.opacity(0.25))
                    .frame(width: 9, height: 9)
                Text("OVERDUB")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(engine.overdubEnabled ? Color.purple.opacity(0.18) : Color.white.opacity(0.06))
            .overlay(Rectangle().strokeBorder(engine.overdubEnabled ? Color.purple : Color.white.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func actionButton(title: String, tint: Color, isActive: Bool, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                .foregroundStyle(isActive ? Color.black : Color.white)
                .frame(width: 130, height: 44)
                .background(isActive ? tint : Color.white.opacity(0.08))
                .overlay(Rectangle().strokeBorder(tint.opacity(disabled ? 0.2 : 0.8), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1.0)
    }

    private var takesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TAKES")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .tracking(2.0)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                if engine.selectedTakeId != nil {
                    Button("RENAME") {
                        if let take = engine.takes.first(where: { $0.id == engine.selectedTakeId }) {
                            renameDraft = take.name
                            renaming = true
                        }
                    }
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.cyan)
                    Button("DELETE") { engine.deleteSelectedTake() }
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if engine.takes.isEmpty {
                Text("No takes yet. Arm record, hit play on your MIDI clock source, perform, hit stop.")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(engine.takes) { take in
                            takeRow(take)
                            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                        }
                    }
                }
            }
        }
        .alert("Rename take", isPresented: $renaming) {
            TextField("Name", text: $renameDraft)
            Button("Save") { engine.renameSelectedTake(to: renameDraft) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func takeRow(_ take: AutomationTake) -> some View {
        let isSelected = take.id == engine.selectedTakeId
        return HStack {
            Text(take.name)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white)
            Spacer()
            Text("\(take.events.count) ev · \(take.totalTicks) ticks")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isSelected ? Color.cyan.opacity(0.16) : Color.clear)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(Color.cyan).frame(width: 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { engine.selectedTakeId = take.id }
    }
}
