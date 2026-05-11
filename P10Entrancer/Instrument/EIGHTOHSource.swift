import Foundation
import Metal
import QuartzCore
import Combine
import AVFoundation
import CoreGraphics
import CoreText

/// EIGHTOH — a 4-track × 16-step drum sequencer pad. Each track is
/// assigned one of the four 808-style voices (kick/snare/hat/tom)
/// and contributes its samples to a stereo mix that flows through
/// the pad's standard audio strip. Video output is an acidwarp-
/// style glitch field with a rainbow waveform overlay; a comic-book
/// POW! caption flashes when a kick fires.
@MainActor
final class EIGHTOHSource: PadSource, ObservableObject {
    private(set) var currentTexture: MTLTexture?
    let displayAspect: Float = 16.0 / 9.0

    @Published var sequencer = DrumSequencer()
    @Published var isPlaying: Bool = true {
        didSet {
            if !isPlaying { sequencer.resetPlayhead() }
        }
    }

    /// Mutable voice instances per track. Updating a track's
    /// voiceType swaps the voice object via `regenerateVoices()`.
    private(set) var voices: [DrumVoice]

    let audioPlayer: PadAudioPlayer
    let renderer: EIGHTOHRenderer

    // Visualization state
    private let context: MetalContext
    private var tickCancellable: AnyCancellable?
    private var runStateCancellable: AnyCancellable?
    private var trackChangesCancellable: AnyCancellable?
    private var pixelBuffer: [UInt32]
    private let textureWidth = 320
    private let textureHeight = 180
    /// Pre-rendered POW! caption (BGRA, premultiplied) overlaid
    /// while powExpiry > now.
    private var powBitmap: (pixels: [UInt32], width: Int, height: Int)
    /// Wall-clock time at which the current POW flash should stop
    /// being drawn. -inf = no caption active.
    private var powExpiry: CFTimeInterval = -.infinity
    private let powDurationSec: CFTimeInterval = 0.3
    private var startTime: CFTimeInterval = CACurrentMediaTime()

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
        self.powBitmap = EIGHTOHSource.renderPOWBitmap()
        let initialVoices: [DrumVoice] = [
            KickVoice(), SnareVoice(), HatVoice(), TomVoice()
        ]
        self.voices = initialVoices
        let renderer = EIGHTOHRenderer(voices: initialVoices)
        self.renderer = renderer
        self.audioPlayer = PadAudioPlayer(source: .drumMachine(renderer),
                                           label: "eightoh")

