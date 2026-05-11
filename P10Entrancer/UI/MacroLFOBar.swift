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
        TimelineView(.animation(minimumInterval: 1.0/30.0)) { context in
            VUMeterDraw(level: CGFloat(displayLevel),
                        peak: CGFloat(peakLevel))
                .onChange(of: context.date) { _, now in
                    let target = (observable.player?.instantRMS ?? 0) * 6.0
                    update(to: min(1.0, max(0, target)), now: now)
                }
        }
    }

    private func update(to target: Float, now: Date) {
        if target > displayLevel {
            displayLevel = target  // instant attack
        } else {
            displayLevel = max(0, displayLevel * 0.90)  // exponential decay
        }
        if displayLevel >= peakLevel {
            peakLevel = displayLevel
            peakHoldUntil = now.addingTimeInterval(0.8)
        } else if now > peakHoldUntil {
            peakLevel = max(0, peakLevel - 0.01)  // slow drift down
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

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(.black.opacity(0.5))
                    .overlay(Rectangle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                // Filled bar
                LinearGradient(
                    colors: [.green, .green, .yellow, .red],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(width: w - 2, height: max(0, h * level - 2))
                .offset(y: -1)
                // Peak marker
                if peak > 0.02 {
                    Rectangle()
                        .fill(.white.opacity(0.9))
                        .frame(width: w - 2, height: 2)
                        .offset(y: -(h * peak) + 1)
                }
            }
        }
    }
}
