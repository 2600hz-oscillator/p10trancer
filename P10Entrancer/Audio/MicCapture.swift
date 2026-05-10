import Foundation
import AVFoundation

/// Captures the iPad mic via a *dedicated* AVAudioEngine (not the
/// shared playback engine). Activating inputNode on the playback
/// engine silences mainMixer's output on iPadOS 26 — see
/// AudioEndToEndTests.test_audio_survives_mic_tap_install. A separate
/// engine has its own graph, so installing a tap on its inputNode
/// doesn't disturb playback.
@MainActor
final class MicCapture: ObservableObject {
    static let shared = MicCapture()

    private(set) var isReady = false
    /// Aggregate gain applied to the mic in recordings. Set by
    /// `AppState.applyAudioRouting()` based on routed camera pads' sliders.
    /// 0 = mic excluded from recordings; 1 = full level.
    @Published var recordGain: Float = 0
    /// Latest RMS of incoming mic samples, [0...1]. Pads that show a
    /// camera source watch this for a live VU meter so the user can
    /// confirm the mic is picking up audio (and at what level).
    @Published private(set) var inputLevel: Float = 0
    let queue = MicBufferQueue()

    /// Dedicated mic engine. Started only after permission is granted.
    private let micEngine = AVAudioEngine()
    private var tapInstalled = false
    private var setupTask: Task<Void, Never>?

    private init() {}

    /// Idempotent. Returns once the dedicated mic engine is running and
    /// the tap is installed (or once permission is denied / setup
    /// failed). Safe from N concurrent callers.
    func ensureRunning() async {
        if isReady { return }
        if let task = setupTask {
            await task.value
            return
        }
        let task = Task { @MainActor in await self.runSetup() }
        setupTask = task
        await task.value
    }

    private func runSetup() async {
        let granted = await requestPermission()
        guard granted else {
            P10Logger.log("[MicCapture] permission denied")
            return
        }
        guard !tapInstalled else {
            isReady = true
            return
        }
        // Tap inputNode of the dedicated mic engine — never the shared
        // playback engine. format: nil lets AVFoundation resolve from
        // the live route.
        let queue = self.queue
        micEngine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            queue.push(buffer)
            // Compute the buffer's RMS for the VU meter and push to
            // MainActor so SwiftUI views can observe @Published changes.
            // Cheap to compute on the audio thread; small per-frame
            // hop to main is fine at the tap's natural rate (~10/s).
            if let ch0 = buffer.floatChannelData?[0] {
                var sum: Float = 0
                let n = Int(buffer.frameLength)
                for i in 0..<n { sum += ch0[i] * ch0[i] }
                let rms = sqrtf(sum / Float(max(1, n)))
                Task { @MainActor [weak self] in self?.inputLevel = rms }
            }
        }
        tapInstalled = true
        do {
            try micEngine.start()
            isReady = true
            let fmt = micEngine.inputNode.outputFormat(forBus: 0)
            P10Logger.log("[MicCapture] dedicated engine running; tap ch=\(fmt.channelCount) sr=\(fmt.sampleRate)")
        } catch {
            P10Logger.log("[MicCapture] mic engine start failed: \(error)")
        }
    }

    /// Currently-known mic format from the dedicated mic engine.
    var inputFormat: AVAudioFormat {
        micEngine.inputNode.outputFormat(forBus: 0)
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }
}

/// Thread-safe FIFO of PCM mic buffers. Producer is the audio render
/// thread (`MicCapture`'s tap callback); consumer is the recorder's audio
/// queue. Buffers are deep-copied on push because the system reuses the
/// originals after the tap callback returns.
final class MicBufferQueue {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    /// Cap to avoid unbounded growth if the consumer falls behind. ~12
    /// buffers ≈ 100–500 ms depending on buffer size.
    private let capacity = 12

    func push(_ buffer: AVAudioPCMBuffer) {
        guard let copy = MicBufferQueue.copy(of: buffer) else { return }
        lock.lock()
        buffers.append(copy)
        if buffers.count > capacity { buffers.removeFirst() }
        lock.unlock()
    }

    func popOldest() -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffers.isEmpty ? nil : buffers.removeFirst()
    }

    func clear() {
        lock.lock()
        buffers.removeAll()
        lock.unlock()
    }

    private static func copy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let dest = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else { return nil }
        dest.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        if let srcF = buffer.floatChannelData, let dstF = dest.floatChannelData {
            for ch in 0..<channels {
                memcpy(dstF[ch], srcF[ch], frames * MemoryLayout<Float>.size)
            }
        } else if let srcI = buffer.int16ChannelData, let dstI = dest.int16ChannelData {
            for ch in 0..<channels {
                memcpy(dstI[ch], srcI[ch], frames * MemoryLayout<Int16>.size)
            }
        } else {
            return nil
        }
        return dest
    }
}
