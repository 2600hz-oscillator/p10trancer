import Foundation

/// Global render-quality knob for the pad preview thumbnails. The
/// actual audio engine + sequencer + AVPlayer playback are NOT
/// affected — only the per-pad on-screen visualizers are scaled
/// back. iPads with a lot of CPU headroom (M2 and up) run fine at
/// `.high`; older devices or future heavy patches may need to drop
/// to `.medium` or `.low` to keep the transport's sequencer ticks
/// firing on cadence.
///
/// `visualizerStride` is the number of PadSystem ticks between
/// expensive visualizer redraws. Stride 1 = every tick; stride 2 =
/// half rate; stride 4 = quarter. Cheap visualizers (the WAVECEL
/// wave3D line trace) honor it; the ACIDKICK 4-band acidwarp pays
/// the highest CPU per redraw so it benefits the most.
enum ThumbnailQuality: Int, CaseIterable, Codable, Identifiable {
    case low = 0
    case medium = 1
    case high = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .low:    return "LOW"
        case .medium: return "MEDIUM"
        case .high:   return "HIGH"
        }
    }

    /// Stride between visualizer redraws. Bigger = lower fps.
    /// Display link runs at 60 Hz, so stride 2 ≈ 30 fps, stride 4
    /// ≈ 15 fps.
    var visualizerStride: Int {
        switch self {
        case .high:   return 1
        case .medium: return 2
        case .low:    return 4
        }
    }

    /// Stride between VideoFileSource pixel-buffer copies. Most of
    /// the time the AVPlayer pipeline emits new buffers slower than
    /// the display link so the inner `hasNewPixelBuffer` check
    /// already throttles us; this just lets `.low` skip every other
    /// check to drop a tiny amount of CPU.
    var videoPixelBufferStride: Int {
        switch self {
        case .high:   return 1
        case .medium: return 1
        case .low:    return 2
        }
    }
}
