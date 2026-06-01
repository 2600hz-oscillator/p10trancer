import SwiftUI

/// Side-strip output-FX panel. The output FX are one set, split across the
/// two side strips by category:
///   • GRADE  — clean HD color grade (gamma / contrast / saturation /
///              brightness / bloom). Always live; identity at its defaults.
///   • ANALOG — the NTSC analog look (chroma / luma / wobble / dropout /
///              noise / comb). Gated by an ON/OFF toggle because the
///              encode→decode roundtrip imparts a look even at neutral
///              knobs and is the expensive pass. Works in any geometry.
///
/// Neither panel is gated by output geometry anymore — geometry only sets
/// the canvas shape/resolution. Both panels are always interactive; state
/// lives on HDPostState / NTSCState, not on the view.
struct OutputFXSidePanel: View {
    enum Mode { case grade, analog }

    let mode: Mode
    @ObservedObject var hdPost: HDPostState
    @ObservedObject var ntsc: NTSCState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch mode {
                    case .grade:  gradeControls
                    case .analog: analogControls
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.04))
        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
    }

    @ViewBuilder
    private var header: some View {
        switch mode {
        case .grade:
            HStack(spacing: 6) {
                Circle().fill(Color.white.opacity(0.5)).frame(width: 7, height: 7)
                Text("GRADE")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
                    .tracking(1.5)
                Spacer()
            }
            .padding(.horizontal, 4)
        case .analog:
            HStack(spacing: 6) {
                Circle()
                    .fill(ntsc.ntscEnabled ? Color.green : Color.white.opacity(0.18))
                    .frame(width: 7, height: 7)
                Text("ANALOG")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
                    .tracking(1.5)
                Spacer()
                Button(action: { ntsc.ntscEnabled.toggle() }) {
                    Text(ntsc.ntscEnabled ? "ON" : "OFF")
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .foregroundStyle(ntsc.ntscEnabled ? .black : .white.opacity(0.6))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ntsc.ntscEnabled ? Color.green : Color.white.opacity(0.08))
                        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
        }
    }

    private var gradeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            knob("Gamma", $hdPost.gamma, in: 0.5...2.5, neutral: 1.0)
            knob("Contrast", $hdPost.contrast, in: 0.5...2.0, neutral: 1.0)
            knob("Saturation", $hdPost.saturation, in: 0...2, neutral: 1.0)
            knob("Brightness", $hdPost.brightness, in: -0.5...0.5, neutral: 0)
            knob("Bloom", $hdPost.bloom, in: 0...1, neutral: 0)
            knob("Bloom thr", $hdPost.bloomThresh, in: 0...1, neutral: 0.75)
        }
    }

    private var analogControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            knob("Chroma", $ntsc.chromaBoost, in: 0...3, neutral: 1.0)
            knob("Luma pk", $ntsc.lumaPeaking, in: 0...3, neutral: 0)
            knob("Comb", $ntsc.combStrength, in: 0...1, neutral: 0.7)
            knob("HSync", $ntsc.hsyncWobble, in: 0...1, neutral: 0)
            knob("Burst", $ntsc.burstPhaseShift, in: -0.5...0.5, neutral: 0)
            knob("Drift", $ntsc.subcarrierDrift, in: 0...0.5, neutral: 0)
            knob("Y/C", $ntsc.ycDelay, in: -8...8, neutral: 0)
            knob("Dropout", $ntsc.dropoutRate, in: 0...1, neutral: 0)
            knob("L noise", $ntsc.lumaNoise, in: 0...0.3, neutral: 0)
            knob("C noise", $ntsc.chromaNoise, in: 0...0.3, neutral: 0)
        }
        .opacity(ntsc.ntscEnabled ? 1.0 : 0.45)
    }

    private func knob(_ label: String,
                      _ binding: Binding<Float>,
                      in range: ClosedRange<Float>,
                      neutral: Float) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(String(format: "%.2f", binding.wrappedValue))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Slider(value: binding, in: range)
                .tint(.white)
                .controlSize(.mini)
        }
    }
}
