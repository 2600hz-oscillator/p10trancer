import SwiftUI

/// Per-pad FX settings sheet. Opened from the pad's long-press context
/// menu — replaces the old Inspector → FX flow where state was sticky
/// across pad switches (the Inspector re-used SwiftUI views and local
/// @State carried over). This sheet is created fresh per pad per open,
/// so the bindings always reflect that pad's actual effects.
struct PadFXSettingsSheet: View {
    let pad: PadSlot
    let padIndex: Int
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: PadFXSheetModel

    init(pad: PadSlot, padIndex: Int) {
        self.pad = pad
        self.padIndex = padIndex
        _model = StateObject(wrappedValue: PadFXSheetModel(pad: pad))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PAD \(padIndex + 1) — FX")
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white).tracking(2.0)
                Spacer()
                Button("CLOSE") { dismiss() }
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.effects) { vm in
                        effectSection(vm: vm)
                    }
                }
                .padding(20)
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func effectSection(vm: FXEffectVM) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { vm.isEnabled }, set: { vm.setEnabled($0) })) {
                Text(vm.effect.name)
                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .toggleStyle(.switch)
            .tint(.green)

            if vm.isEnabled {
                ForEach(Array(vm.effect.parameters.enumerated()), id: \.offset) { idx, param in
                    paramRow(vm: vm, idx: idx, param: param)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.04))
    }

    private func paramRow(vm: FXEffectVM, idx: Int, param: FXParameter) -> some View {
        let binding = Binding<Float>(
            get: { vm.paramValue(at: idx) },
            set: { vm.setParam(at: idx, value: $0) }
        )
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(param.name)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(String(format: "%.2f", binding.wrappedValue))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Slider(value: binding, in: param.range)
                .tint(.white.opacity(0.85))
        }
    }
}

/// View-model that owns the per-effect enable + param values for one
/// pad's FX chain. Wrapping the bare FXEffect with @Published members
/// gives the sheet a real observable surface to bind against.
@MainActor
final class PadFXSheetModel: ObservableObject {
    let effects: [FXEffectVM]
    init(pad: PadSlot) {
        self.effects = pad.fxChain.effects.map { FXEffectVM(effect: $0) }
    }
}

@MainActor
final class FXEffectVM: ObservableObject, Identifiable {
    let effect: FXEffect
    @Published private(set) var isEnabled: Bool
    @Published private(set) var paramValues: [Float]
    var id: String { effect.name }

    init(effect: FXEffect) {
        self.effect = effect
        self.isEnabled = effect.isEnabled
        self.paramValues = effect.parameters.map { $0.value }
    }

    func setEnabled(_ on: Bool) {
        isEnabled = on
        effect.isEnabled = on
    }

    func paramValue(at i: Int) -> Float {
        i < paramValues.count ? paramValues[i] : 0
    }

    func setParam(at i: Int, value: Float) {
        guard i < paramValues.count, i < effect.parameters.count else { return }
        paramValues[i] = value
        effect.parameters[i].value = value
    }
}
