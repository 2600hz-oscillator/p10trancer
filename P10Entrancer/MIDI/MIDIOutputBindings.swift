import Foundation
import Combine

/// Subscribes to all relevant app state and emits matching MIDI events
/// when the state changes. Used to publish a virtual MIDI source so a
/// host (any DAW) can record iPad gestures as automation.
@MainActor
final class MIDIOutputBindings {
    weak var sink: MIDISink?
    /// When true, outbound emission is suppressed. Set by MIDIBindings.dispatch
    /// while handling inbound MIDI to prevent feedback loops.
    var muted: Bool = false

    private let mixer: MixerState
    private let pads: PadSystem
    private let keyer: KeyerState
    private let ntsc: NTSCState
    private var cancellables = Set<AnyCancellable>()

    init(mixer: MixerState, pads: PadSystem, keyer: KeyerState, ntsc: NTSCState) {
        self.mixer = mixer
        self.pads = pads
        self.keyer = keyer
        self.ntsc = ntsc
    }

    /// Per-pad subscriptions to source.isPlaying / audioPlayer.isMuted.
    /// Tracked separately so we can tear them down and re-attach when a
    /// pad's source is replaced (drag-drop, session load).
    private var perPadCancellables: [Int: Set<AnyCancellable>] = [:]

    func attach(sink: MIDISink) {
        self.sink = sink
        wireMixer()
        wireChannelsAndModes()
        wireKeyerAndNTSC()
        wirePerPadPlayAndMute()
        // Re-wire the per-pad publishers when sources change.
        let prior = pads.onSourceChanged
        pads.onSourceChanged = { [weak self] in
            prior?()
            self?.wirePerPadPlayAndMute()
        }
    }

    /// Subscribe to each pad's source.isPlaying and audioPlayer.isMuted.
    /// Tears down any prior per-pad subscriptions first so source
    /// replacement doesn't leak observers. Note 72+i = play toggle,
    /// Note 84+i = mute toggle.
    func wirePerPadPlayAndMute() {
        for i in 0..<PadSystem.padCount {
            perPadCancellables[i] = []
            guard pads.pads.indices.contains(i) else { continue }
            let pad = pads.pads[i]
            if let video = pad.source as? VideoFileSource {
                video.$isPlaying
                    .removeDuplicates()
                    .dropFirst()
                    .sink { [weak self] _ in
                        // Note On with the pad's play key — receivers
                        // toggle in response, so the round-trip stays
                        // consistent.
                        self?.send([0x90, UInt8(72 + i), 64])
                    }
                    .store(in: &perPadCancellables[i, default: []])
            }
            if let player = pad.audioPlayer {
                player.$isMuted
                    .removeDuplicates()
                    .dropFirst()
                    .sink { [weak self] _ in
                        self?.send([0x90, UInt8(84 + i), 64])
                    }
                    .store(in: &perPadCancellables[i, default: []])
            }
        }
    }

    private func wireMixer() {
        mixer.$position
            .removeDuplicates()
            .sink { [weak self] v in self?.sendCC(1, v) }
            .store(in: &cancellables)
        mixer.$masterVolume
            .removeDuplicates()
            .sink { [weak self] v in self?.sendCC(2, v) }
            .store(in: &cancellables)
        mixer.$keyThreshold
            .removeDuplicates()
            .sink { [weak self] v in self?.sendCC(3, v) }
            .store(in: &cancellables)
        mixer.$keySoftness
            .removeDuplicates()
            .sink { [weak self] v in
                // Inverse of the input mapping (CC value × 0.5 → softness)
                self?.sendCC(4, min(v * 2.0, 1.0))
            }
            .store(in: &cancellables)
    }

    private func wireChannelsAndModes() {
        mixer.$ch1Source
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] source in
                guard let self else { return }
                self.muted = self.muted // explicit no-op for clarity
                self.send([0xC0, Self.programChange(for: source), 0])
            }
            .store(in: &cancellables)
        mixer.$ch2Source
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] source in
                guard let self else { return }
                self.send([0xC0, Self.programChange(for: source), 0])
            }
            .store(in: &cancellables)
        mixer.$activeChannel
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] ch in
                self?.send([0xC0, ch == .ch1 ? 10 : 11, 0])
            }
            .store(in: &cancellables)
        mixer.$transition
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] kind in
                self?.send([0xC0, UInt8(12 + kind.rawValue), 0])
            }
            .store(in: &cancellables)
        mixer.$outputMode
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.send([0xC0, 17, 0])
            }
            .store(in: &cancellables)
        mixer.$inspectedPadIndex
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] i in
                self?.send([0xC0, UInt8(22 + i), 0])
            }
            .store(in: &cancellables)
    }

    private func wireKeyerAndNTSC() {
        keyer.$isEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                // PC 18 is a TOGGLE — emitting it always works as long as the
                // host receiver toggles in response. Our MIDIBindings does, so
                // round-trip is consistent.
                self?.send([0xC0, 18, 0])
            }
            .store(in: &cancellables)

        ntsc.$chromaBoost.removeDuplicates().sink { [weak self] v in self?.sendCC(14, v / 3.0) }.store(in: &cancellables)
        ntsc.$hsyncWobble.removeDuplicates().sink { [weak self] v in self?.sendCC(15, v) }.store(in: &cancellables)
        ntsc.$subcarrierDrift.removeDuplicates().sink { [weak self] v in self?.sendCC(16, v / 0.5) }.store(in: &cancellables)
        ntsc.$burstPhaseShift.removeDuplicates().sink { [weak self] v in self?.sendCC(17, v + 0.5) }.store(in: &cancellables)
        ntsc.$ycDelay.removeDuplicates().sink { [weak self] v in self?.sendCC(18, v / 16.0 + 0.5) }.store(in: &cancellables)
        ntsc.$dropoutRate.removeDuplicates().sink { [weak self] v in self?.sendCC(19, v) }.store(in: &cancellables)
        ntsc.$lumaNoise.removeDuplicates().sink { [weak self] v in self?.sendCC(20, v / 0.3) }.store(in: &cancellables)
        ntsc.$chromaNoise.removeDuplicates().sink { [weak self] v in self?.sendCC(21, v / 0.3) }.store(in: &cancellables)
        ntsc.$lumaPeaking.removeDuplicates().sink { [weak self] v in self?.sendCC(22, v / 3.0) }.store(in: &cancellables)
    }

    private func sendCC(_ cc: UInt8, _ normalized: Float) {
        let clamped = max(0, min(1, normalized))
        let value = UInt8(round(clamped * 127.0))
        send([0xB0, cc, value])
    }

    private func send(_ bytes: [UInt8]) {
        guard !muted else { return }
        sink?.send(bytes)
    }

    /// Program-change byte for an outgoing channel-source change.
    /// Each channel source kind gets its own block of program numbers
    /// so external gear can react to the full routing surface, not
    /// just direct pad routings. Layout:
    ///   1..9   pads      (1-indexed for legacy reasons; pad N → N)
    ///   30..32 keyers    (keyer 0 → 30, keyer 1 → 31, ...)
    ///   40..47 feedback  (feedback 0 → 40, ...)
    ///   50..57 xyz       (xyz 0 → 50, xyz 1 → 51, ...)
    private static func programChange(for source: ChannelSource) -> UInt8 {
        switch source {
        case .pad(let i):      return UInt8(min(127, max(0, i + 1)))
        case .keyer(let i):    return UInt8(min(127, 30 + i))
        case .feedback(let i): return UInt8(min(127, 40 + i))
        case .xyz(let i):      return UInt8(min(127, 50 + i))
        }
    }
}
