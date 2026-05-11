import Foundation
import Metal
import QuartzCore
import Combine
import AVFoundation

/// A pad whose visual is a 16-step sequencer display and whose audio
/// is a WAVECEL stereo wavetable synth gated by an ADSR. Conforms to
/// PadSource so it drops into the same slot model as video/camera/
/// image sources.
///
/// Owns an internal PadAudioPlayer in synth mode so the pad still
/// exposes the standard volume / mute / route / VU meter surface.
@MainActor
final class InstrumentSource: PadSource, ObservableObject {
    private(set) var currentTexture: MTLTexture?
    let displayAspect: Float = 16.0 / 9.0

    let synth: WaveCelSynth
    let adsr: ADSREnvelope
    @Published var sequencer = StepSequencer()
    /// Drives whether the sequencer advances on ticks. Toggled by the
    /// per-pad play/stop button. When false, the playhead freezes and
    /// the ADSR releases on the next tick (clean cut-off).
    @Published var isPlaying: Bool = true {
        didSet {
            if !isPlaying {
                adsr.setGate(false)
                sequencer.resetPlayhead()
            }
        }
    }
    /// Octave offset applied when the keyboard UI assigns notes.
    /// MIDI octave numbering: C4 = note 60, octave 4.
    @Published var octave: Int = 4
    /// User-visible label of the currently-loaded wavetable. Set when
    /// a new table is loaded; the UI reads this to label the picker.
    @Published var wavetableLabel: String = "DEFAULT"

    let audioPlayer: PadAudioPlayer

    private let context: MetalContext
    private var tickCancellable: AnyCancellable?
    private var runStateCancellable: AnyCancellable?
    private var pixelBuffer: [UInt32]
    private let textureWidth = 320
    private let textureHeight = 180

    init(transport: Transport, context: MetalContext = .shared) {
        self.context = context
        let synth = WaveCelSynth()
        let adsr = ADSREnvelope()
        self.synth = synth
        self.adsr = adsr
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: textureWidth, height: textureHeight,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        self.currentTexture = context.device.makeTexture(descriptor: descriptor)
        self.pixelBuffer = [UInt32](repeating: 0xFF101010,
                                    count: textureWidth * textureHeight)
        let renderer = WaveCelSynthRenderer(synth: synth, adsr: adsr)
        self.audioPlayer = PadAudioPlayer(source: .synth(renderer),
                                           label: "instrument")
        sequencer.onStepTrigger = { [weak self] step in
            guard let self else { return }
            if step.enabled {
                self.synth.frequencyHz = StepSequencer.frequencyHz(forNote: step.note)
                self.adsr.setGate(true)
            } else {
                self.adsr.setGate(false)
            }
        }
        tickCancellable = transport.tickPublisher.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isPlaying else { return }
                self.sequencer.handleTick()
            }
        }
        runStateCancellable = transport.$isRunning.sink { [weak self] running in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !running {
                    self.sequencer.resetPlayhead()
                    self.adsr.reset()
                }
            }
        }
        // Auto-load bundled VOXSYNTH as the default user-facing table.
        if let voxsynth = WaveCelTableLoader.loadBundled("VOXSYNTH") {
            synth.setTable(voxsynth)
            wavetableLabel = voxsynth.label
        }
    }

    func tick(timestamp: CFTimeInterval) {
        renderStepGrid()
    }

    func assignNote(stepIndex: Int, semitoneFromC: Int) {
        guard sequencer.steps.indices.contains(stepIndex) else { return }
        let midi = (octave + 1) * 12 + semitoneFromC
        sequencer.steps[stepIndex].note = midi
        sequencer.steps[stepIndex].enabled = true
    }

    func toggleStep(_ stepIndex: Int) {
        guard sequencer.steps.indices.contains(stepIndex) else { return }
        sequencer.steps[stepIndex].enabled.toggle()
    }

    /// Replace the active wavetable from a parsed table (used by the
    /// Files picker UI). Updates the UI label so the user sees which
    /// table is loaded.
    func loadTable(_ table: WaveCelSynth.Table) {
        synth.setTable(table)
        wavetableLabel = table.label
    }

    private func renderStepGrid() {
        guard let texture = currentTexture else { return }
        let w = textureWidth
        let h = textureHeight
        let bgEmpty: UInt32  = 0xFF101010
        let bgEnabled: UInt32 = 0xFF1E5E1E
        let bgActive: UInt32  = 0xFFE0C840
        let bgActiveOn: UInt32 = 0xFFE03020
        let gridLine: UInt32 = 0xFF353535
        for i in 0..<pixelBuffer.count { pixelBuffer[i] = bgEmpty }
        let n = StepSequencer.stepCount
        let cellW = w / n
        let padding = 6
        let yTop = padding
        let yBot = h - padding
        for s in 0..<n {
            let xL = s * cellW + 2
            let xR = (s + 1) * cellW - 2
            let isCurrent = s == sequencer.currentStep && isPlaying
            let isEnabled = sequencer.steps[s].enabled
            let color: UInt32
            if isCurrent && isEnabled { color = bgActiveOn }
            else if isCurrent         { color = bgActive }
            else if isEnabled         { color = bgEnabled }
            else                      { color = gridLine }
            for y in yTop..<yBot {
                let row = y * w
                for x in xL..<xR {
                    if x >= 0 && x < w { pixelBuffer[row + x] = color }
                }
            }
        }
        pixelBuffer.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, w, h),
                            mipmapLevel: 0,
                            withBytes: bytes.baseAddress!,
                            bytesPerRow: w * 4)
        }
    }
}

