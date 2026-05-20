import SwiftUI

/// Two-axis touch joystick. Blue circle background with a draggable
/// white dot; the (x, y) of the dot in the circle drives any two
/// LFO-assignable parameters via XYJoystickState.
///
/// The ASSIGN button above the joystick opens a tree-grouped picker
/// where the user binds X and Y to specific targets (per-pad
/// volume, FX params, NTSC / HD-post knobs, keyer/feedback/xyz
/// params, master mixer position, etc.). MIDI CC 70 = X, CC 71 = Y.
struct XYJoystickView: View {
    @ObservedObject var state: XYJoystickState
    let engine: LFOEngine
    @State private var assignSheet = false

    var body: some View {
        VStack(spacing: 6) {
            Button { assignSheet = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10, weight: .bold))
                    Text("ASSIGN")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .tracking(1.0)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55))
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            JoystickPad(state: state)
            assignmentLabels
        }
        .sheet(isPresented: $assignSheet) {
            XYJoystickAssignSheet(state: state, engine: engine)
        }
    }

    private var assignmentLabels: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                Text("X:").font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.cyan)
                Text(displayName(for: state.xTargetID))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            HStack(spacing: 2) {
                Text("Y:").font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.yellow)
                Text(displayName(for: state.yTargetID))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
    }

    private func displayName(for id: String) -> String {
        guard !id.isEmpty else { return "—" }
        return engine.target(id: id)?.displayName ?? id
    }
}

private struct JoystickPad: View {
    @ObservedObject var state: XYJoystickState

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2
            let cx = size / 2
            let cy = size / 2
            let dotR: CGFloat = max(8, size * 0.10)
            let dotX = CGFloat(state.x) * size
            // y flipped — UI top = high y
            let dotY = (1.0 - CGFloat(state.y)) * size
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.18))
                    .overlay(Circle().strokeBorder(Color.blue.opacity(0.7), lineWidth: 2))
                // Crosshair lines so center is visible.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: cy))
                    p.addLine(to: CGPoint(x: size, y: cy))
                    p.move(to: CGPoint(x: cx, y: 0))
                    p.addLine(to: CGPoint(x: cx, y: size))
                }
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                Circle()
                    .fill(Color.white)
                    .frame(width: dotR * 2, height: dotR * 2)
                    .position(x: dotX, y: dotY)
                    .shadow(color: .black.opacity(0.45), radius: 2)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        // Clamp to inside the circle so the dot can't
                        // escape the visual bounds.
                        let dx = drag.location.x - cx
                        let dy = drag.location.y - cy
                        let dist = sqrt(dx*dx + dy*dy)
                        let maxR = radius - dotR
                        let scale = dist > maxR ? maxR / dist : 1.0
                        let clampedX = cx + dx * scale
                        let clampedY = cy + dy * scale
                        let nx = Float(max(0, min(1, clampedX / size)))
                        let ny = Float(max(0, min(1, 1.0 - clampedY / size)))
                        if abs(nx - state.x) > 0.0005 { state.x = nx }
                        if abs(ny - state.y) > 0.0005 { state.y = ny }
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
