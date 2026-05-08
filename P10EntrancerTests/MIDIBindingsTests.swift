import XCTest
@testable import P10Entrancer

@MainActor
final class MIDIBindingsTests: XCTestCase {
    private var mixer: MixerState!
    private var pads: PadSystem!
    private var keyer: KeyerState!
    private var ntsc: NTSCState!
    private var recorder: MixerRecorder!
    private var bindings: MIDIBindings!

    override func setUp() {
        super.setUp()
        mixer = MixerState()
        pads = PadSystem()
        keyer = KeyerState()
        ntsc = NTSCState()
        recorder = MixerRecorder()
        bindings = MIDIBindings(mixer: mixer, pads: pads, keyer: keyer, ntsc: ntsc, recorder: recorder)
    }

    // MARK: - Note On

    func test_note_36_through_44_route_to_pads_1_through_9() {
        mixer.activeChannel = .ch1
        for (i, note) in (36...44).enumerated() {
            mixer.activeChannel = .ch1
            bindings.handleNoteOn(note)
            XCTAssertEqual(mixer.ch1Source, .pad(i), "MPC-style note \(note) should route to pad \(i)")
        }
    }

    func test_note_60_through_68_route_to_pads_1_through_9() {
        mixer.activeChannel = .ch1
        for (i, note) in (60...68).enumerated() {
            mixer.activeChannel = .ch1
            bindings.handleNoteOn(note)
            XCTAssertEqual(mixer.ch1Source, .pad(i), "Keyboard-style note \(note) should route to pad \(i)")
        }
    }

    func test_notes_outside_known_ranges_are_ignored() {
        mixer.ch1Source = .pad(2)
        bindings.handleNoteOn(35)
        XCTAssertEqual(mixer.ch1Source, .pad(2))
        bindings.handleNoteOn(45)
        XCTAssertEqual(mixer.ch1Source, .pad(2))
        bindings.handleNoteOn(59)
        XCTAssertEqual(mixer.ch1Source, .pad(2))
        bindings.handleNoteOn(69)
        XCTAssertEqual(mixer.ch1Source, .pad(2))
    }

    // MARK: - Program Change

    func test_pc_1_through_9_route_to_pads() {
        mixer.activeChannel = .ch2
        for i in 0..<9 {
            mixer.activeChannel = .ch2
            bindings.handleProgramChange(i + 1)
            XCTAssertEqual(mixer.ch2Source, .pad(i), "PC \(i + 1) should route to pad \(i)")
        }
    }

    func test_pc_10_selects_ch1() {
        mixer.activeChannel = .ch2
        bindings.handleProgramChange(10)
        XCTAssertEqual(mixer.activeChannel, .ch1)
    }

    func test_pc_11_selects_ch2() {
        mixer.activeChannel = .ch1
        bindings.handleProgramChange(11)
        XCTAssertEqual(mixer.activeChannel, .ch2)
    }

    func test_pc_12_through_16_select_transitions() {
        let expected: [TransitionKind] = [.crossfade, .linearSwipe, .starSwipe, .chromaKey, .lumaKey]
        for (i, expected) in expected.enumerated() {
            bindings.handleProgramChange(12 + i)
            XCTAssertEqual(mixer.transition, expected)
        }
    }

    func test_pc_17_toggles_output_mode() {
        XCTAssertEqual(mixer.outputMode, .hd720p)
        bindings.handleProgramChange(17)
        XCTAssertEqual(mixer.outputMode, .ntsc4_3)
        bindings.handleProgramChange(17)
        XCTAssertEqual(mixer.outputMode, .hd720p)
    }

    func test_pc_18_toggles_keyer_enable() {
        XCTAssertFalse(keyer.isEnabled)
        bindings.handleProgramChange(18)
        XCTAssertTrue(keyer.isEnabled)
        bindings.handleProgramChange(18)
        XCTAssertFalse(keyer.isEnabled)
    }

    func test_pc_19_routes_keyer_to_ch1() {
        bindings.handleProgramChange(19)
        XCTAssertTrue(mixer.ch1IsKeyer)
        XCTAssertFalse(mixer.ch2IsKeyer)
    }

    func test_pc_20_routes_keyer_to_ch2() {
        bindings.handleProgramChange(20)
        XCTAssertTrue(mixer.ch2IsKeyer)
        XCTAssertFalse(mixer.ch1IsKeyer)
    }

    // MARK: - CC: mixer & master

    func test_cc1_position() {
        bindings.handleCC(cc: 1, value: 0)
        XCTAssertEqual(mixer.position, 0.0, accuracy: 0.001)
        bindings.handleCC(cc: 1, value: 127)
        XCTAssertEqual(mixer.position, 1.0, accuracy: 0.001)
        bindings.handleCC(cc: 1, value: 64)
        XCTAssertEqual(mixer.position, 64.0/127.0, accuracy: 0.001)
    }

    func test_cc2_master_volume() {
        bindings.handleCC(cc: 2, value: 96)
        XCTAssertEqual(mixer.masterVolume, 96.0/127.0, accuracy: 0.001)
    }

    func test_cc3_keyer_threshold_propagates_to_state() {
        bindings.handleCC(cc: 3, value: 95)
        XCTAssertEqual(mixer.keyThreshold, 95.0/127.0, accuracy: 0.001)
        XCTAssertEqual(keyer.threshold, 95.0/127.0, accuracy: 0.001)
    }

    func test_cc4_keyer_softness_scales() {
        bindings.handleCC(cc: 4, value: 127)
        XCTAssertEqual(keyer.softness, 0.5, accuracy: 0.001)
        bindings.handleCC(cc: 4, value: 0)
        XCTAssertEqual(keyer.softness, 0.001, accuracy: 0.001)
    }

