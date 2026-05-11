import Foundation
import Metal
import QuartzCore
import Combine
import AVFoundation

/// A pad whose visual is a 16-step sequencer display and whose audio
/// is a wavetable synth gated by an ADSR. Conforms to PadSource so it
/// drops into the same slot model as video/camera/image sources.
///
/// Owns an internal PadAudioPlayer in synth mode so the pad still
/// exposes the standard volume / mute / route / VU meter surface.
@MainActor
final class InstrumentSource: PadSource, ObservableObject {
    private(set) var currentTexture: MTLTexture?
    let displayAspect: Float = 16.0 / 9.0

    let synth: WavetableSynth
    let adsr: ADSREnvelope
    @Published var sequencer = StepSequencer()
    /// Octave offset for the keyboard UI. Adds 12 × this to whatever
    /// "C-of-the-shown-octave" key the user taps to derive the MIDI
    /// note saved on the step.
    @Published var octave: Int = 4
    /// User-facing wavetable position 0..1 — picks which morph
    /// frame(s) the synth interpolates between.
    @Published var wavePosition: Float = 0 {
        didSet { synth.wavePosition = wavePosition }
    }

    let audioPlayer: PadAudioPlayer

    private let context: MetalContext
    private var tickCancellable: AnyCancellable?
    private var runStateCancellable: AnyCancellable?
    /// CPU buffer for the step grid visual; uploaded into
    /// `currentTexture` each tick. Width × height matches the
    /// allocated MTLTexture below.
    private var pixelBuffer: [UInt32]
    private let textureWidth = 320
    private let textureHeight = 180

    init(transport: Transport, context: MetalContext = .shared) {
        self.context = context
        let synth = WavetableSynth()
        let adsr = ADSREnvelope()
        self.synth = synth
        self.adsr = adsr
        // Allocate visual texture.
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
        // Pad audio player in synth mode. Captures synth + adsr so
        // its render block can drive them.
        self.audioPlayer = PadAudioPlayer(
            source: .synth(WavetableSynthRenderer(synth: synth, adsr: adsr)),
            label: "instrument"
        )
        // Sequencer drives the synth: on each step trigger, retune
        // and gate.
        sequencer.onStepTrigger = { [weak self] step in
            guard let self else { return }
            if step.enabled {
                self.synth.frequencyHz = StepSequencer.frequencyHz(forNote: step.note)
                self.adsr.setGate(true)
            } else {
                self.adsr.setGate(false)
            }
        }
        // Clock subscription: advance one sequencer tick per Transport tick.
        tickCancellable = transport.tickPublisher.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.sequencer.handleTick() }
        }
        // When transport stops, reset playhead so the next start
        // begins at step 1 with no ringing envelope.
        runStateCancellable = transport.$isRunning.sink { [weak self] running in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !running {
                    self.sequencer.resetPlayhead()
                    self.adsr.reset()
                }
            }
        }
    }

    func tick(timestamp: CFTimeInterval) {
        renderStepGrid()
    }

    /// Convenience for the UI: assign a note to a step. The keyboard
    /// view passes a key index 0..11 (semitones from C) and the
    /// instrument applies its current octave.
    func assignNote(stepIndex: Int, semitoneFromC: Int) {
        guard sequencer.steps.indices.contains(stepIndex) else { return }
        let midi = (octave + 1) * 12 + semitoneFromC  // MIDI: C4 = 60
        sequencer.steps[stepIndex].note = midi
        sequencer.steps[stepIndex].enabled = true
    }

    /// Toggle a step on/off — when on, the previously-assigned note
    /// is kept; when off, the step releases on next pass.
    func toggleStep(_ stepIndex: Int) {
        guard sequencer.steps.indices.contains(stepIndex) else { return }
        sequencer.steps[stepIndex].enabled.toggle()
    }

    /// Render the step grid into the shared CPU buffer and push it to
    /// the GPU texture. Cheap enough at 320×180 to do every visual tick.
    private func renderStepGrid() {
        guard let texture = currentTexture else { return }
        let w = textureWidth
        let h = textureHeight
        let bgEmpty: UInt32  = 0xFF101010
        let bgEnabled: UInt32 = 0xFF1E5E1E
        let bgActive: UInt32  = 0xFFE0C840  // current step (highlight)
        let bgActiveOn: UInt32 = 0xFFE03020  // current step + enabled
        let gridLine: UInt32 = 0xFF353535
        // Clear.
        for i in 0..<pixelBuffer.count { pixelBuffer[i] = bgEmpty }
        // 16 steps as horizontal cells.
        let n = StepSequencer.stepCount
        let cellW = w / n
        let padding = 6
        let yTop = padding
        let yBot = h - padding
        for s in 0..<n {
            let xL = s * cellW + 2
            let xR = (s + 1) * cellW - 2
            let isCurrent = s == sequencer.currentStep
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
        // Upload.
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
final class WavetableSynthRenderer: @unchecked Sendable {
    private let synth: WavetableSynth
    private let adsr: ADSREnvelope

    init(synth: WavetableSynth, adsr: ADSREnvelope) {
        self.synth = synth
        self.adsr = adsr
    }

    /// Render `count` mono samples into `out`. Pulls a buffer of
    /// pure wavetable output, then applies the ADSR envelope in-place.
    func renderBlock(into out: UnsafeMutablePointer<Float>, count: Int, sampleRate: Double) {
        synth.renderBlock(into: out, count: count, sampleRate: sampleRate)
        adsr.applyBlock(buffer: out, count: count, sampleRate: sampleRate)
    }
}
