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

enum OutputMode: Int, CaseIterable, Identifiable {
    case hd720p = 0
    case ntsc4_3 = 1

    var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .hd720p: return "HD"
        case .ntsc4_3: return "NTSC 4:3"
        }
    }
    var canvasSize: (width: Int, height: Int) {
        switch self {
        case .hd720p: return (1280, 720)
        case .ntsc4_3: return (720, 480)
        }
    }
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
    @Published var transition: TransitionKind = .crossfade
    @Published var position: Float = 0
    @Published var keyColor: SIMD3<Float> = .init(0, 1, 0)
    @Published var keyThreshold: Float = 0.35
    @Published var keySoftness: Float = 0.1
    @Published var inspectedPadIndex: Int = 0
    @Published var outputMode: OutputMode = .hd720p
    @Published var masterVolume: Float = 0

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
