import Foundation
import Metal
import QuartzCore
import Combine

/// MULTIPLATES — a 16-step macro-oscillator instrument. Each step selects a
/// note + a synthesis MODEL (the 14 MacroOscillator engines); harmonics /
/// timbre / morph / level are global macros. A gate envelope shapes notes so
/// rests are silent and tonal models articulate. Built as a sibling of
/// ACIDBASS; visualizer is a cool cyan/violet interference plasma.
@MainActor
final class MultiplatesSource: PadSource, ObservableObject {
    private(set) var currentTexture: MTLTexture?
    let displayAspect: Float = 16.0 / 9.0

    @Published var sequencer = MultiplatesSequencer()
    @Published var isPlaying: Bool = true {
        didSet { if !isPlaying { sequencer.resetPlayhead() } }
    }

    @Published var vizWarpSpeed: Double = 1.0
    @Published var vizHueSpeed: Double = 0.2
    @Published var vizZoom: Double = 1.0
    /// Keyboard octave for note entry (note = (octave+1)*12 + semitone).
    @Published var octave: Int = 3

    let renderer: MultiplatesRenderer
    let audioPlayer: PadAudioPlayer
    var voice: MacroVoice { renderer.voice }

    private let context: MetalContext
    private var tickCancellable: AnyCancellable?
    private var runStateCancellable: AnyCancellable?
    private var pixelBuffer: [UInt32]
    private let textureWidth = 320
    private let textureHeight = 180
    private var startTime: CFTimeInterval = CACurrentMediaTime()
    private var frameCounter = 0
    private let vizPhase = Int.random(in: 0..<8)
    private var tickCount: UInt64 = 0
    /// HOLD-LAST model resolution (MACSEQ policy): a step with no model keeps
    /// the previous step's.
    private var lastModel = 0

    init(transport: Transport, context: MetalContext = .shared) {
        self.context = context
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: textureWidth, height: textureHeight, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        self.currentTexture = context.device.makeTexture(descriptor: descriptor)
        self.pixelBuffer = [UInt32](repeating: 0xFF000000, count: textureWidth * textureHeight)

        let engineSr = AudioEngine.shared.engine.outputNode.outputFormat(forBus: 0).sampleRate
        let voice = MacroVoice(sampleRate: engineSr > 0 ? engineSr : 48000)
        let renderer = MultiplatesRenderer(voice: voice)
        self.renderer = renderer
        self.audioPlayer = PadAudioPlayer(source: .macroSynth(renderer), label: "multiplates")

        sequencer.onStepTrigger = { [weak self] step in
            guard let self else { return }
            if step.enabled {
                let resolved = step.model ?? self.lastModel
                self.lastModel = resolved
                let model = MacroModel(rawValue: resolved) ?? .va
                self.renderer.gate(midiNote: step.note, model: model, on: true)
            } else {
                self.renderer.gate(midiNote: 0, model: .va, on: false)
            }
        }
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
        let stride = max(2, AppState.shared.thumbnailQuality.visualizerStride)
        if (frameCounter + vizPhase) % stride == 0 { renderPlasma() }
    }

    // MARK: - Note entry (shared keyboard)

    func assignNote(stepIndex: Int, semitoneFromC: Int) {
        guard sequencer.steps.indices.contains(stepIndex) else { return }
        sequencer.steps[stepIndex].note = (octave + 1) * 12 + semitoneFromC
        sequencer.steps[stepIndex].enabled = true
    }

    func toggleStep(_ stepIndex: Int) {
        guard sequencer.steps.indices.contains(stepIndex) else { return }
        sequencer.steps[stepIndex].enabled.toggle()
    }

    /// Audition a live note using the current macros + the cursored step's
    /// model (or hold-last), gated briefly.
    func audition(semitoneFromC: Int, stepIndex: Int?) {
        let midi = (octave + 1) * 12 + semitoneFromC
        let modelIdx = (stepIndex.flatMap { sequencer.steps.indices.contains($0) ? sequencer.steps[$0].model : nil }) ?? lastModel
        let model = MacroModel(rawValue: modelIdx) ?? .va
        renderer.gate(midiNote: midi, model: model, on: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            renderer.gate(midiNote: midi, model: model, on: false)
        }
    }

    // MARK: - Visualization

