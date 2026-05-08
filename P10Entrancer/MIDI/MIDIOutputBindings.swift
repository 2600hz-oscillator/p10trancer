import Foundation
import Combine

/// Subscribes to all relevant app state and emits matching MIDI events
/// when the state changes. Used to publish a virtual MIDI source so a
/// host (Bitwig, etc.) can record iPad gestures as automation.
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

    func attach(sink: MIDISink) {
        self.sink = sink
        wireMixer()
        wireChannelsAndModes()
        wireKeyerAndNTSC()
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
                if case .pad(let i) = source {
                    self.send([0xC0, UInt8(i + 1), 0])
                }
            }
            .store(in: &cancellables)
        mixer.$ch2Source
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] source in
                guard let self else { return }
                if case .pad(let i) = source {
                    self.send([0xC0, UInt8(i + 1), 0])
                }
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
}
