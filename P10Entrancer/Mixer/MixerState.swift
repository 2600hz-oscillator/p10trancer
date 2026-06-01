import Foundation
import Combine

enum ActiveChannel: Int {
    case ch1 = 0
    case ch2 = 1
}

/// A channel can show one of the nine source pads, or it can show the
/// output of one of the three atomic FX pads (KEYER / FEEDBACK / XYZ).
/// There's exactly one of each FX type — no instance index.
enum ChannelSource: Equatable {
    case pad(Int)
    case keyer
    case feedback
    case xyz
}

/// Output aspect ratio. Decoupled from the FX/analog look — geometry only
/// decides the canvas shape. The actual pixel size comes from the
/// per-geometry `OutputResolution` the user picks.
enum OutputGeometry: Int, CaseIterable, Identifiable {
    case ar16_9 = 0
    case ar4_3 = 1

    var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .ar16_9: return "16:9"
        case .ar4_3:  return "4:3"
        }
    }
    /// Logical (square-pixel) aspect used for the composite canvasAspect.
    var aspect: Float {
        switch self {
        case .ar16_9: return 16.0 / 9.0
        case .ar4_3:  return 4.0 / 3.0
        }
    }
}

/// A selectable output resolution. All offered sizes are square-pixel, so
/// width/height matches the geometry's logical aspect exactly.
struct OutputResolution: Equatable, Hashable, Identifiable {
    let width: Int
    let height: Int

    var id: String { "\(width)x\(height)" }
    var label: String { "\(width)×\(height)" }

    static let options4_3: [OutputResolution] = [
        .init(width: 320,  height: 240),
        .init(width: 480,  height: 360),
        .init(width: 640,  height: 480),
        .init(width: 800,  height: 600),
        .init(width: 960,  height: 720),
        .init(width: 1024, height: 768),
        .init(width: 1280, height: 960),
        .init(width: 1440, height: 1080),
    ]
    static let options16_9: [OutputResolution] = [
        .init(width: 426,  height: 240),
        .init(width: 640,  height: 360),
        .init(width: 854,  height: 480),
        .init(width: 1280, height: 720),
        .init(width: 1920, height: 1080),
    ]
    static let default4_3  = OutputResolution(width: 640,  height: 480)
    static let default16_9 = OutputResolution(width: 1280, height: 720)
}

enum TransitionKind: Int, CaseIterable, Identifiable {
    case crossfade = 0
    case linearSwipe = 1
    case starSwipe = 2
    case chromaKey = 3
    case lumaKey = 4

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .crossfade: return "Blur"
        case .linearSwipe: return "Swipe"
        case .starSwipe: return "Star"
        case .chromaKey: return "Chroma"
        case .lumaKey: return "Luma"
        }
    }
}

@MainActor
final class MixerState: ObservableObject {
    @Published var ch1Source: ChannelSource = .pad(0)
    @Published var ch2Source: ChannelSource = .pad(1)
    @Published var activeChannel: ActiveChannel = .ch1
    /// Arming toggles for source reassignment. Both default OFF — tapping
    /// a source pad (or FX pad) only re-routes when at least one of these
    /// is on. Tapping the CH1/CH2 buttons in the bottom bar toggles them.
    @Published var pad1Armed: Bool = false
    @Published var pad2Armed: Bool = false
    @Published var transition: TransitionKind = .crossfade
    @Published var position: Float = 0
    @Published var keyColor: SIMD3<Float> = .init(0, 1, 0)
    @Published var keyThreshold: Float = 0.35
    @Published var keySoftness: Float = 0.1
    @Published var inspectedPadIndex: Int = 0
    /// Output geometry (aspect) + per-geometry pixel resolution. Replaces
    /// the old HD-vs-NTSC OutputMode: geometry is purely the canvas shape,
    /// the analog "NTSC" look is now an independent FX toggle (NTSCState).
    @Published var outputGeometry: OutputGeometry = .ar16_9
    @Published var resolution16_9: OutputResolution = .default16_9
    @Published var resolution4_3: OutputResolution = .default4_3
    @Published var masterVolume: Float = 0

    /// The resolution active for the current geometry.
    var resolution: OutputResolution {
        outputGeometry == .ar4_3 ? resolution4_3 : resolution16_9
    }
    /// The output canvas pixel size — the single source of truth used by
    /// the master mixer, the post pipelines, and the recorder.
    var canvasSize: (width: Int, height: Int) {
        (resolution.width, resolution.height)
    }
    /// Logical canvas aspect (square-pixel ⇒ equals the geometry aspect).
    var canvasAspect: Float { outputGeometry.aspect }

    var ch1PadIndex: Int? {
        if case .pad(let i) = ch1Source { return i } else { return nil }
    }

    var ch2PadIndex: Int? {
        if case .pad(let i) = ch2Source { return i } else { return nil }
    }

    var ch1IsKeyer: Bool { ch1Source == .keyer }
    var ch2IsKeyer: Bool { ch2Source == .keyer }
    var ch1IsFeedback: Bool { ch1Source == .feedback }
    var ch2IsFeedback: Bool { ch2Source == .feedback }
    var ch1IsXYZ: Bool { ch1Source == .xyz }
    var ch2IsXYZ: Bool { ch2Source == .xyz }

    func routeFeedbackTo(_ channel: ActiveChannel) {
        switch channel {
        case .ch1: ch1Source = .feedback
        case .ch2: ch2Source = .feedback
        }
    }

    func routeActivePad(_ index: Int) {
        switch activeChannel {
        case .ch1: ch1Source = .pad(index)
        case .ch2: ch2Source = .pad(index)
        }
    }

    /// Route a source to whichever channels are armed. No-op if neither
    /// is armed — that's the whole point of the arming model.
    @discardableResult
    func routeToArmedChannels(_ source: ChannelSource) -> Bool {
        guard pad1Armed || pad2Armed else { return false }
        if pad1Armed { ch1Source = source }
        if pad2Armed { ch2Source = source }
        return true
    }

    func routeKeyerTo(_ channel: ActiveChannel) {
        switch channel {
        case .ch1: ch1Source = .keyer
        case .ch2: ch2Source = .keyer
        }
    }

    func toggleActiveChannel() {
        activeChannel = (activeChannel == .ch1) ? .ch2 : .ch1
    }
}
