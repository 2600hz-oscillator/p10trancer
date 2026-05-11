import Foundation
import Metal
import QuartzCore
import Combine
import AVFoundation
import CoreGraphics
import CoreText

/// ACIDKICK — a 4-track × 16-step drum sequencer pad. Each track is
/// assigned one of the four 808-style voices (kick/snare/hat/tom)
/// and contributes its samples to a stereo mix that flows through
/// the pad's standard audio strip. Video output is an acidwarp-
/// style glitch field with a rainbow waveform overlay; a comic-book
/// POW! caption flashes when a kick fires.
@MainActor
final class ACIDKICKSource: PadSource, ObservableObject {
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
    let renderer: ACIDKICKRenderer

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
    /// Frame counter for throttling. The visualizer runs every other
    /// PadSystem tick (~30 fps at 60 fps host) — sin/cos-heavy per-cell
    /// shading was the biggest main-thread time sink and 30 fps is
    /// plenty for the chunky-pixel acidwarp aesthetic.
    private var frameCounter: Int = 0

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
        self.powBitmap = ACIDKICKSource.renderPOWBitmap()
        let initialVoices: [DrumVoice] = [
            KickVoice(), SnareVoice(), HatVoice(), TomVoice()
        ]
        self.voices = initialVoices
        let renderer = ACIDKICKRenderer(voices: initialVoices)
        self.renderer = renderer
        self.audioPlayer = PadAudioPlayer(source: .drumMachine(renderer),
                                           label: "acidkick")

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
        // Throttle the visualizer to every other frame. The acidwarp
        // bands cost ~5M trig ops/sec at full rate which competes
        // with SwiftUI layout + transport tick processing on main.
        frameCounter &+= 1
        if frameCounter & 1 == 0 { renderAcidwarp() }
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

