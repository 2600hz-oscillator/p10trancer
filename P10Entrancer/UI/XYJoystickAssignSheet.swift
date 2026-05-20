import SwiftUI

/// Picker for the X/Y joystick. Lists every LFO-assignable target,
/// grouped into expandable sections by source (per-pad, FX units,
/// global). The user picks one target ID for X and one for Y; the
/// joystick writes mapped values into those targets via
/// LFOEngine's setEffective.
struct XYJoystickAssignSheet: View {
    @ObservedObject var state: XYJoystickState
    let engine: LFOEngine
    @Environment(\.dismiss) private var dismiss
    @State private var axis: Axis = .x

    enum Axis: String, CaseIterable, Identifiable {
        case x = "X"
        case y = "Y"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                axisPicker
                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                List {
                    ForEach(groupedTargets, id: \.0) { group, targets in
                        Section(group) {
                            ForEach(targets, id: \.id) { target in
                                row(for: target)
                            }
                        }
                    }
                }
                .listStyle(.grouped)
            }
            .background(.black)
            .preferredColorScheme(.dark)
            .navigationTitle("Assign \(axis.rawValue) Axis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var axisPicker: some View {
        HStack(spacing: 0) {
            ForEach(Axis.allCases) { a in
                let active = axis == a
                Button(action: { axis = a }) {
                    Text("\(a.rawValue) AXIS")
                        .font(.system(size: 13, weight: .heavy, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .foregroundStyle(active ? .black : .white)
                        .background(active ? (a == .x ? Color.cyan : Color.yellow) : Color.white.opacity(0.06))
                        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func row(for target: LFOTarget) -> some View {
        let isSelected = (axis == .x ? state.xTargetID : state.yTargetID) == target.id
        Button(action: {
            switch axis {
            case .x: state.xTargetID = (isSelected ? "" : target.id)
            case .y: state.yTargetID = (isSelected ? "" : target.id)
            }
        }) {
            HStack {
                Text(target.displayName)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(axis == .x ? .cyan : .yellow)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// All LFO targets grouped by their id prefix. Group titles are
    /// human-friendly versions of the prefix.
    private var groupedTargets: [(String, [LFOTarget])] {
        let buckets: [(String, (LFOTarget) -> Bool)] = [
            ("MASTER MIXER", { $0.id.hasPrefix("mixer.") }),
            ("HD POST",       { $0.id.hasPrefix("hd.") }),
            ("NTSC FX",       { $0.id.hasPrefix("ntsc.") }),
            ("KEYER",         { $0.id.hasPrefix("keyer.") }),
            ("FEEDBACK",      { $0.id.hasPrefix("feedback.") }),
            ("XYZ",           { $0.id.hasPrefix("xyz.") }),
        ] + (0..<9).map { i in
            ("PAD \(i + 1)", { $0.id.hasPrefix("pad.\(i).") })
        }
        let all = engine.allTargets
        var result: [(String, [LFOTarget])] = []
        var consumed: Set<String> = []
        for (title, filter) in buckets {
            let matching = all.filter { filter($0) && !consumed.contains($0.id) }
            if !matching.isEmpty {
                result.append((title, matching))
                for t in matching { consumed.insert(t.id) }
            }
        }
        let other = all.filter { !consumed.contains($0.id) }
        if !other.isEmpty {
            result.append(("OTHER", other))
        }
        return result
    }
}
