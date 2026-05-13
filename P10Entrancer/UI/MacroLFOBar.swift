import SwiftUI
import Combine

/// Vertical side strip containing one macro LFO card on top and a
/// Winamp-style VU meter for the corresponding output channel
/// below. Designed to fill the empty space on either side of the
/// 4×3 pad grid; ContentView places one on the left (macro 1 / CH1
/// VU) and one on the right (macro 2 / CH2 VU).
struct MacroSideStrip: View {
    let macroSlotID: String
    let macroTitle: String
    let channelTitle: String
    let channelAccent: Color
    let routedPad: PadSlot?
    let engine: LFOEngine
    let transport: Transport

    var body: some View {
        VStack(spacing: 6) {
            MacroLFOCard(slotID: macroSlotID,
                         title: macroTitle,
                         engine: engine,
                         transport: transport)
            ChannelVUMeter(title: channelTitle,
                           accent: channelAccent,
                           pad: routedPad)
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }
}

private struct MacroLFOCard: View {
    let slotID: String
    let title: String
    let engine: LFOEngine
    @ObservedObject var transport: Transport
    @State private var sheet = false

    var body: some View {
        let lfo = engine.lfo(for: slotID)
        MacroLFOCardInner(
            title: title,
            lfo: lfo,
            transport: transport,
            onEdit: { sheet = true }
        )
        .sheet(isPresented: $sheet) {
            LFOSettingsSheet(
                title: title,
                lfo: lfo,
                availableTargets: engine.availableTargets(forSlot: slotID),
                transport: transport
            )
        }
    }
}

private struct MacroLFOCardInner: View {
    let title: String
    @ObservedObject var lfo: LFOState
    @ObservedObject var transport: Transport
    let onEdit: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Button { lfo.enabled.toggle() } label: {
                    Image(systemName: lfo.enabled ? "circle.fill" : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(lfo.enabled ? .green : .white.opacity(0.4))
                }
                .buttonStyle(.plain)
                Text(title)
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: onEdit) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            MacroLFOPreview(lfo: lfo, transport: transport)
                .frame(maxWidth: .infinity)
                .frame(height: 70)
                .background(Color.white.opacity(0.04))
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            HStack {
                Text(lfo.rate.displayLabel)
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.05))
        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
    }
}

private struct MacroLFOPreview: View {
    @ObservedObject var lfo: LFOState
    @ObservedObject var transport: Transport

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                let w = size.width
                let h = size.height
                let midY = h / 2
                ctx.stroke(
                    Path { p in p.move(to: CGPoint(x: 0, y: midY)); p.addLine(to: CGPoint(x: w, y: midY)) },
                    with: .color(.white.opacity(0.15)),
                    lineWidth: 1
                )
                var path = Path()
                let steps = max(1, Int(w))
                let cycles = 2.0
                for i in 0...steps {
                    let x = Double(i) / Double(steps)
                    let phase = x * cycles
                    let s = Double(lfoSample(phase: phase, morph: lfo.morph))
                    let y = midY - s * (h / 2 - 2)
                    let pt = CGPoint(x: x * w, y: y)
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                ctx.stroke(path, with: .color(.cyan), lineWidth: 1.5)
                if transport.isRunning, lfo.enabled {
                    let displayPhase = lfo.phase.truncatingRemainder(dividingBy: 1) / cycles
                    let xpos = displayPhase * w
                    let s = Double(lfoSample(phase: lfo.phase, morph: lfo.morph))
                    let ypos = midY - s * (h / 2 - 2)
                    let radius: CGFloat = 3.5
                    let rect = CGRect(x: xpos - radius, y: ypos - radius,
                                       width: radius * 2, height: radius * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(.white))
                }
                _ = context.date
            }
        }
    }
}

/// Vertical Winamp-style channel VU. Fills bottom-to-top with a
/// green→yellow→red gradient, tracks the routed pad's instantRMS
/// (post per-pad volume + mute, pre master). A small peak marker
/// hangs above the bar and decays slowly so you can see fleeting
/// peaks.
struct ChannelVUMeter: View {
    let title: String
    let accent: Color
    let pad: PadSlot?

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(accent)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(accent.opacity(0.2))
            VUMeterBody(audioPlayer: pad?.audioPlayer)
                .frame(maxWidth: 28)
                .frame(maxHeight: .infinity)
        }
    }
}

private struct VUMeterBody: View {
    @ObservedObject private var observable: PadAudioPlayerOrEmpty

    init(audioPlayer: PadAudioPlayer?) {
        self.observable = PadAudioPlayerOrEmpty(audioPlayer)
    }

    @State private var displayLevel: Float = 0
    @State private var peakLevel: Float = 0
    @State private var peakHoldUntil: Date = .distantPast

