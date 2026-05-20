import SwiftUI

/// Side-strip output-FX panel. One renders HD post-processing (gamma /
/// contrast / saturation / brightness / bloom), the other renders the
/// NTSC pipeline knobs (chroma / luma / wobble / dropout / etc.).
///
/// Exclusive activation by current output mode: the panel matching
/// the active mode is interactive, the other is rendered with reduced
/// opacity and hit-testing disabled so the user can still SEE the
/// values but can't move them. Both panels persist their state across
/// mode switches (state lives on HDPostState / NTSCState — not on the
/// view).
struct OutputFXSidePanel: View {
    enum Mode { case hd, ntsc }

    let mode: Mode
    @ObservedObject var mixer: MixerState
    @ObservedObject var hdPost: HDPostState
    @ObservedObject var ntsc: NTSCState

    var body: some View {
        let isActive = (mode == .hd && mixer.outputMode == .hd720p)
                    || (mode == .ntsc && mixer.outputMode == .ntsc4_3)
        VStack(alignment: .leading, spacing: 8) {
            header(isActive: isActive)
            Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch mode {
                    case .hd: hdControls
                    case .ntsc: ntscControls
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.04))
        .overlay(Rectangle().strokeBorder(
            isActive ? Color.white.opacity(0.4) : Color.white.opacity(0.12),
            lineWidth: 1))
        .opacity(isActive ? 1.0 : 0.38)
        .allowsHitTesting(isActive)
    }

    private func header(isActive: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isActive ? Color.green : Color.white.opacity(0.18))
                .frame(width: 7, height: 7)
            Text(headerLabel)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .tracking(1.5)
            Spacer()
            Text(isActive ? "ACTIVE" : "IDLE")
                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                .foregroundStyle(isActive ? .green : .white.opacity(0.4))
        }
        .padding(.horizontal, 4)
    }

    private var headerLabel: String {
        switch mode {
        case .hd: return "HD POST"
        case .ntsc: return "NTSC FX"
        }
    }

    private var hdControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            knob("Gamma", $hdPost.gamma, in: 0.5...2.5, neutral: 1.0)
            knob("Contrast", $hdPost.contrast, in: 0.5...2.0, neutral: 1.0)
            knob("Saturation", $hdPost.saturation, in: 0...2, neutral: 1.0)
            knob("Brightness", $hdPost.brightness, in: -0.5...0.5, neutral: 0)
            knob("Bloom", $hdPost.bloom, in: 0...1, neutral: 0)
            knob("Bloom thr", $hdPost.bloomThresh, in: 0...1, neutral: 0.75)
        }
    }

    private var ntscControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            knob("Chroma", $ntsc.chromaBoost, in: 0...3, neutral: 1.0)
            knob("Luma pk", $ntsc.lumaPeaking, in: 0...3, neutral: 0)
            knob("HSync", $ntsc.hsyncWobble, in: 0...1, neutral: 0)
            knob("Burst", $ntsc.burstPhaseShift, in: -0.5...0.5, neutral: 0)
            knob("Drift", $ntsc.subcarrierDrift, in: 0...0.5, neutral: 0)
            knob("Y/C", $ntsc.ycDelay, in: -8...8, neutral: 0)
            knob("Dropout", $ntsc.dropoutRate, in: 0...1, neutral: 0)
            knob("L noise", $ntsc.lumaNoise, in: 0...0.3, neutral: 0)
            knob("C noise", $ntsc.chromaNoise, in: 0...0.3, neutral: 0)
        }
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
