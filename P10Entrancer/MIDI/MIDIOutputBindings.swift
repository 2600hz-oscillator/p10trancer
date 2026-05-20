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
        // CC 2 (master volume) was removed when the master mixer UI
        // was dropped. Per-pad volumes are the only volume knobs.
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
                self.emitChannelSource(source, channel: .ch1)
            }
            .store(in: &cancellables)
        mixer.$ch2Source
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] source in
                guard let self else { return }
                self.emitChannelSource(source, channel: .ch2)
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
            .sink { [weak self] mode in
                guard let self else { return }
                // Emit BOTH the legacy toggle (PC 17) and the explicit
                // setter (PC 60 = HD, PC 61 = NTSC). Legacy receivers
                // that act on PC 17 keep working; stateless receivers
                // (Electra One) act on the explicit PC and ignore 17.
                self.send([0xC0, 17, 0])
                self.send([0xC0, mode == .hd720p ? 60 : 61, 0])
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
            .sink { [weak self] isEnabled in
                guard let self else { return }
                // Legacy toggle (PC 18) + explicit setter (PC 62 = on,
                // PC 63 = off). Both emitted for the same reason as
                // outputMode above.
                self.send([0xC0, 18, 0])
                self.send([0xC0, isEnabled ? 62 : 63, 0])
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

    /// Emit a Program Change for a channel-source change. Pad sources
    /// use PC 1..9 (the long-standing mapping). Non-pad sources use:
    ///   ch1.keyer → PC 40, ch1.feedback → PC 41, ch1.xyz → PC 42
    ///   ch2.keyer → PC 50, ch2.feedback → PC 51, ch2.xyz → PC 52
    /// Recorded into automation takes via `MIDIOutput.onSent`, replayed
    /// through `MIDIBindings` which sets the matching channel source.
    private func emitChannelSource(_ source: ChannelSource, channel: ActiveChannel) {
        switch source {
        case .pad(let i):
            // Pad routing relies on the active-channel state at receive
            // time — only emit when the channel that's changing is the
            // active one, otherwise the receiver would route to the
            // wrong channel.
            if channel == mixer.activeChannel {
                send([0xC0, UInt8(i + 1), 0])
            }
        case .keyer:
            send([0xC0, channel == .ch1 ? 40 : 50, 0])
        case .feedback:
            send([0xC0, channel == .ch1 ? 41 : 51, 0])
        case .xyz:
            send([0xC0, channel == .ch1 ? 42 : 52, 0])
        }
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
}
