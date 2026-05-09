import SwiftUI

struct AutomationPanelView: View {
    @ObservedObject var engine: AutomationEngine
    @Environment(\.dismiss) private var dismiss
    @State private var renameDraft: String = ""
    @State private var renaming: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            controls
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            takesList
        }
        .background(.black)
        .preferredColorScheme(.dark)
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
