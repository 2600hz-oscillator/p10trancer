import SwiftUI
import Combine

/// Vertical side strip holding one macro LFO card. Designed to fill
/// the empty space on either side of the 4×3 pad grid; ContentView
/// places one on the left (macro 1) and one on the right (macro 2).
/// Used to also carry a channel VU meter — that moved to per-pad
/// mini VU bars on the grid, which more directly correlate with the
/// per-pad volume slider the user actually adjusts.
struct MacroSideStrip: View {
    let macroSlotID: String
    let macroTitle: String
    let channelTitle: String
    let channelAccent: Color
    let engine: LFOEngine
    let transport: Transport

    var body: some View {
        // Sized to the macro card's content — no trailing Spacer.
        // The OutputFXSidePanel that ContentView stacks below this
        // claims the rest of the side-strip height.
        MacroLFOCard(slotID: macroSlotID,
                     title: macroTitle,
                     engine: engine,
                     transport: transport)
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
