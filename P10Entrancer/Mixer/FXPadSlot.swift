import Foundation
import Combine

/// One of the three fixed FX-pad slots in the bottom row.
/// Slot 0 = Keyer, slot 1 = Feedback, slot 2 = XYZ. The mapping
/// is permanent — the user can't reassign a slot to a different
/// FX type. The gear icon on each slot opens that FX type's
/// settings sheet directly; the waveform icon opens the per-slot LFO.
enum FXPadKind: Equatable, Hashable, Codable {
    case keyer
    case feedback
    case xyz

    var displayLabel: String {
        switch self {
        case .keyer: return "KEYER"
        case .feedback: return "FEEDBACK"
        case .xyz: return "XYZ"
        }
    }

    /// ChannelSource equivalent — what gets routed when the user taps
    /// this slot. Always points at the single canonical unit of that
    /// FX type (index 0).
    var channelSource: ChannelSource {
        switch self {
        case .keyer: return .keyer(0)
        case .feedback: return .feedback(0)
        case .xyz: return .xyz(0)
        }
    }

    /// LFOTargets slot ID for the underlying FX unit. Used by the
    /// per-slot LFO to pull the right targets out of LFOEngine.
    var underlyingLFOSlotID: String {
        switch self {
        case .keyer: return "keyer-0"
        case .feedback: return "feedback"
        case .xyz: return "xyz-0"
        }
    }
}

@MainActor
final class FXPadSlot: ObservableObject, Identifiable {
    let id: Int
    let kind: FXPadKind

    init(id: Int, kind: FXPadKind) {
        self.id = id
        self.kind = kind
    }

    /// Stable LFO slot ID for THIS pad position.
    var lfoSlotID: String { "fxslot-\(id)" }
}

/// Holds the three fixed FX-pad slots that occupy the bottom row:
/// `[KEYER, FEEDBACK, XYZ]`. Order and types are immutable.
@MainActor
final class FXPadSystem: ObservableObject {
    static let slotCount = 3
    let slots: [FXPadSlot]

    init() {
        self.slots = [
            FXPadSlot(id: 0, kind: .keyer),
            FXPadSlot(id: 1, kind: .feedback),
            FXPadSlot(id: 2, kind: .xyz)
        ]
    }
}
