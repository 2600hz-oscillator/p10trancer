import SwiftUI

/// Two compact "macro" LFO cards side by side. These are the only
/// LFOs that can target ANY param — including the master mixer
/// position. Per-pad / per-keyer / per-feedback LFOs are scoped to
/// their own params.
///
/// The bar slots into the area between the master preview and the
/// 4×3 pad grid in ContentView. Tapping the gear on either card
/// opens the full LFOSettingsSheet for that macro.
struct MacroLFOBar: View {
    let engine: LFOEngine
    let transport: Transport

    var body: some View {
        HStack(spacing: 8) {
            MacroLFOCard(slotID: LFOTargets.slotID(forMacroIndex: 0),
                         title: "MACRO 1",
                         engine: engine, transport: transport)
            MacroLFOCard(slotID: LFOTargets.slotID(forMacroIndex: 1),
                         title: "MACRO 2",
                         engine: engine, transport: transport)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
            availableTargets: engine.availableTargets(forSlot: slotID),
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
    let availableTargets: [LFOTarget]
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Enable toggle (tap chip)
            Button {
                lfo.enabled.toggle()
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: lfo.enabled ? "circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(lfo.enabled ? .green : .white.opacity(0.4))
                    Text(title)
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white)
                }
                .frame(width: 56)
            }
            .buttonStyle(.plain)

            // Mini realtime waveform preview.
            MacroLFOPreview(lfo: lfo, transport: transport)
                .frame(height: 40)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.04))
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))

            // Rate readout.
            VStack(alignment: .trailing, spacing: 1) {
                Text("RATE")
                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                Text(lfo.rate.displayLabel)
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, alignment: .trailing)

            // Edit / gear.
            Button(action: onEdit) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
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
                let steps = Int(w)
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
                    let playheadPhase = lfo.phase.truncatingRemainder(dividingBy: 1) / cycles
                    let xpos = playheadPhase * w
                    ctx.stroke(
                        Path { p in p.move(to: CGPoint(x: xpos, y: 0)); p.addLine(to: CGPoint(x: xpos, y: h)) },
                        with: .color(.white.opacity(0.4)),
                        lineWidth: 1
                    )
                }
                _ = context.date
            }
        }
    }
}
