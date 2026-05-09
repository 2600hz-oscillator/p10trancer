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
    private var mainFormat: AVAudioFormat?
    private var sampleRate: Double = 48_000
    private var framesWritten: Int64 = 0
    private var enabled: Bool = false
    private var includeMic: Bool = false
    private var micQueue: MicBufferQueue?
    private var micGain: Float = 0
    private var micConverter: AVAudioConverter?
    private var micConverterIn: AVAudioFormat?
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
                   sampleRate: Double,
                   mainFormat: AVAudioFormat) {
        lock.lock()
        defer { lock.unlock() }
        self.input = input
        self.formatDescription = formatDescription
        self.sampleRate = sampleRate
        self.mainFormat = mainFormat
        self.framesWritten = 0
    }

    func setEnabled(_ on: Bool) {
        lock.lock()
        enabled = on
        lock.unlock()
    }

    /// Enable mic-into-recording mixing. The supplied `MicBufferQueue` is
    /// drained during each main-mixer tap callback; samples are converted
    /// to the main format (if needed) and sum-mixed into the buffer that
    /// gets appended to the writer. `gain` is the mic level multiplier.
    func setMicMix(queue: MicBufferQueue?, gain: Float) {
        lock.lock()
        self.micQueue = queue
        self.micGain = max(0, min(1, gain))
        self.includeMic = (queue != nil) && (gain > 0)
        if !includeMic { self.micConverter = nil; self.micConverterIn = nil }
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

        lock.lock()
        guard enabled,
              let formatDescription = formatDescription,
              let input = input,
              let mainFormat = mainFormat,
              sampleRate > 0 else {
            lock.unlock()
            return
        }
        let pts = CMTime(value: framesWritten, timescale: Int32(sampleRate))
        let duration = CMTime(value: 1, timescale: Int32(sampleRate))
        framesWritten += Int64(frames)
        let mixMicNow = includeMic
        let micQueue = self.micQueue
        let micGain = self.micGain
        lock.unlock()

        // If mic-mix is on, prepare a writable copy of the main buffer and
        // sum the next mic buffer (converted to the main format) into it.
        let bufferToWrite: AVAudioPCMBuffer
        if mixMicNow, let micQueue,
           let micRaw = micQueue.popOldest(),
           let mixed = mixedBuffer(main: buffer, mic: micRaw, mainFormat: mainFormat, gain: micGain) {
            bufferToWrite = mixed
        } else {
            bufferToWrite = buffer
        }

        if diagnosticCounter <= 4 || diagnosticCounter % 60 == 0 {
            let rms: Float
            if let ch = bufferToWrite.floatChannelData?[0] {
                var sum: Float = 0
                for i in 0..<Int(bufferToWrite.frameLength) { sum += ch[i] * ch[i] }
                rms = sqrtf(sum / Float(max(1, bufferToWrite.frameLength)))
            } else {
                rms = -1
            }
            P10Logger.log("[AudioAppender] tap #\(diagnosticCounter) frames=\(frames) rms=\(String(format: "%.4f", rms)) mic=\(mixMicNow)")
        }

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
            bufferList: bufferToWrite.audioBufferList
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

    /// Sum-mix `mic` into a copy of `main`, converting `mic` to `mainFormat`
    /// first if needed. Returns nil on conversion failure (mic samples are
    /// dropped silently in that case — file audio still records cleanly).
    private func mixedBuffer(main: AVAudioPCMBuffer,
                             mic: AVAudioPCMBuffer,
                             mainFormat: AVAudioFormat,
                             gain: Float) -> AVAudioPCMBuffer? {
        guard let dest = AVAudioPCMBuffer(pcmFormat: mainFormat, frameCapacity: main.frameLength) else { return nil }
        dest.frameLength = main.frameLength
        guard let mainCh = main.floatChannelData,
              let dstCh = dest.floatChannelData else { return nil }

        // Copy main → dest first.
        let frames = Int(main.frameLength)
        let channels = Int(mainFormat.channelCount)
        for ch in 0..<channels {
            memcpy(dstCh[ch], mainCh[ch], frames * MemoryLayout<Float>.size)
        }

        // Resolve mic → mainFormat conversion.
        let micToMain: AVAudioPCMBuffer
        if mic.format == mainFormat {
            micToMain = mic
        } else {
            // Build/refresh converter when mic format changes.
            if micConverter == nil || micConverterIn != mic.format {
                micConverter = AVAudioConverter(from: mic.format, to: mainFormat)
                micConverterIn = mic.format
            }
            guard let conv = micConverter,
                  let converted = AVAudioPCMBuffer(pcmFormat: mainFormat, frameCapacity: main.frameLength) else {
                return dest // give up on mic this round; main-only result
            }
            converted.frameLength = main.frameLength
            var didFeed = false
            var convError: NSError?
            let status = conv.convert(to: converted, error: &convError) { _, outStatus in
                if didFeed { outStatus.pointee = .endOfStream; return nil }
                didFeed = true
                outStatus.pointee = .haveData
                return mic
            }
            if status == .error || convError != nil {
                return dest
            }
            micToMain = converted
        }

        // Sum mic samples into dest with gain.
        guard let micCh = micToMain.floatChannelData else { return dest }
        let micFrames = Int(micToMain.frameLength)
        let mixFrames = min(frames, micFrames)
        for ch in 0..<channels {
            let micChIdx = ch < Int(micToMain.format.channelCount) ? ch : 0
            let dstCol = dstCh[ch]
            let micCol = micCh[micChIdx]
            for i in 0..<mixFrames {
                dstCol[i] += micCol[i] * gain
            }
        }
        return dest
    }
}
