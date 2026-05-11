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
    @Published var foregroundSource: SourceRef
    @Published var backgroundSource: SourceRef
    @Published var kind: KeyerKind = .chroma
    /// Chroma: inner chrominance radius (key fully transparent < this).
    /// Luma:   brightness threshold the alpha ramp centers on.
    /// Was named `threshold` historically; kept for LFO-target +
    /// session compatibility.
    @Published var threshold: Float = 0.15
    /// Width of the smooth ramp band. Wider = softer edges; too wide
    /// produces a muddy matte.
    @Published var softness: Float = 0.08
    /// Chroma key color. Default green-screen.
    @Published var keyColor: SIMD3<Float> = .init(0, 1, 0)
    /// Spill suppression strength (chroma key only). 0 = none, 1 =
    /// fully pull edge pixels' chroma toward neutral so the key
    /// color doesn't tint the subject.
    @Published var spill: Float = 0.5
    /// Flip the matte — useful for luma keys where the user wants to
    /// keep the DARK side instead of the bright.
    @Published var invert: Bool = false

    init(foregroundSource: SourceRef = .pad(7), backgroundSource: SourceRef = .pad(8)) {
        self.foregroundSource = foregroundSource
        self.backgroundSource = backgroundSource
    }

    /// Backward-compat shims used by MIDI / sessions that still index
    /// pads as Int. Returns the pad index when the source is .pad,
    /// otherwise the previous (or default) value. Setting always coerces
    /// to .pad(newValue).
    var foregroundPadIndex: Int {
        get {
            if case .pad(let i) = foregroundSource { return i }
            return 0
        }
        set { foregroundSource = .pad(newValue) }
    }

    var backgroundPadIndex: Int {
        get {
            if case .pad(let i) = backgroundSource { return i }
            return 1
        }
        set { backgroundSource = .pad(newValue) }
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
            KeyerState(foregroundSource: .pad(6), backgroundSource: .pad(7)),
            KeyerState(foregroundSource: .pad(7), backgroundSource: .pad(8))
        ]
    }

    func keyer(at index: Int) -> KeyerState? {
        keyers.indices.contains(index) ? keyers[index] : nil
    }
}
