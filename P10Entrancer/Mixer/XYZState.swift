import Foundation
import Combine

/// State for one XYZ unit — a Rutt-Etra-style luma-driven coord
/// remap fused with the SHAPEDRAMPS continuous shape morph. Three
/// instances live in `XYZSystem` so the FX-pad slots can each show a
/// different XYZ if the user wants.
@MainActor
final class XYZState: ObservableObject {
    /// Source video that gets remapped + tinted. Defaults to pad 1.
    @Published var inputSource: SourceRef

    /// Shape morph 0..1: 0=linear, 0.333=triangle, 0.666=soft-fold,
    /// 1=radial. The fragment shader crossfades continuously.
    @Published var xShape: Float = 0
    @Published var yShape: Float = 0

    /// Luma-driven vertex displacement strength. ±1 swings each
    /// sampled scanline vertex by ±0.5 of the screen extent at full
    /// luma. Default yDisp = -0.3 makes bright pixels push UP, giving
    /// the classic "raised terrain" Rutt-Etra look out of the box.
    @Published var xDisp: Float = 0
    @Published var yDisp: Float = -0.3

    /// Output gain + tint. Default intensity 1.5 keeps the lines
    /// from looking too dim with additive blending.
    @Published var intensity: Float = 1.5
    @Published var tintR: Float = 1.0
    @Published var tintG: Float = 1.0
    @Published var tintB: Float = 1.0

    /// Shaped-ramp frequency + phase. Frequency = 1 sweeps the full
    /// screen once; 2 = two sweeps; etc. Phase shifts the sweep.
    @Published var xFreq: Float = 1.0
    @Published var yFreq: Float = 1.0
    @Published var xPhase: Float = 0
    @Published var yPhase: Float = 0

    init(inputSource: SourceRef = .pad(0)) {
        self.inputSource = inputSource
    }
}

@MainActor
final class XYZSystem: ObservableObject {
    let units: [XYZState]
    init() {
        self.units = [XYZState(inputSource: .pad(0))]
    }
    func unit(at i: Int) -> XYZState? { units.indices.contains(i) ? units[i] : nil }
}
