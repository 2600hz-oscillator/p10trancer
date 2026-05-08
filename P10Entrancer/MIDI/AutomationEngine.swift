import Foundation
import Combine
import QuartzCore

/// Records and plays back MIDI takes locked to incoming MIDI Clock.
///
/// Recording: armed → on next 0xFA (Start), capture every channel-voice byte
/// stream with the running tick index and sub-tick phase. On 0xFC (Stop), save
/// the take.
///
/// Playback: armed (with a take selected) → on next 0xFA, schedule each
/// recorded event at its (tick + phase * tickPeriod) absolute time. On 0xFC,
/// halt scheduled events.
///
/// Sub-tick phase is preserved so a 1ms-resolution gesture isn't quantized to
/// the 24-PPQ grid (which is ~20.8ms at 120 BPM).
@MainActor
final class AutomationEngine: ObservableObject {
    enum State: String {
        case idle
        case armedRecord
        case recording
        case armedPlayback
        case playing
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var takes: [AutomationTake] = []
    @Published var selectedTakeId: UUID?
    @Published private(set) var currentTick: Int = 0
    /// When true, recording into the selected take preserves existing events
    /// on streams (CC#/note#/PC#) that are NOT touched in the new pass, and
    /// also plays back the existing take during recording so you can hear it.
    @Published var overdubEnabled: Bool = false

    private var recordingEvents: [AutomationEvent] = []
    private var recordingTouchedStreams: Set<StreamKey> = []
    private var recordingStartedAt: TimeInterval = 0
    private var overdubBaseTakeId: UUID?
    private var lastTickTime: TimeInterval = 0
    private var tickPeriod: TimeInterval = 0.020833 // 120 BPM @ 24 PPQ
    private var tickPeriodSamples: [TimeInterval] = []
    private let tickPeriodWindow = 12

    private var playbackEvents: [AutomationEvent] = []
    private var playbackEventCursor: Int = 0
    private var playbackStartTime: TimeInterval = 0
    private var playbackTimer: Timer?

    private weak var router: MIDIRouter?
    private weak var output: MIDISink?

    private let storageDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Automations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        loadTakes()
    }

    func attach(router: MIDIRouter, output: MIDISink) {
        self.router = router
        self.output = output
        let existingChannelVoice = router.onChannelVoiceBytes
        router.onChannelVoiceBytes = { [weak self] bytes in
            existingChannelVoice?(bytes)
            self?.recordIfNeeded(bytes: bytes)
        }
        let existingRealTime = router.onRealTime
        router.onRealTime = { [weak self] status in
            existingRealTime?(status)
            self?.handleRealTime(status)
        }
    }

    // MARK: - Public arming controls

    func armRecord() {
        guard state == .idle || state == .armedPlayback else { return }
        // Capture which take we're overdubbing onto NOW so the user can change
        // selection mid-arm without breaking the merge target.
        overdubBaseTakeId = (overdubEnabled ? selectedTakeId : nil)
        state = .armedRecord
        P10Logger.log("[Automation] armed record (overdub=\(overdubEnabled), base=\(overdubBaseTakeId?.uuidString ?? "—"))")
    }

    func armPlayback() {
        guard let id = selectedTakeId, takes.contains(where: { $0.id == id }) else { return }
        guard state == .idle || state == .armedRecord else { return }
        state = .armedPlayback
        P10Logger.log("[Automation] armed playback for take \(id)")
    }

    func disarm() {
        switch state {
        case .recording: stopRecording(save: false)
        case .playing: stopPlayback()
        default: break
        }
        state = .idle
        P10Logger.log("[Automation] disarmed → idle")
    }

    // MARK: - Capture from outbound emissions (gestures)

    func captureOutbound(_ bytes: [UInt8]) {
        recordIfNeeded(bytes: bytes)
    }

    // MARK: - Real-Time handling

    private func handleRealTime(_ status: UInt8) {
        switch status {
        case 0xF8:
            tickClock()
        case 0xFA:
            startTransport(fromBeginning: true)
        case 0xFB:
            startTransport(fromBeginning: false)
        case 0xFC:
            stopTransport()
        default:
            break
        }
    }

