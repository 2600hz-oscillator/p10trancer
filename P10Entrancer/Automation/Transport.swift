import Foundation
import Combine
import QuartzCore

/// Master clock + transport. LFOs (and any future tempo-synced effect)
/// subscribe to `onTick` — fires 24 times per quarter note (the MIDI
/// standard) whether the clock comes from an external device or our
/// internal pulse generator.
///
/// The user picks `clockSource`:
///   - .internal: BPM is driven by a Timer at `bpm` rate. Transport
///     play/stop is controlled by `start()`/`stop()`. Tap tempo updates
///     BPM.
///   - .external: BPM and play/stop come from incoming MIDI Real-Time
///     bytes (0xF8 clock, 0xFA start, 0xFC stop). With no incoming
///     clock the transport never advances — the user explicitly chose
///     to follow an external source that isn't there.
///
/// LFOs assume one tick = 1/24 quarter note. Their per-LFO rate divider
/// converts that to phase increment per tick.
@MainActor
final class Transport: ObservableObject {
    enum ClockSource: String, Codable {
        case internalClock = "internal"
        case externalClock = "external"
    }

    @Published var clockSource: ClockSource = .internalClock {
        didSet {
            guard clockSource != oldValue else { return }
            // Switching source: stop both engines, let the user press
            // play again. Avoids playing the wrong source briefly.
            stop()
        }
    }
    @Published private(set) var bpm: Double = 120 {
        didSet { restartInternalIfNeeded() }
    }
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var hasExternalClock: Bool = false
    /// Total ticks accumulated this run (resets on stop, NOT on bpm
    /// change). LFOs use this for phase.
    @Published private(set) var tickCount: UInt64 = 0

    /// Fired on every clock pulse (24 PPQ). Subscribers should be cheap.
    let tickPublisher = PassthroughSubject<UInt64, Never>()

    private var internalTimer: DispatchSourceTimer?
    private var lastExternalTickAt: CFTimeInterval = 0
    private var externalTickIntervals: [CFTimeInterval] = []
    private var externalClockTimeoutTimer: Timer?
    private var tapTimes: [CFTimeInterval] = []

    // MARK: - User actions

    func start() {
        guard !isRunning else { return }
        isRunning = true
        tickCount = 0
        if clockSource == .internalClock {
            startInternalTimer()
        }
        // External: do nothing extra; ticks land from MIDIRouter.
    }

    func stop() {
        guard isRunning || internalTimer != nil else { return }
        isRunning = false
        internalTimer?.cancel()
        internalTimer = nil
        tickCount = 0
    }

    func toggleRunning() { isRunning ? stop() : start() }

    /// Tap tempo: each call records a tap. Two or more recent taps set
    /// BPM from the average interval. Only meaningful for internal
    /// clock — taps when source is external are ignored.
    func tapTempo() {
        guard clockSource == .internalClock else { return }
        let now = CACurrentMediaTime()
        // Drop stale taps (>2s since the last) so a fresh attempt
        // doesn't average with an old one.
        if let last = tapTimes.last, now - last > 2.0 { tapTimes.removeAll() }
        tapTimes.append(now)
        while tapTimes.count > 6 { tapTimes.removeFirst() }
        guard tapTimes.count >= 2 else { return }
        let intervals = zip(tapTimes.dropFirst(), tapTimes).map { $0.0 - $0.1 }
        let avg = intervals.reduce(0, +) / Double(intervals.count)
        guard avg > 0.1, avg < 2.0 else { return } // 30–600 BPM bound
        bpm = (60.0 / avg).clamped(to: 30...300)
    }

    func setBPM(_ value: Double) {
        bpm = value.clamped(to: 30...300)
    }

    // MARK: - External clock input (called by MIDIRouter.onRealTime)

    /// Handle a MIDI real-time byte (0xF8, 0xFA, 0xFB, 0xFC).
    func handleRealTimeByte(_ byte: UInt8) {
        guard clockSource == .externalClock else { return }
        switch byte {
        case 0xF8: handleExternalTick()
        case 0xFA: // Start
            if !isRunning { isRunning = true; tickCount = 0 }
        case 0xFB: // Continue
            if !isRunning { isRunning = true }
        case 0xFC: // Stop
            isRunning = false
        default: break
        }
    }

    private func handleExternalTick() {
        let now = CACurrentMediaTime()
        if lastExternalTickAt > 0 {
            let dt = now - lastExternalTickAt
            externalTickIntervals.append(dt)
            // Average over the last ~24 ticks (one quarter note) for a
            // smooth BPM readout.
            while externalTickIntervals.count > 24 { externalTickIntervals.removeFirst() }
            if externalTickIntervals.count >= 4 {
                let avg = externalTickIntervals.reduce(0, +) / Double(externalTickIntervals.count)
                if avg > 0 {
                    let computed = 60.0 / (avg * 24.0)
                    bpm = computed.clamped(to: 30...300)
                }
            }
        }
        lastExternalTickAt = now
        hasExternalClock = true
        armExternalTimeout()
        if !isRunning { isRunning = true }
        tickCount &+= 1
        tickPublisher.send(tickCount)
    }

    /// If we don't see an external 0xF8 for ~1s, assume the source
    /// went away. Transport stops (per spec: "if no external signal
    /// present our transport doesn't run").
    private func armExternalTimeout() {
        externalClockTimeoutTimer?.invalidate()
        externalClockTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.hasExternalClock = false
                self?.isRunning = false
            }
        }
    }

    // MARK: - Internal clock

    private func startInternalTimer() {
        internalTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        let interval = secondsPerTick()
        // 1ms leeway is what the kernel comfortably honors; tighter
        // doesn't actually improve precision on iOS but it adds CPU.
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.tickCount &+= 1
            self.tickPublisher.send(self.tickCount)
        }
        timer.resume()
        internalTimer = timer
    }

    private func restartInternalIfNeeded() {
        guard isRunning, clockSource == .internalClock else { return }
        startInternalTimer()
    }

    private func secondsPerTick() -> TimeInterval {
        // 24 PPQ. quarter-note duration = 60 / bpm. tick = qn / 24.
        return 60.0 / max(30.0, bpm) / 24.0
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
