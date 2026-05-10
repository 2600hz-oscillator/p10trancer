import Foundation
import Combine

/// Single feedback unit's mutable params. The "virtual camera" math:
/// each frame samples the previous frame's output through a (zoom,
/// panX, tiltY) transform and composites with the input source.
/// Zoom > 1 produces the recursive fractal-tunnel effect a real
/// camera sees pointed at its own monitor.
@MainActor
final class FeedbackState: ObservableObject {
    /// Input source — any pad 1-9 or one of the keyers. Self-reference
    /// (.feedback) isn't allowed; the unit always reads its own prior
    /// frame internally for the recursive part.
    @Published var inputSource: SourceRef

    /// Virtual camera zoom. 1.0 = 1:1, >1 = zoom in (tunnel-out feedback),
    /// <1 = zoom out (black border around the source).
    @Published var zoom: Float = 1.05

    /// Horizontal pan in normalized -1…1. 0 = centered.
    @Published var panX: Float = 0

    /// Vertical pan in normalized -1…1. 0 = centered.
    @Published var panY: Float = 0

    /// Camera roll / axis tilt in normalized -1…1, mapped to roughly ±π/2
    /// (90° in either direction) for full sweep. 0 = level.
    @Published var tilt: Float = 0

    /// Per-frame multiplier on the previous frame's contribution. <1 keeps
    /// the loop from blowing out to white. Default 0.96 is "warm" feedback.
    @Published var decay: Float = 0.96

    /// Crossfade between source (0) and feedback (1) per frame. Higher =
    /// more fractal, lower = more "live" with subtle trails.
    @Published var feedbackMix: Float = 0.85

    /// Multiplier applied to the previous-frame sample BEFORE decay. Lets
    /// the user counter the recursive darkening that happens when decay <
    /// 1. Range 0…2; 1.0 is neutral.
    @Published var luminosity: Float = 1.0

    /// Saturation push on the previous-frame sample. Counters chroma loss
    /// from repeated linear sampling. Range 0…3; 1.0 is neutral.
    @Published var chromaBoost: Float = 1.0

    init(inputSource: SourceRef = .pad(0)) {
        self.inputSource = inputSource
    }

    /// Backward-compat shim used by the renderer and session-capture
    /// code that still keys on a pad index. Returns the pad index when
    /// the source is .pad, otherwise nil.
    var sourcePadIndex: Int {
        get {
            if case .pad(let i) = inputSource { return i }
            return 0
        }
        set { inputSource = .pad(newValue) }
    }
}

/// Holds the single feedback unit. Kept as a system rather than a bare
/// state so call sites that loop over units (MIDI, sessions) don't have
/// to special-case a single instance.
@MainActor
final class FeedbackSystem: ObservableObject {
    let units: [FeedbackState]

    init() {
        self.units = [FeedbackState(inputSource: .pad(0))]
    }

    func unit(at index: Int) -> FeedbackState? {
        units.indices.contains(index) ? units[index] : nil
    }
}