    /// Cool cyan/violet XY-interference plasma — distinct from ACIDKICK's
    /// diagonal bands and ACIDBASS's warm radial rings.
    private func renderPlasma() {
        guard let texture = currentTexture else { return }
        let w = textureWidth, h = textureHeight
        let wall = Float(CACurrentMediaTime() - startTime)
        let t = wall * Float(max(0, vizWarpSpeed))
        let beat = Float(tickCount % 96) / 96.0 * (2.0 * Float.pi)
        let activity = max(0, min(1, renderer.peak() * 3.0))
        let ds = 3
        let dxCount = (w + ds - 1) / ds
        let dyCount = (h + ds - 1) / ds
        let zoom = Float(max(0.1, min(4, vizZoom)))
        let hueDrift = wall * Float(vizHueSpeed)
        let baseHue: Float = 0.55   // cyan anchor

        for by in 0..<dyCount {
            let yPx0 = by * ds
            let yf = Float(yPx0) * 0.06 * zoom
            for bx in 0..<dxCount {
                let xPx0 = bx * ds
                let xf = Float(xPx0) * 0.06 * zoom
                let warp = sinf(xf + t * 1.3) * sinf(yf - t * 1.1)
                         + sinf((xf - yf) * 0.7 + t * 2.0 + beat)
                let hue = baseHue + warp * 0.4 + hueDrift
                let brightness = 0.34 + activity * 0.5 + 0.12 * sinf(warp * 2 + beat)
                let sat = 0.65 + activity * 0.35
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
                            mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: w * 4)
        }
    }

    private func drawScope() {
        let w = textureWidth, h = textureHeight
        let snap = renderer.snapshotRecentSamples()
        guard !snap.isEmpty else { return }
        let midY = h / 2
        let span = h / 2 - 4
        let color = hsvColor(hueFrac: 0.92, brightness: 1, saturation: 0.85)  // magenta trace
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
        let p = v * (1 - s), q = v * (1 - s * f), qt = v * (1 - s * (1 - f))
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

/// Stereo render bridge for MULTIPLATES: a MacroVoice through a gate-driven
/// ADSR (so rests are silent and tonal models articulate). Note/gate events
/// are queued from the main thread and applied at block start on the audio
/// thread; mirrors a recent-samples ring + peak for the visualizer.
final class MultiplatesRenderer: PadStereoRenderer, @unchecked Sendable {
    let voice: MacroVoice
    let adsr = ADSREnvelope()

    private struct GateEvent { let midiNote: Int; let model: MacroModel; let on: Bool }
    private var pending: [GateEvent] = []
    private let eventLock = NSLock()

    static let bufferSize = 1024
    private var recent: [Float]
    private var writeIdx = 0
    private var peakValue: Float = 0
    private let recentLock = NSLock()
    private var scratch: [Float] = []

    // Sidechain trigger publishing.
    var triggerBus: TriggerBus?
    var busPadIndex: Int = -1
    private var scratchPub: [Float] = []

    init(voice: MacroVoice) {
        self.voice = voice
        recent = [Float](repeating: 0, count: Self.bufferSize)
        adsr.attack = 0.005
        adsr.decay = 0.08
        adsr.sustain = 0.85
        adsr.release = 0.12
    }

    func gate(midiNote: Int, model: MacroModel, on: Bool) {
        eventLock.lock()
        pending.append(GateEvent(midiNote: midiNote, model: model, on: on))
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
            if e.on {
                voice.noteOn(midiNote: e.midiNote, model: e.model)
                // Re-articulate each gated step (false→true restarts attack
                // from the current level — no click).
                adsr.setGate(false)
                adsr.setGate(true)
            } else {
                adsr.setGate(false)
            }
        }

        if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
        for i in 0..<count { scratch[i] = Float(voice.nextSample()) }
        scratch.withUnsafeMutableBufferPointer { p in
            adsr.applyBlock(buffer: p.baseAddress!, count: count, sampleRate: sampleRate)
        }

        var blockPeak: Float = 0
        recentLock.lock()
        var idx = writeIdx
        let ring = Self.bufferSize
        for i in 0..<count {
            var s = scratch[i] * 0.8
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

        if let bus = triggerBus, busPadIndex >= 0 {
            if scratchPub.count < count { scratchPub = [Float](repeating: 0, count: count) }
            for i in 0..<count { scratchPub[i] = (left[i] + right[i]) * 0.5 }
            scratchPub.withUnsafeBufferPointer { bus.publish(pad: busPadIndex, samples: $0.baseAddress!, count: count) }
        }
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

    func currentTriggerLevel() -> Float { peak() }
}