        sequencer.onStepTrigger = { [weak self] firingTracks in
            guard let self else { return }
            for trackIdx in firingTracks {
                guard self.sequencer.tracks.indices.contains(trackIdx) else { continue }
                let track = self.sequencer.tracks[trackIdx]
                self.voices[trackIdx].trigger()
                if track.voiceType == .kick {
                    self.powExpiry = CACurrentMediaTime() + self.powDurationSec
                }
            }
        }
        tickCancellable = transport.tickPublisher.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.sequencer.handleTick()
            }
        }
        runStateCancellable = transport.$isRunning.sink { [weak self] running in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !running { self.sequencer.resetPlayhead() }
            }
        }
        // If the user changes a track's voiceType, rebuild that
        // voice (state isn't transferable across voice types).
        trackChangesCancellable = sequencer.$tracks.sink { [weak self] newTracks in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncVoiceTypes(to: newTracks.map(\.voiceType))
            }
        }
    }

    func tick(timestamp: CFTimeInterval) {
        renderAcidwarp()
    }

    /// Re-create voice objects whose type changed so the new sound
    /// is heard on the next trigger. Voices are stateful so we have
    /// to swap the instance, not just retype.
    private func syncVoiceTypes(to newTypes: [DrumVoiceType]) {
        guard newTypes.count == voices.count else { return }
        var swapped = false
        for i in voices.indices {
            let existing = voices[i]
            let desired = newTypes[i]
            let existingType: DrumVoiceType = {
                switch existing {
                case is KickVoice: return .kick
                case is SnareVoice: return .snare
                case is HatVoice: return .hat
                case is TomVoice: return .tom
                default: return .kick
                }
            }()
            if existingType != desired {
                voices[i] = DrumVoiceFactory.make(type: desired)
                swapped = true
            }
        }
        if swapped { renderer.setVoices(voices) }
    }

    // MARK: - Visualization

    /// Render the acidwarp-style backdrop + rainbow waveform overlay
    /// + (when active) the comic POW caption.
    private func renderAcidwarp() {
        guard let texture = currentTexture else { return }
        let w = textureWidth
        let h = textureHeight
        let t = Float(CACurrentMediaTime() - startTime)
        // Acidwarp background: a sin/cos field downsampled 4× then
        // upscaled, colored from a time-cycling rainbow palette.
        let downsample = 4
        let dw = w / downsample
        let dh = h / downsample
        for by in 0..<dh {
            let yf = Float(by) * 0.18
            let ay = sinf(yf + t * 1.7)
            for bx in 0..<dw {
                let xf = Float(bx) * 0.14
                let ax = cosf(xf + t * 2.1)
                let warp = ax + ay + sinf((xf + yf) * 0.4 + t * 3.0)
                let paletteFrac = (warp * 0.25 + 0.5)
                let hue = paletteFrac + t * 0.1
                let color = hsvColor(hueFrac: hue, brightness: 1)
                let yStart = by * downsample
                let xStart = bx * downsample
                for dy in 0..<downsample {
                    let row = (yStart + dy) * w
                    for dx in 0..<downsample {
                        pixelBuffer[row + xStart + dx] = color
                    }
                }
            }
        }
        // Rainbow waveform overlay: read a snapshot of recent
        // samples and draw a polyline across the middle of the
        // texture with a per-segment hue offset.
        drawWaveformOverlay(t: t)
        // POW flash. Quick scale-in via the remaining time fraction
        // so the caption pops on impact then settles.
        let now = CACurrentMediaTime()
        if now < powExpiry {
            let progress = (powExpiry - now) / powDurationSec  // 1→0
            let scale = Float(1.0 + (progress - 0.5) * 0.4)
            compositePOW(scale: max(0.6, scale), alpha: Float(min(1.0, progress * 2)))
        }
        pixelBuffer.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, w, h),
                            mipmapLevel: 0,
                            withBytes: bytes.baseAddress!,
                            bytesPerRow: w * 4)
        }
    }

    private func drawWaveformOverlay(t: Float) {
        let w = textureWidth
        let h = textureHeight
        let snap = renderer.snapshotRecentSamples()
        guard !snap.isEmpty else { return }
        let midY = h / 2
        let span = h / 3
        var prevX = -1, prevY = -1
        let drawSteps = w
        for i in 0..<drawSteps {
            let sampleIdx = i * snap.count / drawSteps
            let s = snap[sampleIdx]
            let y = midY - Int(s * Float(span))
            let x = i
            let hue = Float(i) / Float(drawSteps) + t * 0.5
            let color = hsvColor(hueFrac: hue, brightness: 1)
            if prevX >= 0 {
                drawLine(x0: prevX, y0: prevY, x1: x, y1: y, color: color)
            }
            prevX = x; prevY = y
        }
    }

    private func compositePOW(scale: Float, alpha: Float) {
        let pw = powBitmap.width
        let ph = powBitmap.height
        let sw = max(1, Int(Float(pw) * scale))
        let sh = max(1, Int(Float(ph) * scale))
        let xOff = (textureWidth - sw) / 2
        let yOff = (textureHeight - sh) / 2
        for py in 0..<sh {
            let srcY = py * ph / sh
            let dstY = yOff + py
            if dstY < 0 || dstY >= textureHeight { continue }
            let dstRow = dstY * textureWidth
            let srcRow = srcY * pw
            for px in 0..<sw {
                let srcX = px * pw / sw
                let dstX = xOff + px
                if dstX < 0 || dstX >= textureWidth { continue }
                let src = powBitmap.pixels[srcRow + srcX]
                let srcA = (src >> 24) & 0xFF
                if srcA == 0 { continue }
                let effA = Float(srcA) / 255 * alpha
                pixelBuffer[dstRow + dstX] = blend(under: pixelBuffer[dstRow + dstX],
                                                   over: src, alpha: effA)
            }
        }
    }

    private func blend(under: UInt32, over: UInt32, alpha: Float) -> UInt32 {
        let a = max(0, min(1, alpha))
        let or = Float((over >> 16) & 0xFF)
        let og = Float((over >>  8) & 0xFF)
        let ob = Float((over      ) & 0xFF)
        let ur = Float((under >> 16) & 0xFF)
        let ug = Float((under >>  8) & 0xFF)
        let ub = Float((under      ) & 0xFF)
        let r = or * a + ur * (1 - a)
        let g = og * a + ug * (1 - a)
        let b = ob * a + ub * (1 - a)
        return 0xFF000000
            | UInt32(r) << 16
            | UInt32(g) << 8
            | UInt32(b)
    }

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

    private func hsvColor(hueFrac: Float, brightness: Float) -> UInt32 {
        let hf = hueFrac - floor(hueFrac)
        let h = hf * 6
        let i = Int(h)
        let f = h - Float(i)
        let v: Float = brightness
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
        return 0xFF000000
            | UInt32(r * 255) << 16
            | UInt32(g * 255) << 8
            | UInt32(b * 255)
    }

    // MARK: - POW bitmap

    /// Pre-render the POW! caption once via CoreGraphics. We use a
    /// chunky black-outlined comic font, set on a transparent canvas.
    /// The bitmap is then composited every visualization tick while
    /// the kick flash is active.
    private static func renderPOWBitmap() -> (pixels: [UInt32], width: Int, height: Int) {
        let w = 220
        let h = 90
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: w * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return ([UInt32](repeating: 0, count: w * h), w, h)
        }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        // Outline. Drawn by stroking white text at large size with a
        // thick line width, then filling with red on top.
        let fontSize: CGFloat = 64
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let yellow = CGColor(red: 1, green: 0.9, blue: 0.2, alpha: 1)
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        let text = "POW!"
        let attrsOutline: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: yellow,
            .strokeColor: black,
            .strokeWidth: -6.0  // negative → fill AND stroke
        ]
        let attr = NSAttributedString(string: text, attributes: attrsOutline)
        let line = CTLineCreateWithAttributedString(attr)
        let bounds = CTLineGetImageBounds(line, ctx)
        let tx = (CGFloat(w) - bounds.width) / 2 - bounds.origin.x
        let ty = (CGFloat(h) - bounds.height) / 2 - bounds.origin.y
        ctx.textPosition = CGPoint(x: tx, y: ty)
        CTLineDraw(line, ctx)

        guard let data = ctx.data else { return ([UInt32](repeating: 0, count: w * h), w, h) }
        let buf = data.bindMemory(to: UInt32.self, capacity: w * h)
        var out = [UInt32](repeating: 0, count: w * h)
        for i in 0..<(w * h) { out[i] = buf[i] }
        return (out, w, h)
    }
}

