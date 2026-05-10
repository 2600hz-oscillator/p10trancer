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
    /// Set of audio sources to mix into the recording, alongside the
    /// main mixer's PCM. Each source is iPad mic or a camera's
    /// embedded audio queue. Empty = no auxiliary audio (recording
    /// captures only what the engine's mainMixer is outputting).
    struct AudioSource {
        let queue: MicBufferQueue
        let gain: Float
        let label: String
    }
    private var auxSources: [AudioSource] = []
    /// One converter per (input-format) so we don't allocate on the
    /// audio thread. Keyed by the source's PCM format.
    private var converters: [ObjectIdentifier: (AVAudioConverter, AVAudioFormat)] = [:]
    /// `mach_absolute_time()` at REC start, set by configure(). Combined
    /// with the first `handle()` call's mach time, it yields the PTS
    /// offset of the first audio sample so audio aligns with video
    /// (both use the same wall-clock origin).
    private var recordStartHostTime: UInt64 = 0
    /// Becomes true once we've found the first audio buffer that
    /// began capturing AT or AFTER REC press. Buffers before then
    /// (tap was mid-fill at REC) are dropped so the file's first
    /// audio sample lines up with REC press in wall time.
    private var firstSamplePTSResolved: Bool = false
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()
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
                   mainFormat: AVAudioFormat,
                   recordStartHostTime: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        self.input = input
        self.formatDescription = formatDescription
        self.sampleRate = sampleRate
        self.mainFormat = mainFormat
        self.framesWritten = 0
        self.recordStartHostTime = recordStartHostTime
        self.firstSamplePTSResolved = false
    }

    func setEnabled(_ on: Bool) {
        lock.lock()
        enabled = on
        lock.unlock()
    }

    /// Replace the full list of auxiliary audio sources (iPad mic and/or
    /// any camera-embedded audio queues). Empty list = mainMixer-only
    /// recording. Each source contributes its PCM scaled by its own
    /// gain, mixed into the main-tap buffer in handle().
    func setAuxSources(_ sources: [AudioSource]) {
        lock.lock()
        self.auxSources = sources.filter { $0.gain > 0 }
        // Drop converters for queues no longer in the list so memory
        // doesn't grow with each REC session.
        let liveIDs = Set(self.auxSources.map { ObjectIdentifier($0.queue) })
        self.converters = self.converters.filter { liveIDs.contains($0.key) }
        lock.unlock()
    }

    /// Legacy single-source path. Kept so callers that still pass
    /// `setMicMix(queue:gain:)` keep working — folds into setAuxSources.
    func setMicMix(queue: MicBufferQueue?, gain: Float) {
        guard let queue, gain > 0 else {
            setAuxSources([])
            return
        }
        setAuxSources([AudioSource(queue: queue, gain: gain, label: "mic")])
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

    /// Block until every CMSampleBuffer that's already been dispatched
    /// to the writer queue has actually been appended. Without this,
    /// `MixerRecorder.stop()` would call `markAsFinished` while ~50ms
    /// of audio buffers were still pending — they'd land after the
    /// input was sealed and get silently dropped, cutting off the end
    /// of every recording.
    func flushPendingAppends() {
        queue.sync {}
    }

    private var diagnosticCounter: Int = 0

    /// Continuously-updated RMS of the most recent buffer the persistent
    /// tap delivered. Used by integration tests to verify audio is
    /// flowing through mainMixerNode without having to install a second
    /// tap (AVAudioEngine only allows one tap per bus). Float so the
    /// audio thread can write it without locking.
    private(set) var lastBufferRMS: Float = 0

    /// Tap callback. Runs on the audio render thread.
    func handle(_ buffer: AVAudioPCMBuffer, audioTime: AVAudioTime) {
        let frames = CMItemCount(buffer.frameLength)
        guard frames > 0 else { return }
        diagnosticCounter &+= 1

        // Always-on RMS probe so tests can see whether audio is flowing
        // through mainMixerNode regardless of recording state.
        if let ch0 = buffer.floatChannelData?[0] {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += ch0[i] * ch0[i] }
            lastBufferRMS = sqrtf(sum / Float(max(1, buffer.frameLength)))
        }

        lock.lock()
        guard enabled,
              let formatDescription = formatDescription,
              let input = input,
              let mainFormat = mainFormat,
              sampleRate > 0 else {
            lock.unlock()
            return
        }
        // Drop buffers whose first sample was captured BEFORE REC (the
        // tap was already filling a buffer when the user pressed REC).
        // Without this, the partial pre-REC buffer ends up as audio
        // before video appears — perceived as audio leading. The
        // writer's edit list aligns audio first PTS to 0 regardless,
        // so the only way to keep audio in sync with video is to
        // ensure the first kept buffer was captured AT or AFTER REC.
        if !firstSamplePTSResolved && recordStartHostTime > 0 {
            let now = mach_absolute_time()
            let delta = (now > recordStartHostTime) ? (now - recordStartHostTime) : 0
            let nanos = Double(delta) * Double(Self.timebase.numer) / Double(Self.timebase.denom)
            let elapsedSec = nanos / 1_000_000_000.0
            let bufferDurationSec = Double(buffer.frameLength) / sampleRate
            if elapsedSec - bufferDurationSec < 0 {
                lock.unlock()
                return
            }
            firstSamplePTSResolved = true
        }
        // PTS = framesWritten / sampleRate. First kept buffer is at
        // PTS=0; both audio and video tracks have first PTS=0 in the
        // file so the player shows them in sync.
        let pts = CMTime(value: framesWritten, timescale: Int32(sampleRate))
        let duration = CMTime(value: 1, timescale: Int32(sampleRate))
        framesWritten += Int64(frames)
        let sourcesNow = self.auxSources
        lock.unlock()

        // Mix every active aux source (iPad mic + camera-embedded audio
        // queues) into a writable copy of the main buffer. Each source
        // contributes its converted-and-gained PCM. Sources with no
        // pending sample this tick are skipped — gaps just produce
        // silence frames for that source in this output buffer.
        let bufferToWrite: AVAudioPCMBuffer
        if !sourcesNow.isEmpty,
           let mixed = mixedBufferFromSources(main: buffer, mainFormat: mainFormat, sources: sourcesNow) {
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
            P10Logger.log("[AudioAppender] tap #\(diagnosticCounter) frames=\(frames) rms=\(String(format: "%.4f", rms)) auxSources=\(sourcesNow.count)")
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
        // Retained for any legacy caller. New code uses
        // mixedBufferFromSources to handle N sources at once.
        let source = AudioSource(queue: MicBufferQueue(), gain: gain, label: "legacy")
        _ = source
        return mixedBufferFromSources(
            main: main,
            mainFormat: mainFormat,
            sources: [],
            preFetched: [(mic, gain)]
        )
    }

    /// Mix N PCM sources into a writable copy of the main buffer.
    /// Drains one buffer from each source's queue (skipping sources
    /// whose queue is empty this tick). `preFetched` lets callers
    /// inject already-drained buffers (used by the legacy shim above);
    /// production code passes only `sources`.
    private func mixedBufferFromSources(
        main: AVAudioPCMBuffer,
        mainFormat: AVAudioFormat,
        sources: [AudioSource],
        preFetched: [(AVAudioPCMBuffer, Float)] = []
    ) -> AVAudioPCMBuffer? {
        guard let dest = AVAudioPCMBuffer(pcmFormat: mainFormat, frameCapacity: main.frameLength) else { return nil }
        dest.frameLength = main.frameLength
        guard let mainCh = main.floatChannelData,
              let dstCh = dest.floatChannelData else { return nil }

        let frames = Int(main.frameLength)
        let channels = Int(mainFormat.channelCount)
        for ch in 0..<channels {
            memcpy(dstCh[ch], mainCh[ch], frames * MemoryLayout<Float>.size)
        }

        // Drain a buffer from each live source's queue. Sources with
        // an empty queue this tick contribute silence (skipped).
        var contributions: [(AVAudioPCMBuffer, Float)] = preFetched
        for source in sources {
            // popLatest drops older buffers so high-rate sources
            // (camera USB audio at ~21ms chunks) don't drift behind
            // the main tap's ~85ms cadence.
            guard let raw = source.queue.popLatest() else { continue }
            contributions.append((raw, source.gain))
        }

        for (raw, gain) in contributions {
            let convertedOrSame = convert(raw, to: mainFormat, frames: main.frameLength)
            guard let aux = convertedOrSame,
                  let auxCh = aux.floatChannelData else { continue }
            let auxFrames = Int(aux.frameLength)
            let mixFrames = min(frames, auxFrames)
            for ch in 0..<channels {
                let auxChIdx = ch < Int(aux.format.channelCount) ? ch : 0
                let dstCol = dstCh[ch]
                let auxCol = auxCh[auxChIdx]
                for i in 0..<mixFrames {
                    dstCol[i] += auxCol[i] * gain
                }
            }
        }
        return dest
    }

    /// Returns `raw` unchanged when its format already matches
    /// `mainFormat`, else uses (and caches) an AVAudioConverter to
    /// resample/channel-map it. Returns nil on conversion failure;
    /// caller treats that source as silent this tick.
    private func convert(_ raw: AVAudioPCMBuffer,
                         to mainFormat: AVAudioFormat,
                         frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        if raw.format == mainFormat { return raw }
        let key = ObjectIdentifier(raw.format)
        let converter: AVAudioConverter
        if let cached = converters[key]?.0, converters[key]?.1 == raw.format {
            converter = cached
        } else if let made = AVAudioConverter(from: raw.format, to: mainFormat) {
            converter = made
            converters[key] = (made, raw.format)
        } else {
            return nil
        }
        guard let dest = AVAudioPCMBuffer(pcmFormat: mainFormat, frameCapacity: frames) else { return nil }
        dest.frameLength = frames
        var didFeed = false
        var convError: NSError?
        let status = converter.convert(to: dest, error: &convError) { _, outStatus in
            if didFeed { outStatus.pointee = .endOfStream; return nil }
            didFeed = true
            outStatus.pointee = .haveData
            return raw
        }
        if status == .error || convError != nil { return nil }
        return dest
    }
}
