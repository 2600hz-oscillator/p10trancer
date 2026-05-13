import SwiftUI

/// Per-slot LFO config: wave morph + rate + 3 assignment slots.
/// Same sheet used for source pads, keyer pads, and the feedback pad.
struct LFOSettingsSheet: View {
    let title: String
    @ObservedObject var lfo: LFOState
    /// Allowed assignment targets for THIS LFO. Per-pad / per-keyer /
    /// per-feedback LFOs see only their own params; macro LFOs see
    /// the full pool including the master mixer position.
    let availableTargets: [LFOTarget]
    let transport: Transport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            LFOEditor(lfo: lfo, targets: availableTargets, transport: transport)
        }
        .background(.black)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("LFO — \(title)")
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white).tracking(2.0)
            Spacer()
            Button("CLOSE") { dismiss() }
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

}

/// Reusable LFO editor body — enable / shape / rate / 3 assignment
/// slots. Extracted from LFOSettingsSheet so it can be embedded in
/// the multi-LFO tab UI used by instrument pads.
struct LFOEditor: View {
    @ObservedObject var lfo: LFOState
    let targets: [LFOTarget]
    let transport: Transport

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                enableRow
                shapeRow
                rateRow
                assignSection
            }
            .padding(20)
        }
    }

    private var enableRow: some View {
        Toggle(isOn: $lfo.enabled) {
            Text("ENABLED")
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
        }
        .tint(.green)
    }

    private var shapeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SHAPE")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                Text(shapeName(for: lfo.morph))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
            LFOWaveformPreview(lfo: lfo, transport: transport)
                .frame(height: 80)
                .background(Color.white.opacity(0.04))
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
            HStack {
                Text("sine").font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                Slider(value: $lfo.morph, in: 0...1).tint(.white)
                Text("square").font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func shapeName(for morph: Float) -> String {
        let m = max(0, min(1, morph))
        if m < 0.05 { return "sine" }
        if m > 0.95 { return "square" }
        if abs(m - 0.5) < 0.05 { return "saw" }
        if m < 0.5 { return "sine↔saw \(Int(m * 200))%" }
        return "saw↔square \(Int((m - 0.5) * 200))%"
    }

    private var rateRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("RATE")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                Text(lfo.rate.displayLabel)
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: 0) {
                ForEach(LFORate.allCases) { rate in
                    Button(action: { lfo.rate = rate }) {
                        Text(rate.displayLabel)
                            .font(.system(size: 10, weight: .heavy, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .foregroundStyle(lfo.rate == rate ? .black : .white)
                            .background(lfo.rate == rate ? Color.white : Color.white.opacity(0.06))
                            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var assignSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ASSIGN — up to 3 targets")
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
            ForEach(0..<3, id: \.self) { i in
                LFOAssignRow(
                    slotIndex: i,
                    assignment: Binding(
                        get: { lfo.assignments[i] },
                        set: { lfo.assignments[i] = $0 }
                    ),
                    targets: targets
                )
            }
        }
    }
}

private struct LFOAssignRow: View {
    let slotIndex: Int
    @Binding var assignment: LFOAssignment
    let targets: [LFOTarget]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("#\(slotIndex + 1)")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Menu {
                    Button("— none —") { assignment.targetID = "" }
                    Divider()
                    ForEach(targets) { target in
                        Button(target.displayName) { assignment.targetID = target.id }
                    }
                } label: {
                    HStack {
                        Text(currentLabel)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.06))
                    .overlay(Rectangle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                }
            }
            HStack {
                Text("AMT")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Slider(value: $assignment.amount, in: 0...1).tint(.cyan)
                Text("\(Int(assignment.amount * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 42, alignment: .trailing)
            }
            .opacity(assignment.targetID.isEmpty ? 0.3 : 1.0)
            .disabled(assignment.targetID.isEmpty)
        }
    }

    private var currentLabel: String {
        if assignment.targetID.isEmpty { return "— pick a target —" }
        return targets.first(where: { $0.id == assignment.targetID })?.displayName
            ?? assignment.targetID
    }
}

/// Live preview canvas: draws the LFO's shape across the width and
/// animates a playhead at the current phase. Uses TimelineView so it
/// repaints at the display's refresh rate without the engine having
/// to poke it.
private struct LFOWaveformPreview: View {
    @ObservedObject var lfo: LFOState
    @ObservedObject var transport: Transport

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                let w = size.width
                let h = size.height
                let midY = h / 2
                // Background centerline.
                ctx.stroke(
                    Path { p in p.move(to: CGPoint(x: 0, y: midY)); p.addLine(to: CGPoint(x: w, y: midY)) },
                    with: .color(.white.opacity(0.2)),
                    lineWidth: 1
                )
                // Wave: 2 full cycles across the canvas so the morph
                // and the playhead positioning are obvious.
                let cycles = 2.0
                var path = Path()
                let steps = Int(w)
                for i in 0...steps {
                    let x = Double(i) / Double(steps)
                    let phase = x * cycles
                    let s = Double(lfoSample(phase: phase, morph: lfo.morph))
                    let y = midY - s * (h / 2 - 4)
                    let pt = CGPoint(x: x * w, y: y)
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                ctx.stroke(path, with: .color(.cyan), lineWidth: 2)
                // Animated dot riding the waveform at the LFO's current
                // phase (only while transport is running + LFO enabled).
                if transport.isRunning, lfo.enabled {
                    let displayPhase = lfo.phase.truncatingRemainder(dividingBy: 1) / cycles
                    let xpos = displayPhase * w
                    let s = Double(lfoSample(phase: lfo.phase, morph: lfo.morph))
                    let ypos = midY - s * (h / 2 - 4)
                    let radius: CGFloat = 5
                    let rect = CGRect(x: xpos - radius, y: ypos - radius,
                                       width: radius * 2, height: radius * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(.white))
                    ctx.stroke(Path(ellipseIn: rect),
                                with: .color(.cyan),
                                lineWidth: 1.5)
                }
                _ = context.date // keep TimelineView animating
            }
        }
    }
}
