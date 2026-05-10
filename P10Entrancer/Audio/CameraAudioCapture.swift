import AVFoundation
import Foundation

/// Captures the audio device paired with a UVC camera (HDMI capture
/// devices like Elgato Cam Link, USB webcams with built-in mics, etc.)
/// onto the camera's own AVCaptureSession. Samples land in a per-camera
/// `MicBufferQueue` that the recorder mixes into the saved file when
/// the camera's pad is routed and "embedded audio" is enabled.
///
/// Separate per camera so two cameras can capture independent audio in
/// the same recording session (each gets its own queue + RMS level).
@MainActor
final class CameraAudioCapture: ObservableObject {
    /// FIFO of PCM buffers from this camera. Same shape as
    /// MicCapture's queue so AudioAppender can drain it identically.
    let queue = MicBufferQueue()

    /// Continuously-updated RMS of incoming buffers, [0...1]. Drives
    /// the camera pad's VU meter when embedded audio is on.
    @Published private(set) var inputLevel: Float = 0

    /// Localized name of the audio device that was actually paired.
    /// nil if no plausible audio device was found.
    private(set) var pairedDeviceName: String?

    private let output = AVCaptureAudioDataOutput()
    private let label: String
    private let queueDispatch: DispatchQueue
    private var receiver: AudioBufferReceiver?

    init(label: String) {
        self.label = label
        self.queueDispatch = DispatchQueue(label: "p10e.camera.audio.\(label)", qos: .userInitiated)
    }

    /// Try to attach a USB audio device matching this camera. Returns
    /// true if found + attached. Caller is responsible for the
    /// session's beginConfiguration/commitConfiguration pair.
    func attach(to session: AVCaptureSession, pairedWith videoDevice: AVCaptureDevice) -> Bool {
        guard let audioDevice = Self.findPairedAudioDevice(for: videoDevice) else {
            P10Logger.log("[CameraAudioCapture:\(label)] no paired audio device for '\(videoDevice.localizedName)'")
            return false
        }
        do {
            let input = try AVCaptureDeviceInput(device: audioDevice)
            guard session.canAddInput(input) else {
                P10Logger.log("[CameraAudioCapture:\(label)] cannot add audio input '\(audioDevice.localizedName)'")
                return false
            }
            session.addInput(input)
            guard session.canAddOutput(output) else {
                P10Logger.log("[CameraAudioCapture:\(label)] cannot add audio output")
                session.removeInput(input)
                return false
            }
            session.addOutput(output)
            let receiver = AudioBufferReceiver(owner: self)
            self.receiver = receiver
            output.setSampleBufferDelegate(receiver, queue: queueDispatch)
            pairedDeviceName = audioDevice.localizedName
            P10Logger.log("[CameraAudioCapture:\(label)] paired audio device '\(audioDevice.localizedName)'")
            return true
        } catch {
            P10Logger.log("[CameraAudioCapture:\(label)] attach failed: \(error)")
            return false
        }
    }

    /// Called from the AVCapture audio thread. Converts the
    /// CMSampleBuffer to an AVAudioPCMBuffer and pushes it onto the
    /// queue, mirroring MicCapture's tap callback behavior.
    fileprivate func receive(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = Self.makePCMBuffer(from: sampleBuffer) else { return }
        queue.push(pcm)
        if let ch0 = pcm.floatChannelData?[0] {
            var sum: Float = 0
            let n = Int(pcm.frameLength)
            for i in 0..<n { sum += ch0[i] * ch0[i] }
            let rms = sqrtf(sum / Float(max(1, n)))
            Task { @MainActor [weak self] in self?.inputLevel = rms }
        }
    }

    /// Convert a CMSampleBuffer (from AVCaptureAudioDataOutput) into
    /// an AVAudioPCMBuffer the appender can mix. Allocates a new
    /// buffer per call; that's fine at audio-buffer rate (~10/s).
    private static func makePCMBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else {
            return nil
        }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0 else { return nil }
        guard let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: format.channelCount, mDataByteSize: 0, mData: nil)
        )
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr,
              let src = audioBufferList.mBuffers.mData else { return nil }
        // Float32 path: copy raw samples in. The capture output gives
        // us whatever the device offers (often Int16); we rely on
        // AudioAppender's downstream AVAudioConverter to handle format
        // mismatch when mixing into the recording's main format.
        if let floatChannels = buffer.floatChannelData {
            let bytesPerSample = Int(format.streamDescription.pointee.mBytesPerFrame) / Int(format.channelCount)
            // Most capture devices give Float32 interleaved or Int16
            // interleaved. The PCM buffer's interleaved-ness comes
            // from the AVAudioFormat we constructed from the ASBD.
            if format.isInterleaved {
                memcpy(floatChannels[0], src, Int(audioBufferList.mBuffers.mDataByteSize))
            } else {
                _ = bytesPerSample
                memcpy(floatChannels[0], src, Int(audioBufferList.mBuffers.mDataByteSize))
            }
        } else if let intChannels = buffer.int16ChannelData {
            memcpy(intChannels[0], src, Int(audioBufferList.mBuffers.mDataByteSize))
        }
        return buffer
    }

    /// Match a USB audio device to the given camera by localized-name
    /// affinity. Most UVC devices report video + audio with similar
    /// names ("Cam Link 4K" + "Cam Link 4K Audio", or shared prefix).
    static func findPairedAudioDevice(for videoDevice: AVCaptureDevice) -> AVCaptureDevice? {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.microphone]
        if #available(iOS 17.0, *) { deviceTypes.append(.external) }
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        let candidates = session.devices
        let videoName = videoDevice.localizedName
        // Skip the iPad's built-in mic — that's MicCapture's territory.
        let external = candidates.filter { $0.uniqueID != "iPad Microphone" && !$0.localizedName.contains("iPad Microphone") }
        // Try exact prefix-match either direction
        if let match = external.first(where: {
            $0.localizedName.hasPrefix(videoName) || videoName.hasPrefix($0.localizedName)
        }) { return match }
        // Fallback: significant common word (first non-trivial token)
        let words = videoName.split(separator: " ").map(String.init).filter { $0.count > 3 }
        for word in words {
            if let match = external.first(where: { $0.localizedName.contains(word) }) {
                return match
            }
        }
        // Last resort: if exactly one non-builtin audio device exists,
        // assume it's paired with the only camera we have.
        return external.count == 1 ? external.first : nil
    }
}

private final class AudioBufferReceiver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    weak var owner: CameraAudioCapture?

    init(owner: CameraAudioCapture) {
        self.owner = owner
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let buffer = sampleBuffer
        Task { @MainActor [weak owner] in
            owner?.receive(buffer)
        }
    }
}