    /// Render the visualizer: four horizontal acidwarp bands stacked
    /// top to bottom, one per voice. Each band is tinted by its
    /// voice's signature color (kick = red, snare = orange, hat =
    /// yellow, tom = purple), brightens with that voice's recent
    /// peak amplitude, and shows a scope of that voice's last ~20 ms
    /// of samples overlaid in a complementary hue. POW caption
    /// composites across the whole image when a kick fires.
    private func renderAcidwarp() {
        guard let texture = currentTexture else { return }
        let w = textureWidth
        let h = textureHeight
        let t = Float(CACurrentMediaTime() - startTime)
        let trackCount = DrumSequencer.trackCount
        let bandHeight = h / trackCount
        for band in 0..<trackCount {
            let yStart = band * bandHeight
            let yEnd = (band == trackCount - 1) ? h : (band + 1) * bandHeight
            let voiceType = sequencer.tracks[band].voiceType
            let peak = renderer.peak(voiceIndex: band)
            // Activity 0..1 — light decay so the band stays lit for
            // a beat after the voice fires, then dims back down.
            let activity = max(0, min(1, peak * 3.0))
            let baseHue = Self.bandHue(for: voiceType)
            renderAcidwarpBand(yStart: yStart, yEnd: yEnd,
                                t: t, baseHue: baseHue, activity: activity)
            drawBandScope(yStart: yStart, yEnd: yEnd,
                          voiceIndex: band, baseHue: baseHue, t: t)
        }
        // Thin separator lines between bands so each track reads as
        // its own strip without going full Mondrian.
        for band in 1..<trackCount {
            let y = band * bandHeight
            let row = y * w
            for x in 0..<w { pixelBuffer[row + x] = 0xFF000000 }
        }
        // POW flash on kick.
        let now = CACurrentMediaTime()
        if now < powExpiry {
            let progress = (powExpiry - now) / powDurationSec
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

    /// Per-band acidwarp pattern: sin/cos field downsampled 4× and
    /// rendered as colored chunky cells. `baseHue` ties the palette
    /// to the voice type; `activity` brightens the band when the
    /// voice is firing.
    private func renderAcidwarpBand(yStart: Int, yEnd: Int,
                                     t: Float,
                                     baseHue: Float,
                                     activity: Float) {
        let w = textureWidth
        let downsample = 4
        let dy0 = yStart / downsample
        let dy1 = (yEnd + downsample - 1) / downsample
        let dxCount = w / downsample
        // Band brightness floor: 0.35 at rest, up to 1.0 at peak.
        // Saturation also climbs with activity so quiet bands feel
        // muted and loud ones feel pumped.
        let baseBrightness: Float = 0.35 + activity * 0.6
        let sat: Float = 0.6 + activity * 0.4
        for by in dy0..<dy1 {
            let yf = Float(by) * 0.22
            let ay = sinf(yf + t * 1.7)
            for bx in 0..<dxCount {
                let xf = Float(bx) * 0.18
                let ax = cosf(xf + t * 2.1)
                let warp = ax + ay + sinf((xf + yf) * 0.4 + t * 3.0)
                let palette = warp * 0.18  // tighter swing — keeps the
                                            // hue near baseHue so the
                                            // band reads as "that color"
                let hue = baseHue + palette + t * 0.04
                let color = hsvColor(hueFrac: hue,
                                     brightness: baseBrightness,
                                     saturation: sat)
                let yPxStart = by * downsample
                let xStart = bx * downsample
                for dy in 0..<downsample {
                    let yPx = yPxStart + dy
                    if yPx < yStart || yPx >= yEnd { continue }
                    let row = yPx * w
                    for dx in 0..<downsample {
                        let xPx = xStart + dx
                        if xPx < w { pixelBuffer[row + xPx] = color }
                    }
                }
            }
        }
    }

    /// Draws a polyline of `voiceIndex`'s recent samples inside its
    /// band. Hue offset by ~0.5 from the band's base so the trace
    /// pops against the background.
    private func drawBandScope(yStart: Int, yEnd: Int,
                                voiceIndex: Int,
                                baseHue: Float, t: Float) {
        let w = textureWidth
        let bandH = yEnd - yStart
        let midY = yStart + bandH / 2
        let span = bandH / 2 - 2  // leave a pixel of breathing room
        let snap = renderer.snapshotRecentSamples(voiceIndex: voiceIndex)
        guard !snap.isEmpty else { return }
        let scopeHue = baseHue + 0.5
        let scopeColor = hsvColor(hueFrac: scopeHue + t * 0.3,
                                  brightness: 1, saturation: 1)
        var prevX = -1, prevY = -1
        let drawSteps = w
        for i in 0..<drawSteps {
            let sampleIdx = i * snap.count / drawSteps
            let s = snap[sampleIdx]
            // Clamp y to inside the band so a hot sample can't paint
            // into a neighboring track.
            var y = midY - Int(s * Float(span))
            if y < yStart { y = yStart }
            if y >= yEnd { y = yEnd - 1 }
            let x = i
            if prevX >= 0 {
                drawLine(x0: prevX, y0: prevY, x1: x, y1: y, color: scopeColor)
            }
            prevX = x; prevY = y
        }
    }

    /// Signature hue per drum voice type. Matches the chip colors
    /// in the settings sheet so the visualization and the editor
    /// read consistently.
    private static func bandHue(for type: DrumVoiceType) -> Float {
        switch type {
        case .kick:  return 0.00     // red
        case .snare: return 0.06     // orange
        case .hat:   return 0.14     // yellow
        case .tom:   return 0.78     // purple
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

    /// HSV → RGB packed BGRA. Saturation defaults to 1 so existing
    /// callers (e.g. the POW caption / legacy scope code) keep
    /// their fully-saturated look; band rendering passes a lower
    /// saturation to mute quiet bands.
    private func hsvColor(hueFrac: Float,
                           brightness: Float,
                           saturation: Float = 1) -> UInt32 {
        let hf = hueFrac - floor(hueFrac)
        let h = hf * 6
        let i = Int(h)
        let f = h - Float(i)
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
/// and the ACIDKICK voices. Each render block clears the L/R
/// buffers, asks every voice to renderAdd into a per-voice scratch
/// pair, sums those into the output, then mirrors each voice's mono
/// scratch into its own ring buffer so the visualizer can draw one
/// band per voice.
final class ACIDKICKRenderer: PadStereoRenderer, @unchecked Sendable {
    private var voices: [DrumVoice]
    /// Per-voice ring buffers of recent mono samples. 1024 samples ≈
    /// 20 ms @ 48k — enough for a clean scope trace across the
    /// texture width. One buffer per track so the 4-band visualizer
    /// can render each voice independently.
    private var perVoiceSamples: [[Float]]
    private var perVoiceWriteIdx: [Int]
    /// Latest peak amplitude per voice (max abs sample seen in the
    /// most recent render block). The visualizer reads this to
    /// brighten a band when its voice is firing.
    private var perVoicePeak: [Float]
    /// Scratch buffers reused across renders so the audio thread
    /// never allocates. Sized lazily up to the largest buffer the
    /// engine ever asks for.
    private var scratchL: [Float] = []
    private var scratchR: [Float] = []
    private let recentLock = NSLock()

    static let bufferSize = 1024

    init(voices: [DrumVoice]) {
        self.voices = voices
        let n = voices.count
        self.perVoiceSamples = (0..<n).map { _ in
            [Float](repeating: 0, count: Self.bufferSize)
        }
        self.perVoiceWriteIdx = [Int](repeating: 0, count: n)
        self.perVoicePeak = [Float](repeating: 0, count: n)
    }

    /// Swap in updated voices (e.g. after a track voiceType change).
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
        // Grow scratch if the engine asked for a bigger buffer than
        // we've seen before — done outside the lock since the array
        // mutation is one-time at this size.
        if scratchL.count < count {
            scratchL = [Float](repeating: 0, count: count)
            scratchR = [Float](repeating: 0, count: count)
        }
        recentLock.lock()
        let activeVoices = voices
        recentLock.unlock()
        recentLock.lock()
        for vi in activeVoices.indices {
            for i in 0..<count { scratchL[i] = 0; scratchR[i] = 0 }
            scratchL.withUnsafeMutableBufferPointer { lp in
                scratchR.withUnsafeMutableBufferPointer { rp in
                    activeVoices[vi].renderAdd(left: lp.baseAddress!,
                                                right: rp.baseAddress!,
                                                count: count,
                                                sampleRate: sampleRate)
                }
            }
            var peak: Float = 0
            // Accumulate into the master mix and stash the mono
            // scratch into the per-voice ring buffer for the band
            // viz to consume.
            if perVoiceSamples.indices.contains(vi) {
                var idx = perVoiceWriteIdx[vi]
                let ring = Self.bufferSize
                for i in 0..<count {
                    let l = scratchL[i]
                    let r = scratchR[i]
                    let mono = (l + r) * 0.5
                    if abs(mono) > peak { peak = abs(mono) }
                    perVoiceSamples[vi][idx] = mono
                    idx = (idx + 1) % ring
                    left[i] += l
                    right[i] += r
                }
                perVoiceWriteIdx[vi] = idx
                perVoicePeak[vi] = peak
            } else {
                for i in 0..<count {
                    left[i] += scratchL[i]
                    right[i] += scratchR[i]
                }
            }
        }
        recentLock.unlock()
        // Soft limit so multiple voices doubling up don't clip.
        for i in 0..<count {
            left[i] = max(-1, min(1, left[i] * 0.7))
            right[i] = max(-1, min(1, right[i] * 0.7))
        }
    }

    /// Copy a voice's ring buffer in playback order (oldest →
    /// newest). Called from the main thread.
    func snapshotRecentSamples(voiceIndex: Int) -> [Float] {
        recentLock.lock()
        defer { recentLock.unlock() }
        guard perVoiceSamples.indices.contains(voiceIndex) else { return [] }
        let buffer = perVoiceSamples[voiceIndex]
        let start = perVoiceWriteIdx[voiceIndex]
        let n = buffer.count
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = buffer[(start + i) % n] }
        return out
    }

    /// Current per-voice peak — the visualizer brightens its band
    /// proportionally to this. Cheap read, no buffer copy.
    func peak(voiceIndex: Int) -> Float {
        recentLock.lock()
        defer { recentLock.unlock() }
        guard perVoicePeak.indices.contains(voiceIndex) else { return 0 }
        return perVoicePeak[voiceIndex]
    }
}
