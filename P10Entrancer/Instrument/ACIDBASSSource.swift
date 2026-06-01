import Foundation
import Metal
import QuartzCore
import Combine

/// ACIDBASS — a 16-step TB-303 bassline pad. A single TB303Voice driven by
/// a BassSequencer (note / accent / slide per step), clocked off the shared
/// transport so it locks to ACIDKICK. Audio flows through the pad's standard
/// stereo strip. Video output is a radial acidwarp plasma in warm TD-3
/// amber→magenta tones — deliberately distinct from ACIDKICK's diagonal
/// red/orange bands — that pulses on the beat and brightens with level.
@MainActor
final class ACIDBASSSource: PadSource, ObservableObject {
    private(set) var currentTexture: MTLTexture?
    let displayAspect: Float = 16.0 / 9.0

    @Published var sequencer = BassSequencer()
    @Published var isPlaying: Bool = true {
        didSet { if !isPlaying { sequencer.resetPlayhead() } }
    }

    /// Background visualizer params (registered as LFO targets).
    @Published var vizWarpSpeed: Double = 1.0   // 0 ... 4
    @Published var vizHueSpeed: Double = 0.2     // 0 ... 1
    @Published var vizZoom: Double = 1.0         // 0.3 ... 2.5 (ring density)

    /// Keyboard octave for note entry (note = (octave+1)*12 + semitone).
    @Published var octave: Int = 2

    let renderer: ACIDBASSRenderer
    let audioPlayer: PadAudioPlayer

    /// The 303 voice — knobs are set from the UI / LFO engine on the main
    /// thread; the audio thread reads (and smooths) them.
    var voice: TB303Voice { renderer.voice }

    private let context: MetalContext
    private var tickCancellable: AnyCancellable?
    private var runStateCancellable: AnyCancellable?
    private var pixelBuffer: [UInt32]
    private let textureWidth = 320
    private let textureHeight = 180
    private var startTime: CFTimeInterval = CACurrentMediaTime()
    private var frameCounter = 0
    /// Per-instance redraw phase so two instrument visualizers never
    /// rasterize on the same frame (spreads the heavy main-thread work).
    private let vizPhase = Int.random(in: 0..<8)
    /// Free-running transport tick count for beat-phase animation.
    private var tickCount: UInt64 = 0
    /// 303 slide model: a note glides IN when the PREVIOUS step had slide set.
    private var lastStepWasSlide = false

