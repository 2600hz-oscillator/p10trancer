import Foundation
import Combine

/// Identifies the FX type + instance assigned to one of the bottom-row
/// "FX pad" slots. The three slots are freely assignable to any of
/// `keyer / feedback / xyz`, and the choice persists across saves.
enum FXPadKind: Equatable, Hashable, Codable {
    case keyer(Int)
    case feedback(Int)
    case xyz(Int)

    var displayLabel: String {
        switch self {
        case .keyer(let i): return "KEYER \(i + 1)"
        case .feedback(let i): return "FEEDBACK \(i + 1)"
        case .xyz(let i): return "XYZ \(i + 1)"
        }
    }

    /// ChannelSource equivalent — what gets routed when the user taps
    /// this slot.
    var channelSource: ChannelSource {
        switch self {
        case .keyer(let i): return .keyer(i)
        case .feedback(let i): return .feedback(i)
        case .xyz(let i): return .xyz(i)
        }
    }

    /// LFOTargets slot ID for whichever FX unit this kind refers to.
    /// Used by the slot's per-position LFO to pull the right
    /// targets out of LFOEngine. Computed locally (no MainActor hop
    /// needed) so it's callable from synchronous contexts.
    var underlyingLFOSlotID: String {
        switch self {
        case .keyer(let i): return "keyer-\(i)"
        case .feedback: return "feedback"
        case .xyz(let i): return "xyz-\(i)"
        }
    }
}

@MainActor
final class FXPadSlot: ObservableObject, Identifiable {
    let id: Int
    @Published var kind: FXPadKind {
        didSet {
            guard kind != oldValue else { return }
            onKindChange?(self, oldValue, kind)
        }
    }
    /// Hook for AppState to clear the slot's LFO assignments when
    /// the FX type underneath changes — the new type has different
    /// targets, so persisting old target IDs would silently fail.
    /// LFO shape / rate / amount values stay; only the assignment
    /// target IDs are wiped.
    var onKindChange: ((FXPadSlot, FXPadKind, FXPadKind) -> Void)?

    init(id: Int, kind: FXPadKind) {
        self.id = id
        self.kind = kind
    }

    /// Stable LFO slot ID for THIS pad position (not the underlying
    /// FX unit). The slot owns its own LFOState so the user's wave
    /// shape, rate, etc. persist across kind switches.
    var lfoSlotID: String { "fxslot-\(id)" }
}

/// Holds the three FX-pad slots that occupy the bottom row of the
/// 4×3 grid. Default layout is `[keyer-0, feedback-0, xyz-0]` —
/// one of each FX type. The previous default (`keyer-0, keyer-1,
/// feedback-0`) is no longer used.
@MainActor
final class FXPadSystem: ObservableObject {
    static let slotCount = 3
    let slots: [FXPadSlot]

    init() {
        self.slots = [
            FXPadSlot(id: 0, kind: .keyer(0)),
            FXPadSlot(id: 1, kind: .feedback(0)),
            FXPadSlot(id: 2, kind: .xyz(0))
        ]
    }
}