    var body: some View {
        // 12 Hz sample rate; the bar is a chunky LED grid, not a
        // waveform — sampling faster just makes single-frame audio
        // spikes flicker the meter without any added information.
        TimelineView(.animation(minimumInterval: 1.0/12.0)) { context in
            VUMeterDraw(level: CGFloat(displayLevel),
                        peak: CGFloat(peakLevel))
                .onChange(of: context.date) { _, now in
                    let target = (observable.player?.instantRMS ?? 0) * 6.0
                    update(to: min(1.0, max(0, target)), now: now)
                }
        }
    }

    private func update(to target: Float, now: Date) {
        // Smoother attack: rather than snapping to peak instantly,
        // pull part-way toward the target. Decay is slower too —
        // a single quiet sample shouldn't drop the meter visibly.
        if target > displayLevel {
            displayLevel = displayLevel + (target - displayLevel) * 0.55
        } else {
            displayLevel = max(0, displayLevel * 0.78)
        }
        if displayLevel >= peakLevel {
            peakLevel = displayLevel
            peakHoldUntil = now.addingTimeInterval(1.0)
        } else if now > peakHoldUntil {
            peakLevel = max(0, peakLevel - 0.02)
        }
    }
}

/// Tiny wrapper so the VU meter can observe whichever pad is
/// currently routed without re-instantiating the view tree when the
/// routing changes. If no pad audio player, instantRMS reads as 0.
@MainActor
private final class PadAudioPlayerOrEmpty: ObservableObject {
    let player: PadAudioPlayer?
    private var cancellable: AnyCancellable?
    init(_ player: PadAudioPlayer?) {
        self.player = player
        if let player {
            cancellable = player.$instantRMS.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }
}

private struct VUMeterDraw: View {
    let level: CGFloat
    let peak: CGFloat

    /// How many discrete segments stack from bottom to top. 16 is a
    /// classic LED-meter density that reads clearly on a tall side
    /// strip.
    private static let segmentCount = 16

    /// LED color at position 0..1 from bottom→top. Dark green at the
    /// floor, bright green by the middle, yellow at ~⅔, then ramps
    /// to bright red at the top — gives the meter a clear "you're
    /// approaching clip" visual ramp instead of a binary green/red.
    private static func segmentColor(at fraction: CGFloat) -> Color {
        let t = max(0, min(1, fraction))
        // Three-stop interpolation: dark-green → yellow → bright-red.
        let darkGreen   = (r: 0.05, g: 0.45, b: 0.08)
        let midYellow   = (r: 0.95, g: 0.92, b: 0.10)
        let brightRed   = (r: 1.00, g: 0.15, b: 0.10)
        let stops: [(pos: Double, c: (r: Double, g: Double, b: Double))] = [
            (0.0, darkGreen), (0.65, midYellow), (1.0, brightRed)
        ]
        for i in 0..<stops.count - 1 {
            let a = stops[i], b = stops[i + 1]
            if Double(t) <= b.pos {
                let span = b.pos - a.pos
                let k = span > 0 ? (Double(t) - a.pos) / span : 0
                return Color(red: a.c.r + (b.c.r - a.c.r) * k,
                             green: a.c.g + (b.c.g - a.c.g) * k,
                             blue: a.c.b + (b.c.b - a.c.b) * k)
            }
        }
        return Color(red: brightRed.r, green: brightRed.g, blue: brightRed.b)
    }

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            // Background frame.
            let outline = CGRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1)
            ctx.fill(Path(outline), with: .color(.black.opacity(0.7)))
            ctx.stroke(Path(outline), with: .color(.white.opacity(0.25)), lineWidth: 1)
            guard h > 4, w > 4 else { return }
            let segGap: CGFloat = 1
            let innerPad: CGFloat = 2
            let usableH = h - innerPad * 2
            let segH = max(1, (usableH - segGap * CGFloat(Self.segmentCount - 1)) / CGFloat(Self.segmentCount))
            let usableW = w - innerPad * 2
            // Segment 0 = bottom, segmentCount-1 = top. Draw bottom-up
            // so segH stacking visually grows upward from the floor.
            for i in 0..<Self.segmentCount {
                let threshold = CGFloat(i + 1) / CGFloat(Self.segmentCount)
                let peakBand = peak >= threshold && peak - threshold < 1.0 / CGFloat(Self.segmentCount)
                let lit = level >= threshold || peakBand
                // Color ramps with position so each segment in the
                // bargraph has its own tint along dark-green→yellow→red.
                let baseColor = Self.segmentColor(at: CGFloat(i) / CGFloat(Self.segmentCount - 1))
                let color = lit ? baseColor : baseColor.opacity(0.22)
                let bottomY = h - innerPad - CGFloat(i) * (segH + segGap)
                let topY = bottomY - segH
                let rect = CGRect(x: innerPad, y: topY, width: usableW, height: segH)
                ctx.fill(Path(rect), with: .color(color))
            }
        }
    }
}