    private func tickClock() {
        let now = CACurrentMediaTime()
        if lastTickTime > 0 {
            let dt = now - lastTickTime
            if dt > 0.0005 && dt < 0.5 {
                tickPeriodSamples.append(dt)
                if tickPeriodSamples.count > tickPeriodWindow {
                    tickPeriodSamples.removeFirst()
                }
                tickPeriod = tickPeriodSamples.reduce(0, +) / TimeInterval(tickPeriodSamples.count)
            }
        }
        lastTickTime = now
        if state == .recording || state == .playing {
            currentTick &+= 1
        }
    }

    private func startTransport(fromBeginning: Bool) {
        let now = CACurrentMediaTime()
        if fromBeginning {
            currentTick = 0
        }
        switch state {
        case .armedRecord:
            recordingEvents.removeAll()
            recordingTouchedStreams.removeAll()
            recordingStartedAt = now
            state = .recording
            // Overdub: also play the existing take so the user hears/sees the
            // context they're layering on top of. The base take is captured at
            // arm time so playback isn't affected by other takes selected mid-pass.
            if overdubEnabled,
               let baseId = overdubBaseTakeId,
               let take = takes.first(where: { $0.id == baseId }) {
                playbackEvents = take.events
                playbackEventCursor = 0
                playbackStartTime = now
                P10Logger.log("[Automation] overdub: playing base take during recording (\(take.events.count) events)")
                scheduleNextPlaybackEvents()
            }
            P10Logger.log("[Automation] recording started (overdub=\(overdubEnabled))")
        case .armedPlayback:
            beginPlayback(fromBeginning: fromBeginning, now: now)
        default:
            break
        }
    }

    private func stopTransport() {
        switch state {
        case .recording:
            stopRecording(save: true)
        case .playing:
            stopPlayback()
        default:
            break
        }
    }

    // MARK: - Recording

    private func recordIfNeeded(bytes: [UInt8]) {
        guard state == .recording else { return }
        let now = CACurrentMediaTime()
        let elapsedSinceLastTick = max(0, now - lastTickTime)
        let phase = tickPeriod > 0 ? Float(min(1.0, elapsedSinceLastTick / tickPeriod)) : 0
        recordingEvents.append(AutomationEvent(
            tick: currentTick,
            phase: phase,
            bytes: bytes
        ))
        if let key = StreamKey(bytes: bytes) {
            recordingTouchedStreams.insert(key)
        }
    }

    private func stopRecording(save: Bool) {
        let newEvents = recordingEvents
        let touched = recordingTouchedStreams
        recordingEvents.removeAll()
        recordingTouchedStreams.removeAll()
        // Stop overdub playback that was running alongside.
        playbackTimer?.invalidate()
        playbackTimer = nil
        playbackEvents.removeAll()
        playbackEventCursor = 0

        guard save && !newEvents.isEmpty else {
            P10Logger.log("[Automation] recording discarded (events=\(newEvents.count), save=\(save))")
            state = .idle
            return
        }

        if overdubEnabled,
           let baseId = overdubBaseTakeId,
           let baseIdx = takes.firstIndex(where: { $0.id == baseId }) {
            let base = takes[baseIdx]
            let preserved = base.events.filter { event in
                guard let key = StreamKey(bytes: event.bytes) else { return true }
                return !touched.contains(key)
            }
            var merged = preserved + newEvents
            merged.sort { ($0.tick, $0.phase) < ($1.tick, $1.phase) }
            let totalTicks = max(base.totalTicks, merged.last?.tick ?? 0)
            let updated = AutomationTake(
                id: base.id,
                name: base.name,
                createdAt: base.createdAt,
                totalTicks: totalTicks,
                events: merged
            )
            takes[baseIdx] = updated
            persistTake(updated)
            P10Logger.log("[Automation] overdub merged into '\(updated.name)': +\(newEvents.count) new, kept \(preserved.count), touched \(touched.count) streams")
        } else {
            let totalTicks = newEvents.last?.tick ?? currentTick
            let take = AutomationTake(
                id: UUID(),
                name: defaultTakeName(),
                createdAt: Date(),
                totalTicks: totalTicks,
                events: newEvents
            )
            persistTake(take)
            takes.insert(take, at: 0)
            selectedTakeId = take.id
            P10Logger.log("[Automation] saved take '\(take.name)' (\(newEvents.count) events, \(totalTicks) ticks)")
        }
        state = .idle
    }

