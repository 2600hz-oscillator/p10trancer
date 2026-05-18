import XCTest
@testable import P10Entrancer

@MainActor
final class MIDIOutputBindingsTests: XCTestCase {
    private var mixer: MixerState!
    private var pads: PadSystem!
    private var keyer: KeyerState!
    private var ntsc: NTSCState!
    private var output: MIDIOutputBindings!
    private var sink: FakeSink!

    override func setUp() {
        super.setUp()
        mixer = MixerState()
        pads = PadSystem()
        keyer = KeyerState()
        ntsc = NTSCState()
        output = MIDIOutputBindings(mixer: mixer, pads: pads, keyer: keyer, ntsc: ntsc)
        sink = FakeSink()
        output.attach(sink: sink)
    }

    func test_position_change_emits_cc1() {
        sink.events.removeAll()
        mixer.position = 0.7
        XCTAssertTrue(sink.events.contains { $0[0] == 0xB0 && $0[1] == 1 })
        let lastCC1 = sink.events.last { $0[1] == 1 }!
        XCTAssertEqual(lastCC1[2], 89) // 0.7 * 127 ≈ 89
    }

    func test_master_volume_change_emits_cc2() {
        sink.events.removeAll()
        mixer.masterVolume = 1.0
        XCTAssertTrue(sink.events.contains { $0 == [0xB0, 2, 127] })
    }

    func test_ch1_pad_assignment_emits_pc() {
        sink.events.removeAll()
        mixer.ch1Source = .pad(4)
        // Should emit PC 5 (= pad index 4 + 1).
        XCTAssertTrue(sink.events.contains { $0 == [0xC0, 5, 0] })
    }

    func test_ch1_keyer_assignment_emits_pc40() {
        sink.events.removeAll()
        mixer.ch1Source = .keyer
        XCTAssertTrue(sink.events.contains { $0 == [0xC0, 40, 0] },
                      "ch1.keyer must emit PC 40 so automation captures it")
    }

    func test_ch1_feedback_assignment_emits_pc41() {
        sink.events.removeAll()
        mixer.ch1Source = .feedback
        XCTAssertTrue(sink.events.contains { $0 == [0xC0, 41, 0] })
    }

    func test_ch1_xyz_assignment_emits_pc42() {
        sink.events.removeAll()
        mixer.ch1Source = .xyz
        XCTAssertTrue(sink.events.contains { $0 == [0xC0, 42, 0] })
    }

    func test_ch2_keyer_feedback_xyz_emit_pc_50_51_52() {
        sink.events.removeAll()
        mixer.ch2Source = .keyer
        XCTAssertTrue(sink.events.contains { $0 == [0xC0, 50, 0] })
        sink.events.removeAll()
        mixer.ch2Source = .feedback
        XCTAssertTrue(sink.events.contains { $0 == [0xC0, 51, 0] })
        sink.events.removeAll()
        mixer.ch2Source = .xyz
        XCTAssertTrue(sink.events.contains { $0 == [0xC0, 52, 0] })
    }

    /// End-to-end: a routing PC out of MIDIOutputBindings must round-trip
    /// through MIDIBindings.handleProgramChange to set the same source.
    func test_channel_source_pc_round_trip_through_midi_bindings() {
        let bindings = MIDIBindings(mixer: mixer, pads: pads, keyer: keyer, ntsc: ntsc)
        bindings.output = output
        mixer.ch1Source = .pad(0)
        bindings.handleProgramChange(40)
        XCTAssertEqual(mixer.ch1Source, .keyer)
        bindings.handleProgramChange(51)
        XCTAssertEqual(mixer.ch2Source, .feedback)
        bindings.handleProgramChange(52)
        XCTAssertEqual(mixer.ch2Source, .xyz)
        bindings.handleProgramChange(41)
        XCTAssertEqual(mixer.ch1Source, .feedback)
        bindings.handleProgramChange(42)
        XCTAssertEqual(mixer.ch1Source, .xyz)
        bindings.handleProgramChange(50)
        XCTAssertEqual(mixer.ch2Source, .keyer)
    }

    func test_active_channel_change_emits_pc_10_or_11() {
        sink.events.removeAll()
        mixer.activeChannel = .ch2
        XCTAssertTrue(sink.events.contains { $0 == [0xC0, 11, 0] })
        sink.events.removeAll()
        mixer.activeChannel = .ch1
        XCTAssertTrue(sink.events.contains { $0 == [0xC0, 10, 0] })
    }

    func test_transition_change_emits_pc_12_through_16() {
        sink.events.removeAll()
        mixer.transition = .chromaKey
        XCTAssertTrue(sink.events.contains { $0 == [0xC0, 15, 0] })
    }

    func test_inspected_pad_emits_pc_22_through_30() {
        sink.events.removeAll()
        mixer.inspectedPadIndex = 3
        XCTAssertTrue(sink.events.contains { $0 == [0xC0, 25, 0] })
    }

    func test_ntsc_chroma_change_emits_cc14_scaled() {
        sink.events.removeAll()
        ntsc.chromaBoost = 3.0
        XCTAssertTrue(sink.events.contains { $0 == [0xB0, 14, 127] })
    }

    func test_muted_flag_suppresses_emission() {
        sink.events.removeAll()
        output.muted = true
        mixer.position = 0.7
        output.muted = false
        XCTAssertTrue(sink.events.isEmpty, "muted flag should suppress all output")
    }

    func test_outputmode_change_emits_pc17_and_explicit() {
        sink.events.removeAll()
        mixer.outputMode = .ntsc4_3
        XCTAssertTrue(sink.events.contains { $0 == [0xC0, 17, 0] },
                      "Legacy toggle PC 17 must still emit")
        XCTAssertTrue(sink.events.contains { $0 == [0xC0, 61, 0] },
                      "Explicit PC 61 (NTSC) must emit for stateless receivers")
        sink.events.removeAll()
        mixer.outputMode = .hd720p
        XCTAssertTrue(sink.events.contains { $0 == [0xC0, 60, 0] },
                      "Explicit PC 60 (HD) must emit when switching back")
    }

    func test_keyer_isEnabled_change_emits_pc18_and_explicit() {
        sink.events.removeAll()
        keyer.isEnabled = true
        XCTAssertTrue(sink.events.contains { $0 == [0xC0, 18, 0] },
                      "Legacy toggle PC 18 must still emit")
        XCTAssertTrue(sink.events.contains { $0 == [0xC0, 62, 0] },
                      "Explicit PC 62 (keyer on) must emit")
        sink.events.removeAll()
        keyer.isEnabled = false
        XCTAssertTrue(sink.events.contains { $0 == [0xC0, 63, 0] },
                      "Explicit PC 63 (keyer off) must emit")
    }

    func test_inbound_midi_round_trip_does_not_echo() {
        // Simulate the user-facing scenario: MIDI comes in via MIDIBindings,
        // MIDIBindings sets the muted flag, the resulting state changes don't
        // echo back out the MIDIOutputBindings.
        sink.events.removeAll()
        let bindings = MIDIBindings(mixer: mixer, pads: pads, keyer: keyer, ntsc: ntsc)
        bindings.output = output
        let router = MIDIRouter.shared
        bindings.attach(to: router)

        bindings.handleCC(cc: 1, value: 64) // simulates inbound MIDI directly
        XCTAssertTrue(sink.events.isEmpty, "inbound MIDI should not produce outbound MIDI (would loop)")
    }
}

@MainActor
private final class FakeSink: MIDISink {
    var events: [[UInt8]] = []
    func send(_ bytes: [UInt8]) {
        events.append(bytes)
    }
}