    init(transport: Transport, context: MetalContext = .shared) {
        self.context = context
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: textureWidth, height: textureHeight,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        self.currentTexture = context.device.makeTexture(descriptor: descriptor)
        self.pixelBuffer = [UInt32](repeating: 0xFF000000,
                                    count: textureWidth * textureHeight)

        let engineSr = AudioEngine.shared.engine.outputNode.outputFormat(forBus: 0).sampleRate
        let voice = TB303Voice(sampleRate: engineSr > 0 ? engineSr : 48000)
        let renderer = ACIDBASSRenderer(voice: voice)
        self.renderer = renderer
        self.audioPlayer = PadAudioPlayer(source: .bassSynth(renderer), label: "acidbass")

        sequencer.onStepTrigger = { [weak self] step in
            guard let self else { return }
            if step.enabled {
                self.renderer.noteOn(noteCv: BassSequencer.noteCv(forNote: step.note),
                                     accented: step.accent,
                                     glide: self.lastStepWasSlide)
                self.lastStepWasSlide = step.slide
            } else {
                self.renderer.noteOff()
                self.lastStepWasSlide = false
            }
        }
        // Handle inline — see ACIDKICKSource for why the Task hop is gone.
        tickCancellable = transport.tickPublisher.sink { [weak self] _ in
            guard let self else { return }
            self.tickCount &+= 1
            guard self.isPlaying else { return }
            self.sequencer.handleTick()
        }
        runStateCancellable = transport.$isRunning.sink { [weak self] running in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !running { self.sequencer.resetPlayhead() }
            }
        }
    }

    func tick(timestamp: CFTimeInterval) {
        frameCounter &+= 1
        // Floor the stride at 2 (<=30fps) and phase-offset per instance so
        // multiple instrument visualizers don't stack on the same frame and
        // starve the main-thread clock.
        let stride = max(2, AppState.shared.thumbnailQuality.visualizerStride)
        if (frameCounter + vizPhase) % stride == 0 { renderAcidwarpBass() }
    }

    // MARK: - Note entry (shared keyboard)

    /// Record a note into a step and enable it (keyboard with a cursor).
    func assignNote(stepIndex: Int, semitoneFromC: Int) {
        guard sequencer.steps.indices.contains(stepIndex) else { return }
        sequencer.steps[stepIndex].note = (octave + 1) * 12 + semitoneFromC
        sequencer.steps[stepIndex].enabled = true
    }

    func toggleStep(_ stepIndex: Int) {
        guard sequencer.steps.indices.contains(stepIndex) else { return }
        sequencer.steps[stepIndex].enabled.toggle()
    }

    /// Audition a live note (keyboard tapped with no step cursor).
    func audition(semitoneFromC: Int) {
        let midi = (octave + 1) * 12 + semitoneFromC
        renderer.noteOn(noteCv: BassSequencer.noteCv(forNote: midi), accented: false, glide: false)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            renderer.noteOff()
        }
    }

    // MARK: - Visualization

    /// Full-frame radial plasma. Concentric/spiral acid rings driven by a
    /// 3-sinusoid field in polar coords, hue swinging widely through a warm
    /// amber→magenta→lime palette, phase advanced by beat + wall clock so it
    /// pulses on the beat, brightness pumped by output level.
    private func renderAcidwarpBass() {
        guard let texture = currentTexture else { return }
        let w = textureWidth, h = textureHeight
        let wall = Float(CACurrentMediaTime() - startTime)
        let t = wall * Float(max(0, vizWarpSpeed))
        let beatPhase = Float(tickCount % 96) / 96.0 * (2.0 * Float.pi)
        let activity = max(0, min(1, renderer.peak() * 3.0))
        let cx = Float(w) * 0.5
        let cy = Float(h) * 0.5
        let ds = 3
        let dxCount = (w + ds - 1) / ds
        let dyCount = (h + ds - 1) / ds
        let ringDensity = Float(max(0.1, min(4, vizZoom)))
        let hueDrift = wall * Float(vizHueSpeed)
        let baseHue: Float = 0.11   // TD-3 amber anchor

        for by in 0..<dyCount {
            let yPx0 = by * ds
            let yf = Float(yPx0) - cy
            for bx in 0..<dxCount {
                let xPx0 = bx * ds
                let xf = Float(xPx0) - cx
                let r = sqrtf(xf * xf + yf * yf) * 0.045 * ringDensity
                let ang = atan2f(yf, xf)
                let warp = sinf(r * 2.0 - t * 1.6 + beatPhase)
                         + sinf(ang * 3.0 + t * 1.1)
                         + sinf((r * 0.5 + ang) * 2.0 + t * 2.3)
                let hue = baseHue + warp * 0.5 + hueDrift
                let brightness = 0.34 + activity * 0.5 + 0.12 * sinf(warp + beatPhase)
                let sat = 0.7 + activity * 0.3
                let color = hsvColor(hueFrac: hue, brightness: brightness, saturation: sat)
                for dy in 0..<ds {
                    let yPx = yPx0 + dy
                    if yPx >= h { break }
                    let row = yPx * w
                    for dx in 0..<ds {
                        let xPx = xPx0 + dx
                        if xPx < w { pixelBuffer[row + xPx] = color }
                    }
                }
            }
        }

        drawScope()

        pixelBuffer.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, w, h),
                            mipmapLevel: 0,
                            withBytes: bytes.baseAddress!,
                            bytesPerRow: w * 4)
        }
    }

    /// Bass waveform scope across the vertical middle, in a contrasting hue.
    private func drawScope() {
        let w = textureWidth, h = textureHeight
        let snap = renderer.snapshotRecentSamples()
        guard !snap.isEmpty else { return }
        let midY = h / 2
        let span = h / 2 - 4
        let color = hsvColor(hueFrac: 0.5, brightness: 1, saturation: 0.9)  // cyan trace
        var prevX = -1, prevY = -1
        for i in 0..<w {
            let s = snap[i * snap.count / w]
            var y = midY - Int(s * Float(span))
            if y < 0 { y = 0 } else if y >= h { y = h - 1 }
            if prevX >= 0 { drawLine(x0: prevX, y0: prevY, x1: i, y1: y, color: color) }
            prevX = i; prevY = y
        }
    }

    private func drawLine(x0: Int, y0: Int, x1: Int, y1: Int, color: UInt32) {
        let w = textureWidth, h = textureHeight
        let dx = x1 - x0, dy = y1 - y0
        let steps = max(abs(dx), abs(dy))
        if steps == 0 {
            if x0 >= 0 && x0 < w && y0 >= 0 && y0 < h { pixelBuffer[y0 * w + x0] = color }
            return
        }
        let inv = 1.0 / Float(steps)
        var fx = Float(x0), fy = Float(y0)
        let xi = Float(dx) * inv, yi = Float(dy) * inv
        for _ in 0...steps {
            let x = Int(fx.rounded()), y = Int(fy.rounded())
            if x >= 0 && x < w && y >= 0 && y < h { pixelBuffer[y * w + x] = color }
            fx += xi; fy += yi
        }
    }

    private func hsvColor(hueFrac: Float, brightness: Float, saturation: Float = 1) -> UInt32 {
        let hf = hueFrac - floor(hueFrac)
        let hh = hf * 6
        let i = Int(hh)
        let f = hh - Float(i)
        let v = max(0, min(1, brightness))
        let s = max(0, min(1, saturation))
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let qt = v * (1 - s * (1 - f))
        var r: Float = 0, g: Float = 0, b: Float = 0
        switch i % 6 {
        case 0: r = v;  g = qt; b = p
        case 1: r = q;  g = v;  b = p
        case 2: r = p;  g = v;  b = qt
        case 3: r = p;  g = q;  b = v
        case 4: r = qt; g = p;  b = v
        default: r = v; g = p;  b = q
        }
        return 0xFF000000 | UInt32(r * 255) << 16 | UInt32(g * 255) << 8 | UInt32(b * 255)
    }
}

