import Foundation
import AVFoundation
import CoreMedia

/// Captures audio from an AVAudioEngine tap and feeds the PCM samples into
/// an AVAssetWriterInput as CMSampleBuffers. Plain (non-MainActor) class so
/// the tap callback (which runs on a real-time audio thread) can call into
/// it without crossing actor boundaries.
final class AudioAppender {
    private let lock = NSLock()
    private var input: AVAssetWriterInput?
    private var formatDescription: CMAudioFormatDescription?
    private var sampleRate: Double = 48_000
    private var framesWritten: Int64 = 0
    private var enabled: Bool = false
    private let queue = DispatchQueue(label: "p10e.recorder.audio", qos: .userInitiated)

    /// Build a writer input + format description for the given engine output
    /// format. Returns nil if the writer can't accept it.
    static func makeInput(format: AVAudioFormat) -> (AVAssetWriterInput, CMAudioFormatDescription)? {
        let channels = max(1, Int(format.channelCount))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 128_000
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writerInput.expectsMediaDataInRealTime = true

        var asbd = format.streamDescription.pointee
        var fmtDesc: CMAudioFormatDescription?
        let layout = format.channelLayout?.layout
        let status = CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: &asbd,
            layoutSize: layout != nil ? MemoryLayout<AudioChannelLayout>.size : 0,
            layout: layout,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &fmtDesc
        )
        guard status == noErr, let fmtDesc else { return nil }
        return (writerInput, fmtDesc)
    }

    func configure(input: AVAssetWriterInput,
                   formatDescription: CMAudioFormatDescription,
                   sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        self.input = input
        self.formatDescription = formatDescription
        self.sampleRate = sampleRate
        self.framesWritten = 0
    }

    func setEnabled(_ on: Bool) {
        lock.lock()
        enabled = on
        lock.unlock()
    }

    /// Mark the underlying writer input as finished. Call after the tap has
    /// been removed and before `AVAssetWriter.finishWriting`, so the audio
    /// track is sealed before the file is closed.
    func markFinished() {
        lock.lock()
        let input = self.input
        lock.unlock()
        input?.markAsFinished()
    }

    private var diagnosticCounter: Int = 0

    /// Tap callback. Runs on the audio render thread.
    func handle(_ buffer: AVAudioPCMBuffer) {
        let frames = CMItemCount(buffer.frameLength)
        guard frames > 0 else { return }
        diagnosticCounter &+= 1
        if diagnosticCounter <= 4 || diagnosticCounter % 60 == 0 {
            // Quick RMS check on channel 0 so we can tell whether the tap is
            // delivering signal or pure silence (master vol = 0 case).
            let rms: Float
            if let ch = buffer.floatChannelData?[0] {
                var sum: Float = 0
                for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
                rms = sqrtf(sum / Float(max(1, buffer.frameLength)))
            } else {
                rms = -1
            }
            P10Logger.log("[AudioAppender] tap #\(diagnosticCounter) frames=\(frames) rms=\(String(format: "%.4f", rms))")
        }

        lock.lock()
        guard enabled,
              let formatDescription = formatDescription,
              let input = input,
              sampleRate > 0 else {
            lock.unlock()
            return
        }
        let pts = CMTime(value: framesWritten, timescale: Int32(sampleRate))
        let duration = CMTime(value: 1, timescale: Int32(sampleRate))
        framesWritten += Int64(frames)
        lock.unlock()

        var timing = [CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)]
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sampleBuffer = sampleBuffer else { return }

        let attachStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList
        )
        guard attachStatus == noErr else { return }

        queue.async { [weak self, sampleBuffer] in
            guard let self else { return }
            self.lock.lock()
            let stillEnabled = self.enabled
            let writerInput = self.input
            self.lock.unlock()
            guard stillEnabled, let writerInput, writerInput.isReadyForMoreMediaData else { return }
            writerInput.append(sampleBuffer)
        }
    }
}
