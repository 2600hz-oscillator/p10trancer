import SwiftUI

struct ControlRailView: View {
    let pads: PadSystem
    @ObservedObject var mixer: MixerState
    @ObservedObject var keyer: KeyerState
    @ObservedObject var ntsc: NTSCState
    @ObservedObject var thermal: ThermalMonitor

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("ACTIVE")
                HStack(spacing: 8) {
                    channelButton(channel: .ch1, label: "CH1", tint: .cyan)
                    channelButton(channel: .ch2, label: "CH2", tint: .orange)
                }

                VStack(alignment: .leading, spacing: 4) {
                    channelStatus(label: "CH1", source: mixer.ch1Source, tint: .cyan)
                    channelStatus(label: "CH2", source: mixer.ch2Source, tint: .orange)
                }

                Divider().background(.white.opacity(0.2))

                sectionHeader("TRANSITION")
                Picker("", selection: $mixer.transition) {
                    ForEach(TransitionKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .colorScheme(.dark)

                sectionHeader("POSITION")
                Slider(value: $mixer.position, in: 0...1)
                    .tint(.white)
                Text(String(format: "%.2f", mixer.position))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))

                if mixer.transition == .chromaKey || mixer.transition == .lumaKey {
                    sectionHeader("KEY THRESHOLD")
                    Slider(value: $mixer.keyThreshold, in: 0...1)
                        .tint(.white)
                    sectionHeader("KEY SOFTNESS")
                    Slider(value: $mixer.keySoftness, in: 0.001...0.5)
                        .tint(.white)
                }

                Divider().background(.white.opacity(0.2))

                masterVolumeSection

                Divider().background(.white.opacity(0.2))

                outputModeSection

                if mixer.outputMode == .ntsc4_3 {
                    Divider().background(.white.opacity(0.2))
                    ntscSection
                }

                Divider().background(.white.opacity(0.2))

                keyerSection

                Divider().background(.white.opacity(0.2))

                FXInspectorView(pads: pads, mixer: mixer)

                Divider().background(.white.opacity(0.2))

                thermalIndicator
            }
            .padding(14)
        }
        .frame(maxHeight: .infinity)
        .background(.black)
        .foregroundStyle(.white)
    }

    private var ntscSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("NTSC FX")
            ntscParam(label: "Chroma", value: $ntsc.chromaBoost, range: 0...3, fmt: "%.2fx")
            ntscParam(label: "Luma Peak", value: $ntsc.lumaPeaking, range: 0...3, fmt: "%.2f")
            ntscParam(label: "HSync Wob", value: $ntsc.hsyncWobble, range: 0...1, fmt: "%.2f")
            ntscParam(label: "Burst", value: $ntsc.burstPhaseShift, range: -0.5...0.5, fmt: "%.2f")
            ntscParam(label: "Drift", value: $ntsc.subcarrierDrift, range: 0...0.5, fmt: "%.2f")
            ntscParam(label: "Y/C Delay", value: $ntsc.ycDelay, range: -8...8, fmt: "%.1f")
            ntscParam(label: "Drop", value: $ntsc.dropoutRate, range: 0...1, fmt: "%.2f")
            ntscParam(label: "Y Noise", value: $ntsc.lumaNoise, range: 0...0.3, fmt: "%.2f")
            ntscParam(label: "C Noise", value: $ntsc.chromaNoise, range: 0...0.3, fmt: "%.2f")
        }
    }

    private func ntscParam(label: String, value: Binding<Float>, range: ClosedRange<Float>, fmt: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(String(format: fmt, value.wrappedValue))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Slider(value: value, in: range)
                .tint(.green)
        }
    }

    private var thermalIndicator: some View {
        let color: Color
        switch thermal.indicatorColor {
        case .nominal: color = .green
        case .warm: color = .yellow
        case .hot: color = .orange
        case .critical: color = .red
        }
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("THERMAL \(thermal.label)")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var masterVolumeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("MASTER VOLUME")
            Slider(value: Binding(
                get: { mixer.masterVolume },
                set: { newValue in
                    mixer.masterVolume = newValue
                    AudioEngine.shared.masterVolume = newValue
                }
            ), in: 0...1)
            .tint(.white)
            Text(String(format: "%.2f", mixer.masterVolume))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var outputModeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("HDMI OUT")
            Picker("", selection: $mixer.outputMode) {
                ForEach(OutputMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .colorScheme(.dark)
            let size = mixer.outputMode.canvasSize
            Text("\(size.width) x \(size.height)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var keyerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("KEYER")
                Spacer()
                Toggle("", isOn: $keyer.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
            }
            if keyer.isEnabled {
                padPicker(label: "FG", selection: $keyer.foregroundPadIndex)
                padPicker(label: "BG", selection: $keyer.backgroundPadIndex)

                Picker("", selection: $keyer.kind) {
                    ForEach(KeyerKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .colorScheme(.dark)

                Text("THR \(String(format: "%.2f", keyer.threshold))")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Slider(value: $keyer.threshold, in: 0...1).tint(.white)

                Text("SOFT \(String(format: "%.2f", keyer.softness))")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Slider(value: $keyer.softness, in: 0.001...0.5).tint(.white)

                HStack(spacing: 8) {
                    Button("→ CH1") { mixer.routeKeyerTo(.ch1) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(mixer.ch1IsKeyer ? Color.cyan : Color.white.opacity(0.08))
                        .foregroundStyle(mixer.ch1IsKeyer ? Color.black : Color.white)
                    Button("→ CH2") { mixer.routeKeyerTo(.ch2) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(mixer.ch2IsKeyer ? Color.orange : Color.white.opacity(0.08))
                        .foregroundStyle(mixer.ch2IsKeyer ? Color.black : Color.white)
                }
            }
        }
    }

    private func padPicker(label: String, selection: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 24, alignment: .leading)
            Picker("", selection: selection) {
                ForEach(0..<PadSystem.padCount, id: \.self) { i in
                    Text("\(i + 1)").tag(i)
                }
            }
            .pickerStyle(.segmented)
            .colorScheme(.dark)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
            .tracking(1.5)
    }

    private func channelButton(channel: ActiveChannel, label: String, tint: Color) -> some View {
        let isActive = mixer.activeChannel == channel
        return Button(action: { mixer.activeChannel = channel }) {
            Text(label)
                .font(.system(size: 13, weight: .heavy, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isActive ? tint : Color.white.opacity(0.08))
                .foregroundStyle(isActive ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }

    private func channelStatus(label: String, source: ChannelSource, tint: Color) -> some View {
        let text: String
        switch source {
        case .pad(let i): text = "PAD \(i + 1)"
        case .keyer: text = "KEYER"
        }
        return HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}