/// Stereo render bridge between PadAudioPlayer's AVAudioSourceNode and the
/// single TB303Voice. Note triggers are queued from the main thread and
/// applied at block start on the audio thread (so the voice's DSP state is
/// only ever touched on the audio thread). Mirrors the live output into a
/// ring buffer + peak for the visualizer / sidechain trigger.
final class ACIDBASSRenderer: PadStereoRenderer, @unchecked Sendable {
    let voice: TB303Voice

    private struct NoteEvent { let noteCv: Double; let accented: Bool; let glide: Bool; let on: Bool }
    private var pending: [NoteEvent] = []
    private let eventLock = NSLock()

    static let bufferSize = 1024
    private var recent: [Float]
    private var writeIdx = 0
    private var peakValue: Float = 0
    private let recentLock = NSLock()

    init(voice: TB303Voice) {
        self.voice = voice
        recent = [Float](repeating: 0, count: Self.bufferSize)
    }

    func noteOn(noteCv: Double, accented: Bool, glide: Bool) {
        eventLock.lock()
        pending.append(NoteEvent(noteCv: noteCv, accented: accented, glide: glide, on: true))
        eventLock.unlock()
    }
    func noteOff() {
        eventLock.lock()
        pending.append(NoteEvent(noteCv: 0, accented: false, glide: false, on: false))
        eventLock.unlock()
    }

    func renderStereoBlock(left: UnsafeMutablePointer<Float>,
                           right: UnsafeMutablePointer<Float>,
                           count: Int,
                           sampleRate: Double) {
        voice.setSampleRate(sampleRate)

        eventLock.lock()
        let events = pending
        pending.removeAll(keepingCapacity: true)
        eventLock.unlock()
        for e in events {
            if e.on { voice.noteOn(noteCv: e.noteCv, accented: e.accented, glide: e.glide) }
            else { voice.noteOff() }
        }

        var blockPeak: Float = 0
        recentLock.lock()
        var idx = writeIdx
        let ring = Self.bufferSize
        for i in 0..<count {
            var s = Float(voice.nextSample()) * 0.8   // headroom
            if s > 1 { s = 1 } else if s < -1 { s = -1 }
            left[i] = s
            right[i] = s
            let a = abs(s)
            if a > blockPeak { blockPeak = a }
            recent[idx] = s
            idx = (idx + 1) % ring
        }
        writeIdx = idx
        peakValue = blockPeak
        recentLock.unlock()
    }

    func snapshotRecentSamples() -> [Float] {
        recentLock.lock(); defer { recentLock.unlock() }
        let n = recent.count
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = recent[(writeIdx + i) % n] }
        return out
    }

    func peak() -> Float {
        recentLock.lock(); defer { recentLock.unlock() }
        return peakValue
    }

    /// Trigger level for when another instrument sidechains TO this pad.
    func currentTriggerLevel() -> Float { peak() }
}