/// Real-time render bridge between PadAudioPlayer's AVAudioSourceNode
/// and the InstrumentSource's synth + ADSR. Holds strong references
/// to both so they can't deinit while audio is rendering. Not
/// @MainActor: the render method runs on the audio thread.
///
/// WAVECEL output is stereo. PadAudioPlayer attaches this as a stereo
/// source; the L/R buffers come straight from the synth, the envelope
/// applies to both equally.
final class WaveCelSynthRenderer: @unchecked Sendable {
    private let synth: WaveCelSynth
    private let adsr: ADSREnvelope

    init(synth: WaveCelSynth, adsr: ADSREnvelope) {
        self.synth = synth
        self.adsr = adsr
    }

    /// Render-block scratch for the envelope. Allocated once and
    /// reused across calls — real-time path can't allocate. Capacity
    /// covers the largest expected hardware buffer; AVAudioSourceNode
    /// typically asks for 512..1024 frames.
    private var envScratch = [Float](repeating: 0, count: 4096)

    func renderStereoBlock(left: UnsafeMutablePointer<Float>,
                            right: UnsafeMutablePointer<Float>,
                            count: Int,
                            sampleRate: Double) {
        synth.renderBlock(left: left, right: right,
                          count: count, sampleRate: sampleRate)
        // Render the envelope into the scratch buffer once, then
        // multiply both channels — keeps spread/stereo intact while
        // sharing one envelope instance.
        if envScratch.count < count {
            envScratch = [Float](repeating: 0, count: count)
        }
        envScratch.withUnsafeMutableBufferPointer { scratch in
            adsr.fillEnvelope(into: scratch.baseAddress!,
                              count: count,
                              sampleRate: sampleRate)
            for i in 0..<count {
                left[i] *= scratch[i]
                right[i] *= scratch[i]
            }
        }
    }

    func renderBlock(into out: UnsafeMutablePointer<Float>, count: Int, sampleRate: Double) {
        // Mono entry — used by PadAudioPlayer when the audio path is
        // a mono AVAudioSourceNode. Discard the right channel.
        synth.renderBlock(left: out, right: out, count: count, sampleRate: sampleRate)
        adsr.applyBlock(buffer: out, count: count, sampleRate: sampleRate)
    }
}
