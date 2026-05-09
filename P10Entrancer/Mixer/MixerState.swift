import Foundation
import Combine

enum ActiveChannel: Int {
    case ch1 = 0
    case ch2 = 1
}

enum ChannelSource: Equatable {
    case pad(Int)
    case keyer(Int)    // 0 = Keyer 1, 1 = Keyer 2
    case feedback(Int) // 0 = FB 1, 1 = FB 2
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

    var ch1KeyerIndex: Int? {
        if case .keyer(let i) = ch1Source { return i } else { return nil }
    }

    var ch2KeyerIndex: Int? {
        if case .keyer(let i) = ch2Source { return i } else { return nil }
    }

    var ch1FeedbackIndex: Int? {
        if case .feedback(let i) = ch1Source { return i } else { return nil }
    }

    var ch2FeedbackIndex: Int? {
        if case .feedback(let i) = ch2Source { return i } else { return nil }
    }

    func routeFeedbackTo(_ channel: ActiveChannel, feedbackIndex: Int = 0) {
        switch channel {
        case .ch1: ch1Source = .feedback(feedbackIndex)
        case .ch2: ch2Source = .feedback(feedbackIndex)
        }
    }

    func routeActivePad(_ index: Int) {
        switch activeChannel {
        case .ch1: ch1Source = .pad(index)
        case .ch2: ch2Source = .pad(index)
        }
    }

    func routeKeyerTo(_ channel: ActiveChannel, keyerIndex: Int = 0) {
        switch channel {
        case .ch1: ch1Source = .keyer(keyerIndex)
        case .ch2: ch2Source = .keyer(keyerIndex)
        }
    }

    func toggleActiveChannel() {
        activeChannel = (activeChannel == .ch1) ? .ch2 : .ch1
    }
}
