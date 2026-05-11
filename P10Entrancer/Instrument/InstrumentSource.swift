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
    /// Wasp-style state-variable filter (LP/HP/BP, cutoff, res) sits
    /// between the ADSR and the reverb. Tanh-saturated feedback gives
    /// it the Doepfer A-124 character at high resonance.
    let filter: WaspFilter
    /// Stereo reverb applied after synth + ADSR + filter. Lives on
    /// the instrument because the reverb tail is part of the patch
    /// sound, not a master-bus effect.
    let reverb: SimpleReverb
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
    /// Visualizer 3D-space params. `vizZoom` scales the whole stack
    /// around the texture center, `vizRotation` rotates it (in
    /// turns, 0..1 → 0..360°), `vizColorCycle` drives a time-based
    /// HSV hue rotation across non-active frames. 0 keeps the
    /// classic orange-fading look; > 0 ramps up rainbow speed.
    @Published var vizZoom: Float = 1.0
    @Published var vizRotation: Float = 0
    @Published var vizColorCycle: Float = 0

    let audioPlayer: PadAudioPlayer

    private let context: MetalContext
    private var tickCancellable: AnyCancellable?
    private var runStateCancellable: AnyCancellable?
    private var pixelBuffer: [UInt32]
    private let textureWidth = 320
    private let textureHeight = 180
    /// Wall-clock-driven phase used by the visualizer's color cycle
    /// so a non-zero `vizColorCycle` runs even when the transport is
    /// stopped. Computed inside renderWavetableVisualization from
    /// the host CFTimeInterval to avoid a separate timer.
    private var vizStartTime: CFTimeInterval = CACurrentMediaTime()

    init(transport: Transport, context: MetalContext = .shared) {
        self.context = context
        let synth = WaveCelSynth()
        let adsr = ADSREnvelope()
        // Build reverb at the engine's native sample rate so the
        // delay tunings match. A slight mistuning (engine running at
        // 44.1k while we initialize at 48k or vice versa) is
        // inaudible — the reverb is a coloration, not a precise
        // clock — but matching the rate keeps the size knob honest.
        let engineSR = AudioEngine.shared.engine.outputNode.outputFormat(forBus: 0).sampleRate
        let reverb = SimpleReverb(sampleRate: engineSR > 0 ? engineSR : 48000)
        let filter = WaspFilter()
        self.synth = synth
        self.adsr = adsr
        self.filter = filter
        self.reverb = reverb
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
        let renderer = WaveCelSynthRenderer(synth: synth, adsr: adsr,
                                            filter: filter, reverb: reverb)
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
        renderWavetableVisualization()
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

    /// Animated wavetable visualization — a port of WAVECEL's
    /// wave3D card view. Frames are stacked back-to-front in
    /// pseudo-perspective; the active frame (selected by `morph`)
    /// is drawn in white, the rest in orange (or rainbow-cycling
    /// per `vizColorCycle`) fading toward the back. Zoom + rotation
    /// apply a 2D affine transform around the texture center;
    /// rotation is in turns (0..1 → 0..360°).
    private func renderWavetableVisualization() {
        guard let texture = currentTexture else { return }
        let w = textureWidth
        let h = textureHeight
        let bg: UInt32 = 0xFF0A0C11
        for i in 0..<pixelBuffer.count { pixelBuffer[i] = bg }

        let snapshot = synth.tableSnapshot
        let fc = snapshot.frameCount
        guard fc > 0, snapshot.samples.count >= fc * WaveCelSynth.frameSize else {
            uploadTexture(texture)
            return
        }

        let maxFramesDrawn = 24
        let frameStride = max(1, fc / maxFramesDrawn)
        let drawnFrameCount = (fc + frameStride - 1) / frameStride
        let sampleStride = max(1, WaveCelSynth.frameSize / 60)

        let margin = 6
        let drawW = w - margin * 2
        let drawH = h - margin * 2
        let backWidth = Float(drawW) * 0.55
        let frontWidth = Float(drawW) * 0.95
        let totalDepth = Float(drawH) * 0.7
        let yBack = Float(margin) + Float(drawH) * 0.05

        let activeFrame = Int(round(Double(synth.morph) * Double(fc - 1)))
        let activeDrawIndex = activeFrame / frameStride

        // 2D affine snapshot used by the polyline routine.
        let cx = Float(w) * 0.5
        let cy = Float(h) * 0.5
        let zoom = max(0.1, min(4, vizZoom))
        let rotTurns = vizRotation - floor(vizRotation)
        let rotAngle = rotTurns * 2 * .pi
        let cosA = cos(rotAngle)
        let sinA = sin(rotAngle)

        // Hue offset for color cycling. `colorCycle = 0` → no
        // animation; > 0 → rainbow rotation faster as it grows.
        let cycle = max(0, min(1, vizColorCycle))
        let elapsed = CACurrentMediaTime() - vizStartTime
        let hueRotation = Float(elapsed) * cycle * 0.3  // 0.3 turns/s at max

        snapshot.samples.withUnsafeBufferPointer { samples in
            for di in 0..<drawnFrameCount {
                let f = min(di * frameStride, fc - 1)
                let t = drawnFrameCount > 1 ? Float(di) / Float(drawnFrameCount - 1) : 0
                let frameW = backWidth + (frontWidth - backWidth) * t
                let frameY = yBack + totalDepth * t
                let xLeft = Float(margin) + (Float(drawW) - frameW) / 2
                            + Float(drawW) * 0.05 * (t - 0.5) * 2
                let sliceH = Float(drawH) * 0.16 * (0.6 + 0.4 * t)
                let color: UInt32
                let isActive = di == activeDrawIndex
                if isActive {
                    color = 0xFFFFFFFF
                } else if cycle > 0.001 {
                    // Rainbow stripes — each frame gets its own
                    // hue offset, the whole wheel rotates over time.
                    let hueFrac = Float(di) / Float(max(1, drawnFrameCount)) + hueRotation
                    let alpha = 0.25 + 0.7 * t
                    color = packHSV(hueFrac: hueFrac, alpha: alpha)
                } else {
                    let alpha = 0.25 + 0.7 * t
                    color = pack(r: 255, g: 150, b: 40, a: alpha)
                }
                drawFramePolyline(frame: f,
                                  xLeft: xLeft,
                                  frameY: frameY,
                                  frameW: frameW,
                                  sliceH: sliceH,
                                  sampleStride: sampleStride,
                                  samples: samples.baseAddress!,
                                  cx: cx, cy: cy,
                                  zoom: zoom, cosA: cosA, sinA: sinA,
                                  color: color)
            }
        }
        uploadTexture(texture)
    }

    /// HSV→RGB with full saturation and fixed value. Pre-multiplies
    /// alpha against the BG so the visualizer reads correctly at
    /// dim alphas.
    private func packHSV(hueFrac: Float, alpha: Float) -> UInt32 {
        let h = (hueFrac - floor(hueFrac)) * 6  // 0..6
        let i = Int(h)
        let f = h - Float(i)
        let v: Float = 1
        let q = v * (1 - f)
        let qt = v * f
        var r: Float = 0, g: Float = 0, b: Float = 0
        switch i % 6 {
        case 0: r = v;  g = qt; b = 0
        case 1: r = q;  g = v;  b = 0
        case 2: r = 0;  g = v;  b = qt
        case 3: r = 0;  g = q;  b = v
        case 4: r = qt; g = 0;  b = v
        default: r = v; g = 0;  b = q
        }
        return pack(r: Int(r * 255), g: Int(g * 255), b: Int(b * 255), a: alpha)
    }

    /// Pseudo-alpha by blending toward the background. The pad
    /// preview's CPU rasterizer can't do true alpha cheaply, so we
    /// premultiply against the (constant) BG color here.
    private func pack(r: Int, g: Int, b: Int, a: Float) -> UInt32 {
        let bgR = 0x0A, bgG = 0x0C, bgB = 0x11
        let rr = Int(Float(r) * a + Float(bgR) * (1 - a))
        let gg = Int(Float(g) * a + Float(bgG) * (1 - a))
        let bb = Int(Float(b) * a + Float(bgB) * (1 - a))
        return 0xFF000000 | UInt32(rr) << 16 | UInt32(gg) << 8 | UInt32(bb)
    }

    private func drawFramePolyline(frame: Int,
                                   xLeft: Float,
                                   frameY: Float,
                                   frameW: Float,
                                   sliceH: Float,
                                   sampleStride: Int,
                                   samples: UnsafePointer<Float>,
                                   cx: Float, cy: Float,
                                   zoom: Float, cosA: Float, sinA: Float,
                                   color: UInt32) {
        let frameOffset = frame * WaveCelSynth.frameSize
        var prevX: Int = -1
        var prevY: Int = -1
        var s = 0
        while s < WaveCelSynth.frameSize {
            let sample = samples[frameOffset + s]
            let xf = xLeft + (Float(s) / Float(WaveCelSynth.frameSize - 1)) * frameW
            let yf = frameY - sample * sliceH
            // Apply zoom + rotation around the texture center. This
            // moves the whole wave stack in 2D screen space; combined
            // with the existing perspective stacking it reads as a
            // 3D camera tilt + zoom.
            let dx = xf - cx
            let dy = yf - cy
            let rx = dx * cosA - dy * sinA
            let ry = dx * sinA + dy * cosA
            let tx = cx + rx * zoom
            let ty = cy + ry * zoom
            let x = Int(tx.rounded())
            let y = Int(ty.rounded())
            if prevX >= 0 {
                drawLine(x0: prevX, y0: prevY, x1: x, y1: y, color: color)
            }
            prevX = x
            prevY = y
            s += sampleStride
        }
    }

    /// Bresenham-style DDA on the shared pixel buffer. Clipped to
    /// the texture bounds. No anti-aliasing — at 320×180 the
    /// stair-stepping is small enough to read as smooth.
    private func drawLine(x0: Int, y0: Int, x1: Int, y1: Int, color: UInt32) {
        let w = textureWidth
        let h = textureHeight
        let dx = x1 - x0
        let dy = y1 - y0
        let steps = max(abs(dx), abs(dy))
        if steps == 0 {
            if x0 >= 0 && x0 < w && y0 >= 0 && y0 < h {
                pixelBuffer[y0 * w + x0] = color
            }
            return
        }
        let invSteps = 1.0 / Float(steps)
        let xInc = Float(dx) * invSteps
        let yInc = Float(dy) * invSteps
        var fx = Float(x0)
        var fy = Float(y0)
        for _ in 0...steps {
            let x = Int(fx.rounded())
            let y = Int(fy.rounded())
            if x >= 0 && x < w && y >= 0 && y < h {
                pixelBuffer[y * w + x] = color
            }
            fx += xInc
            fy += yInc
        }
    }

    private func uploadTexture(_ texture: MTLTexture) {
        let w = textureWidth
        let h = textureHeight
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
final class WaveCelSynthRenderer: PadStereoRenderer, @unchecked Sendable {
    private let synth: WaveCelSynth
    private let adsr: ADSREnvelope
    private let filter: WaspFilter
    private let reverb: SimpleReverb

    init(synth: WaveCelSynth, adsr: ADSREnvelope,
         filter: WaspFilter, reverb: SimpleReverb) {
        self.synth = synth
        self.adsr = adsr
        self.filter = filter
        self.reverb = reverb
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
        // Filter runs after envelope so the cutoff feels responsive
        // to the dynamics; reverb sits at the tail so it tails out
        // through the filter's color.
        filter.process(left: left, right: right, count: count, sampleRate: sampleRate)
        reverb.process(left: left, right: right, count: count)
    }

    func renderBlock(into out: UnsafeMutablePointer<Float>, count: Int, sampleRate: Double) {
        // Mono entry — used by PadAudioPlayer when the audio path is
        // a mono AVAudioSourceNode. Discard the right channel.
        synth.renderBlock(left: out, right: out, count: count, sampleRate: sampleRate)
        adsr.applyBlock(buffer: out, count: count, sampleRate: sampleRate)
    }
}
