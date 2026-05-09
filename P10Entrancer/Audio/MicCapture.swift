import Foundation
import AVFoundation

/// Captures the iPad mic via `installTap(onBus:0)` on the engine's input
/// node. **Never** connects inputNode to other engine nodes — that path
/// reliably crashes AVAudioEngine when the route format isn't yet
/// resolved. The tap callback writes copied PCM buffers into a thread-
/// safe queue that `AudioAppender` drains during recording.
@MainActor
final class MicCapture {
    static let shared = MicCapture()

    private(set) var isReady = false
    /// Aggregate gain applied to the mic in recordings. Set by
    /// `AppState.applyAudioRouting()` based on routed camera pads' sliders.
    /// 0 = mic excluded from recordings; 1 = full level.
    @Published var recordGain: Float = 0
    let queue = MicBufferQueue()

    private var tapInstalled = false
    private var setupTask: Task<Void, Never>?

    private init() {}

    /// Idempotent. Returns once the mic tap is installed (or once
    /// permission was denied / setup already failed). Safe from N
    /// concurrent callers.
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
        let engine = AudioEngine.shared.engine
        guard !tapInstalled else {
            isReady = true
            return
        }
        // installTap on inputNode — Apple's documented pattern. The format
        // is passed as nil so the engine resolves it from the live route.
        // This does not require the engine to be running with input wired
        // up; the tap callback just starts firing once samples are available.
        let queue = self.queue
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            queue.push(buffer)
        }
        tapInstalled = true
        isReady = true
        let fmt = engine.inputNode.outputFormat(forBus: 0)
        P10Logger.log("[MicCapture] tap installed ch=\(fmt.channelCount) sr=\(fmt.sampleRate)")
    }

    /// Currently-known mic format from the engine. Useful for AVAudioConverter.
    var inputFormat: AVAudioFormat {
        AudioEngine.shared.engine.inputNode.outputFormat(forBus: 0)
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