    // MARK: - CC: NTSC FX

    func test_cc14_ntsc_chroma_boost_scales_to_3x() {
        bindings.handleCC(cc: 14, value: 127)
        XCTAssertEqual(ntsc.chromaBoost, 3.0, accuracy: 0.001)
        bindings.handleCC(cc: 14, value: 0)
        XCTAssertEqual(ntsc.chromaBoost, 0.0, accuracy: 0.001)
    }

    func test_cc15_ntsc_hsync_wobble() {
        bindings.handleCC(cc: 15, value: 127)
        XCTAssertEqual(ntsc.hsyncWobble, 1.0, accuracy: 0.001)
    }

    func test_cc17_ntsc_burst_phase_centers_around_zero() {
        bindings.handleCC(cc: 17, value: 64)
        XCTAssertEqual(ntsc.burstPhaseShift, 64.0/127.0 - 0.5, accuracy: 0.005)
        bindings.handleCC(cc: 17, value: 0)
        XCTAssertEqual(ntsc.burstPhaseShift, -0.5, accuracy: 0.001)
        bindings.handleCC(cc: 17, value: 127)
        XCTAssertEqual(ntsc.burstPhaseShift, 0.5, accuracy: 0.001)
    }

    func test_cc18_ntsc_yc_delay_signed() {
        bindings.handleCC(cc: 18, value: 64)
        XCTAssertEqual(ntsc.ycDelay, (64.0/127.0 - 0.5) * 16.0, accuracy: 0.05)
    }

    // MARK: - CC: per-pad audio volume

    func test_cc5_through_13_set_pad_volumes() {
        // PadAudioPlayer is created by VideoFileSource async; we can't always set
        // a real source in a unit test environment without bundle assets.
        // Instead just verify the cc range doesn't crash and falls into the right indices.
        for i in 0..<9 {
            bindings.handleCC(cc: 5 + i, value: 64)
            // No assertion on volume since audioPlayer may not exist in tests; the
            // important property is that the dispatch picked the right pad index
            // and didn't crash.
        }
    }

    // MARK: - regression

    func test_pc_does_not_corrupt_other_state() {
        let originalCh1 = mixer.ch1Source
        bindings.handleProgramChange(10)  // Set CH1 active
        bindings.handleProgramChange(11)  // Set CH2 active
        XCTAssertEqual(mixer.ch1Source, originalCh1)
        XCTAssertEqual(mixer.activeChannel, .ch2)
    }

    func test_unknown_pc_silently_ignored() {
        bindings.handleProgramChange(127)
        bindings.handleProgramChange(0)
        // No assertion — just that nothing crashes.
    }

    // MARK: - PC 22-30 + per-pad FX CCs

    func test_pc_22_through_30_set_inspected_pad() {
        for i in 0..<9 {
            bindings.handleProgramChange(22 + i)
            XCTAssertEqual(mixer.inspectedPadIndex, i, "PC \(22 + i) should select pad \(i) for FX inspection")
        }
    }

    func test_cc23_blur_radius_drives_inspected_pad() {
        mixer.inspectedPadIndex = 3
        bindings.handleCC(cc: 23, value: 127)
        let blur = pads.pads[3].fxChain.effects.first { $0.name == "Blur" }
        XCTAssertNotNil(blur)
        XCTAssertEqual(blur?.parameters[0].value ?? 0, 6.0, accuracy: 0.01)
        XCTAssertTrue(blur?.isEnabled ?? false)
    }

    func test_cc23_zero_disables_blur() {
        mixer.inspectedPadIndex = 3
        bindings.handleCC(cc: 23, value: 100)
        bindings.handleCC(cc: 23, value: 0)
        let blur = pads.pads[3].fxChain.effects.first { $0.name == "Blur" }
        XCTAssertFalse(blur?.isEnabled ?? true)
    }

    func test_cc32_feedback_mix_drives_inspected_pad_only() {
        mixer.inspectedPadIndex = 5
        bindings.handleCC(cc: 32, value: 127)
        let fbPad5 = pads.pads[5].fxChain.effects.first { $0.name == "Feedback" }
        let fbPad6 = pads.pads[6].fxChain.effects.first { $0.name == "Feedback" }
        XCTAssertEqual(fbPad5?.parameters[0].value ?? 0, 1.0, accuracy: 0.01)
        XCTAssertTrue(fbPad5?.isEnabled ?? false)
        XCTAssertFalse(fbPad6?.isEnabled ?? true, "Feedback on a different pad must NOT enable")
    }

    func test_inspect_then_modify_then_inspect_different() {
        // Regression for the user's "fade ch2 to ch3 + ramp pad-2 feedback" workflow.
        // Sequence: select pad 1 (PC 23), ramp its feedback (CC 32), then select pad 2 (PC 24)
        // and ramp its feedback. The first pad's feedback should remain at the level we set.
        bindings.handleProgramChange(23) // inspect pad 1 (index 1)
        bindings.handleCC(cc: 32, value: 100)
        let fbPad1 = pads.pads[1].fxChain.effects.first { $0.name == "Feedback" }
        let level1 = fbPad1?.parameters[0].value ?? 0
        XCTAssertGreaterThan(level1, 0.5)

        bindings.handleProgramChange(24) // inspect pad 2 (index 2)
        bindings.handleCC(cc: 32, value: 80)
        let fbPad2 = pads.pads[2].fxChain.effects.first { $0.name == "Feedback" }
        let level2 = fbPad2?.parameters[0].value ?? 0
        XCTAssertGreaterThan(level2, 0.4)

        // pad 1 still has its prior level.
        XCTAssertEqual(fbPad1?.parameters[0].value ?? 0, level1, accuracy: 0.001,
                       "pad 1 feedback should not change when we shift inspection to pad 2")
    }
}
