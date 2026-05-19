import SwiftUI

/// App-wide settings sheet opened from the upper-right gear on the
/// main screen. Three tabs:
///   1. PERFORMANCE — thumbnail quality knob.
///   2. NTSC — sliders for the NTSC pipeline (visible regardless of
///      output mode; the user can configure them before flipping
///      output to NTSC 4:3).
///   3. MIDI — list of connected MIDI sources + live traffic log.
struct GlobalSettingsSheet: View {
    @ObservedObject var appState: AppState
    @ObservedObject var ntsc: NTSCState
    @ObservedObject var router: MIDIRouter
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .performance

    enum Section: String, CaseIterable, Identifiable {
        case performance = "PERFORMANCE"
        case ntsc = "NTSC"
        case midi = "MIDI"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            tabBar
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            ScrollView {
                Group {
                    switch section {
                    case .performance: performanceSection
                    case .ntsc: ntscSection
                    case .midi: midiSection
                    }
                }
                .padding(20)
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("SETTINGS")
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .tracking(2.0)
            Spacer()
            Button("CLOSE") { dismiss() }
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Section.allCases) { s in
                Button(action: { section = s }) {
                    Text(s.rawValue)
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .foregroundStyle(section == s ? .black : .white)
                        .background(section == s ? Color.white : Color.white.opacity(0.06))
                        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Performance

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("THUMBNAIL QUALITY")
            HStack(spacing: 0) {
                ForEach(ThumbnailQuality.allCases) { q in
                    let selected = appState.thumbnailQuality == q
                    Button(action: { appState.thumbnailQuality = q }) {
                        Text(q.label)
                            .font(.system(size: 11, weight: .heavy, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .foregroundStyle(selected ? .black : .white)
                            .background(selected ? Color.white : Color.white.opacity(0.06))
                            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Affects only the per-pad preview render rate. Doesn't change audio or sequencer timing.")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    // MARK: - NTSC

    private var ntscSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("NTSC FX")
            slider("Chroma boost", $ntsc.chromaBoost, in: 0...3)
            slider("Luma peak", $ntsc.lumaPeaking, in: 0...3)
            slider("HSync wobble", $ntsc.hsyncWobble, in: 0...1)
            slider("Burst phase", $ntsc.burstPhaseShift, in: -0.5...0.5)
            slider("Subcarrier drift", $ntsc.subcarrierDrift, in: 0...0.5)
            slider("Y/C delay", $ntsc.ycDelay, in: -8...8)
            slider("Dropout", $ntsc.dropoutRate, in: 0...1)
            slider("Luma noise", $ntsc.lumaNoise, in: 0...0.3)
            slider("Chroma noise", $ntsc.chromaNoise, in: 0...0.3)
            Text("Sliders affect output only when HDMI mode is NTSC 4:3.")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    // MARK: - MIDI

    private var midiSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            connectedDevicesGroup
            trafficGroup
        }
    }

    private var connectedDevicesGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("CONNECTED DEVICES")
            if router.connectedDeviceNames.isEmpty {
                Text("(none)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ForEach(router.connectedDeviceNames, id: \.self) { name in
                    HStack {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text(name)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                }
            }
            Text("Includes any network MIDI peers (Audio MIDI Setup → MIDI Network) plus USB controllers.")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var trafficGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionHeader("LIVE TRAFFIC")
                Spacer()
                Text("\(router.recentEvents.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
            if router.recentEvents.isEmpty {
                Text("Waiting for MIDI…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(router.recentEvents.enumerated()), id: \.offset) { idx, ev in
                        Text(ev)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(idx == 0 ? .white : .white.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.white.opacity(0.03))
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy, design: .monospaced))
            .tracking(2.0)
            .foregroundStyle(.white)
    }

    private func slider(_ label: String, _ binding: Binding<Float>, in range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(String(format: "%.2f", binding.wrappedValue))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
            }
            Slider(value: binding, in: range).tint(.white)
        }
    }
}