    private func defaultTakeName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "Take \(formatter.string(from: Date()))"
    }

    // MARK: - Playback

    private func beginPlayback(fromBeginning: Bool, now: TimeInterval) {
        guard let take = takes.first(where: { $0.id == selectedTakeId }) else { return }
        playbackEvents = take.events
        playbackEventCursor = 0
        playbackStartTime = now
        state = .playing
        P10Logger.log("[Automation] playback started, \(take.events.count) events queued")
        scheduleNextPlaybackEvents()
    }

    private func scheduleNextPlaybackEvents() {
        playbackTimer?.invalidate()
        guard state == .playing, playbackEventCursor < playbackEvents.count else { return }
        let nextEvent = playbackEvents[playbackEventCursor]
        let absoluteTime = playbackStartTime
            + TimeInterval(nextEvent.tick) * tickPeriod
            + TimeInterval(nextEvent.phase) * tickPeriod
        let delay = max(0, absoluteTime - CACurrentMediaTime())
        playbackTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.firePlaybackTick()
            }
        }
    }

    private func firePlaybackTick() {
        guard state == .playing else { return }
        let nowEvent = playbackEvents[playbackEventCursor]
        emitPlaybackEvent(nowEvent.bytes)
        playbackEventCursor += 1
        if playbackEventCursor >= playbackEvents.count {
            P10Logger.log("[Automation] playback complete")
            state = .idle
            return
        }
        scheduleNextPlaybackEvents()
    }

    private func emitPlaybackEvent(_ bytes: [UInt8]) {
        // Re-perform on iPad: feed back through the router so MIDIBindings runs
        // its mute-during-inbound path and updates UI state.
        router?.inject(bytes: bytes)
        // Mirror to Bitwig so the DAW sees the playback too.
        output?.send(bytes)
    }

    private func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        playbackEvents.removeAll()
        playbackEventCursor = 0
        state = .idle
        P10Logger.log("[Automation] playback stopped")
    }

    // MARK: - Persistence

    func renameSelectedTake(to newName: String) {
        guard let id = selectedTakeId,
              let idx = takes.firstIndex(where: { $0.id == id }) else { return }
        var take = takes[idx]
        take.name = newName
        takes[idx] = take
        persistTake(take)
    }

    func deleteSelectedTake() {
        guard let id = selectedTakeId,
              let idx = takes.firstIndex(where: { $0.id == id }) else { return }
        let take = takes.remove(at: idx)
        try? FileManager.default.removeItem(at: takeURL(take.id))
        selectedTakeId = takes.first?.id
    }

    private func loadTakes() {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: storageDir,
                                                                          includingPropertiesForKeys: nil) else { return }
        var loaded: [AutomationTake] = []
        for url in entries where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let take = try? JSONDecoder().decode(AutomationTake.self, from: data) {
                loaded.append(take)
            }
        }
        loaded.sort { $0.createdAt > $1.createdAt }
        takes = loaded
        selectedTakeId = takes.first?.id
    }

    private func persistTake(_ take: AutomationTake) {
        let url = takeURL(take.id)
        if let data = try? JSONEncoder().encode(take) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func takeURL(_ id: UUID) -> URL {
        storageDir.appendingPathComponent("\(id.uuidString).json")
    }
}

struct AutomationTake: Codable, Identifiable {
    let id: UUID
    var name: String
    let createdAt: Date
    let totalTicks: Int
    let events: [AutomationEvent]
}

struct AutomationEvent: Codable {
    let tick: Int
    let phase: Float
    let bytes: [UInt8]
}

/// Identifies a "stream" of events (one CC, one note, one PC channel) so that
/// overdub can replace events on touched streams without disturbing the rest.
enum StreamKey: Hashable {
    case cc(channel: Int, number: Int)
    case note(channel: Int, number: Int)
    case pc(channel: Int)

    init?(bytes: [UInt8]) {
        guard !bytes.isEmpty else { return nil }
        let status = bytes[0] & 0xF0
        let channel = Int(bytes[0] & 0x0F)
        switch status {
        case 0xB0:
            guard bytes.count >= 2 else { return nil }
            self = .cc(channel: channel, number: Int(bytes[1]))
        case 0x90, 0x80:
            guard bytes.count >= 2 else { return nil }
            self = .note(channel: channel, number: Int(bytes[1]))
        case 0xC0:
            self = .pc(channel: channel)
        default:
            return nil
        }
    }
}