/// Stereo render bridge between PadAudioPlayer's AVAudioSourceNode
/// and the EIGHTOH voices. Each render block clears the L/R
/// buffers, then asks every voice to renderAdd in turn. Also
/// captures the last frame of mono-mixed samples for the
/// visualizer's waveform overlay (lock-free single writer / single
/// reader via an atomic index).
final class EIGHTOHRenderer: PadStereoRenderer, @unchecked Sendable {
    private var voices: [DrumVoice]
    /// Ring buffer of recent mono samples for the visualizer. 1024
    /// samples ≈ 20 ms @ 48k — enough to trace a clear shape across
    /// the texture.
    private var recentSamples = [Float](repeating: 0, count: 1024)
    private var writeIndex: Int = 0
    private let recentLock = NSLock()  // protects the snapshot read

    init(voices: [DrumVoice]) {
        self.voices = voices
    }

    /// Swap in updated voices (e.g. after a track voiceType change).
    /// Called from the main thread; the audio thread reads `voices`
    /// per render, so this is a write to the array reference that
    /// the audio thread eventually sees.
    func setVoices(_ v: [DrumVoice]) {
        recentLock.lock()
        defer { recentLock.unlock() }
        voices = v
    }

    func renderStereoBlock(left: UnsafeMutablePointer<Float>,
                            right: UnsafeMutablePointer<Float>,
                            count: Int,
                            sampleRate: Double) {
        for i in 0..<count { left[i] = 0; right[i] = 0 }
        recentLock.lock()
        let activeVoices = voices
        recentLock.unlock()
        for voice in activeVoices {
            voice.renderAdd(left: left, right: right, count: count, sampleRate: sampleRate)
        }
        // Soft limit so multiple voices doubling up don't clip.
        for i in 0..<count {
            left[i] = max(-1, min(1, left[i] * 0.7))
            right[i] = max(-1, min(1, right[i] * 0.7))
        }
        // Snapshot into the ring buffer.
        recentLock.lock()
        for i in 0..<count {
            let mono = (left[i] + right[i]) * 0.5
            recentSamples[writeIndex] = mono
            writeIndex = (writeIndex + 1) % recentSamples.count
        }
        recentLock.unlock()
    }

    /// Copy the recent-samples buffer in playback order (oldest →
    /// newest). Called from the main thread by the visualizer.
    func snapshotRecentSamples() -> [Float] {
        recentLock.lock()
        defer { recentLock.unlock() }
        let count = recentSamples.count
        let start = writeIndex
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = recentSamples[(start + i) % count]
        }
        return out
    }
}
