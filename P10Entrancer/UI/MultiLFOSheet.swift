import SwiftUI

/// LFO sheet variant for pads that own multiple LFOs (currently only
/// instrument pads, which have 3). Top header + segmented LFO tab
/// picker + the reusable LFOEditor body for the selected LFO.
///
/// Each LFO has its own state in the engine — slot IDs are
/// `pad-N` (LFO 1, for backward compat with the single-LFO setup),
/// `pad-N-lfo-1` (LFO 2), `pad-N-lfo-2` (LFO 3). All three resolve
/// to the same `pad.N.*` target set so any LFO on this pad can
/// drive any of its params.
struct MultiLFOSheet: View {
    let padIndex: Int
    let lfoCount: Int
    @ObservedObject var engine: LFOEngine
    let transport: Transport
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            tabPicker
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            let slotID = slotID(for: selected)
            LFOEditor(lfo: engine.lfo(for: slotID),
                      targets: engine.availableTargets(forSlot: slotID),
                      transport: transport)
                .id(selected)  // force a fresh editor on tab switch
        }
        .background(.black)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("LFOs — PAD \(padIndex + 1)")
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white).tracking(2.0)
            Spacer()
            Button("CLOSE") { dismiss() }
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(0..<lfoCount, id: \.self) { i in
                Button {
                    selected = i
                } label: {
                    Text("LFO \(i + 1)")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .foregroundStyle(selected == i ? .black : .white)
                        .background(selected == i ? Color.white : Color.white.opacity(0.06))
                        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func slotID(for index: Int) -> String {
        LFOTargets.slotID(forPadIndex: padIndex, lfoIndex: index)
    }
}
