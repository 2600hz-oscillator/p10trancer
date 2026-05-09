import Foundation
import AVFoundation

/// Singleton that owns the iPad mic input. Configures the audio session for
/// `.playAndRecord` (one-time mic-permission prompt) and exposes a downstream
/// mixer node that camera pads tap into. Idempotent: callers wait on
/// `ensureRunning()` and broadcast their gain stage with `connect(to:)`.
@MainActor
final class MicCapture {
    static let shared = MicCapture()

    private(set) var isReady: Bool = false
    /// Output of the mic gate. Camera pads' AVAudioMixerNodes tap from here
    /// via the broadcast-fanout `connect(_:to:)` API on `AVAudioEngine`.
    let output = AVAudioMixerNode()

    private var taps: [AVAudioConnectionPoint] = []
    private var attachedToEngine = false
    private var sessionConfigured = false
    private var setupTask: Task<Void, Never>?

    private init() {}

    /// Permission + session + engine wiring. Returns once mic capture is
    /// running and the `output` node is live. Safe to call from N concurrent
    /// tasks — the first one runs setup; the rest wait on the same Task and
    /// resume once setup completes (no double-attach race).
    func ensureRunning() async {
        if isReady { return }
        if let setupTask {
            await setupTask.value
            return
        }
        let task = Task { @MainActor in await self.runSetup() }
        setupTask = task
        await task.value
    }

    private func runSetup() async {
        let granted = await requestPermission()
        guard granted else {
            P10Logger.log("[MicCapture] mic permission denied")
            return
        }
        do {
            try configureSession()
            let engine = AudioEngine.shared.engine
            if !attachedToEngine {
                engine.attach(output)
                let inputFormat = engine.inputNode.outputFormat(forBus: 0)
                P10Logger.log("[MicCapture] inputFormat ch=\(inputFormat.channelCount) sr=\(inputFormat.sampleRate)")
                guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
                    P10Logger.log("[MicCapture] input not ready — bailing out")
                    return
                }
                engine.connect(engine.inputNode, to: output, format: inputFormat)
                attachedToEngine = true
            }
            isReady = true
            P10Logger.log("[MicCapture] running")
        } catch {
            P10Logger.log("[MicCapture] setup failed: \(error)")
        }
    }

    /// Add `destination` as a tap of the mic. The engine fans-out the mic
    /// signal to every registered destination via a single broadcast
    /// connection rebuilt on each add. `destination` should already be
    /// attached to the engine.
    func connect(_ destination: AVAudioNode, format: AVAudioFormat? = nil) {
        guard isReady else { return }
        let engine = AudioEngine.shared.engine
        engine.disconnectNodeOutput(output)
        taps.append(AVAudioConnectionPoint(node: destination, bus: 0))
        let fmt = format ?? engine.inputNode.outputFormat(forBus: 0)
        engine.connect(output, to: taps, fromBus: 0, format: fmt)
    }

    /// Disconnect a previously connected tap (called from PadAudioPlayer
    /// deinit when the camera source is replaced).
    func disconnect(_ destination: AVAudioNode) {
        let engine = AudioEngine.shared.engine
        engine.disconnectNodeOutput(output)
        taps.removeAll { $0.node === destination }
        guard !taps.isEmpty else { return }
        let fmt = engine.inputNode.outputFormat(forBus: 0)
        engine.connect(output, to: taps, fromBus: 0, format: fmt)
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    private func configureSession() throws {
        // AudioEngine sets the category to .playAndRecord at startup, so
        // there's nothing to reconfigure here. This is left as a no-op for
        // future hooks (e.g., switching to a USB audio interface).
        sessionConfigured = true
    }
}
