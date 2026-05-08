import Foundation
import Combine

enum KeyerKind: Int, CaseIterable, Identifiable {
    case chroma = 0
    case luma = 1

    var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .chroma: return "Chroma"
        case .luma: return "Luma"
        }
    }
}

/// Single keyer's mutable params. Two instances live in `KeyerSystem`.
/// `isEnabled` is preserved for back-compat with MIDI bindings; the keyer
/// also runs implicitly whenever any pad or channel references it.
@MainActor
final class KeyerState: ObservableObject {
    @Published var isEnabled: Bool = false
    @Published var foregroundPadIndex: Int
    @Published var backgroundPadIndex: Int
    @Published var kind: KeyerKind = .chroma
    @Published var threshold: Float = 0.35
    @Published var softness: Float = 0.1
    @Published var keyColor: SIMD3<Float> = .init(0, 1, 0)

    init(foregroundPadIndex: Int = 7, backgroundPadIndex: Int = 8) {
        self.foregroundPadIndex = foregroundPadIndex
        self.backgroundPadIndex = backgroundPadIndex
    }
}

/// Holds the two independent keyers and exposes them by index. Index 0 = Keyer 1,
/// index 1 = Keyer 2. Same model wherever code needs to look up a keyer by its
/// numeric tag — channel sources, MIDI, UI tabs.
@MainActor
final class KeyerSystem: ObservableObject {
    let keyers: [KeyerState]

    init() {
        self.keyers = [
            KeyerState(foregroundPadIndex: 6, backgroundPadIndex: 7),
            KeyerState(foregroundPadIndex: 7, backgroundPadIndex: 8)
        ]
    }

    func keyer(at index: Int) -> KeyerState? {
        keyers.indices.contains(index) ? keyers[index] : nil
    }
}
