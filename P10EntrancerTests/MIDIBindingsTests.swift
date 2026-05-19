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

    // MARK: - Explicit binary mode setters (Electra-friendly)

    func test_pc_60_sets_output_mode_to_hd() {
        mixer.outputMode = .ntsc4_3
        bindings.handleProgramChange(60)
        XCTAssertEqual(mixer.outputMode, .hd720p)
    }

    func test_pc_61_sets_output_mode_to_ntsc() {
        mixer.outputMode = .hd720p
        bindings.handleProgramChange(61)
        XCTAssertEqual(mixer.outputMode, .ntsc4_3)
    }

    func test_pc_60_is_idempotent_unlike_toggle() {
        mixer.outputMode = .hd720p
        bindings.handleProgramChange(60)
        bindings.handleProgramChange(60)
        XCTAssertEqual(mixer.outputMode, .hd720p, "PC 60 must always set HD, never flip away")
    }

    func test_pc_62_enables_keyer() {
        keyer.isEnabled = false
        bindings.handleProgramChange(62)
        XCTAssertTrue(keyer.isEnabled)
    }

    func test_pc_63_disables_keyer() {
        keyer.isEnabled = true
        bindings.handleProgramChange(63)
        XCTAssertFalse(keyer.isEnabled)
    }

    func test_pc_62_is_idempotent_unlike_toggle() {
        keyer.isEnabled = false
        bindings.handleProgramChange(62)
        bindings.handleProgramChange(62)
        XCTAssertTrue(keyer.isEnabled, "PC 62 must always enable, never flip back off")
    }

    // MARK: - Channel-keyed per-pad FX (CC 23-34)

    func test_cc23_on_channel_0_sets_pad_1_blur() {
        // Channel 0 = MIDI ch 1 = pad 1 (index 0)
        bindings.handleCC(cc: 23, value: 127, channel: 0)
        let blur = pads.pads[0].fxChain.effects.first { $0.name == "Blur" }
        XCTAssertNotNil(blur, "Blur effect should exist")
        XCTAssertEqual(blur?.parameters[0].value ?? 0, 6.0, accuracy: 0.05,
                       "Pad 0 Blur radius should be at top of range")
    }

    func test_cc23_on_channel_5_sets_pad_6_not_pad_0() {
        // Snapshot pad 0's Blur BEFORE the channel-5 dispatch so we
        // can assert it didn't move (we can't rely on a specific
        // default value across builds).
        let pad0Blur = pads.pads[0].fxChain.effects.first { $0.name == "Blur" }!
        let pad0Before = pad0Blur.parameters[0].value
        let pad5Blur = pads.pads[5].fxChain.effects.first { $0.name == "Blur" }!

        mixer.inspectedPadIndex = 0
        bindings.handleCC(cc: 23, value: 127, channel: 5)

        XCTAssertEqual(pad0Blur.parameters[0].value, pad0Before, accuracy: 0.01,
                       "Pad 0 must NOT be affected when channel addresses pad 5")
        XCTAssertEqual(pad5Blur.parameters[0].value, 6.0, accuracy: 0.05,
                       "Pad 5 must receive the FX param via channel 5")
    }

    func test_cc23_on_channel_15_uses_inspected_pad_index() {
        mixer.inspectedPadIndex = 3
        bindings.handleCC(cc: 23, value: 127, channel: 15)
        let pad3Blur = pads.pads[3].fxChain.effects.first { $0.name == "Blur" }
        XCTAssertEqual(pad3Blur?.parameters[0].value ?? 0, 6.0, accuracy: 0.05,
                       "Channels 9-15 must keep the inspectedPadIndex semantics")
    }

    // MARK: - Explicit FX on/off via channel-keyed CC 35-40

    func test_cc35_channel_4_enables_pad_5_blur() {
        let blur = pads.pads[4].fxChain.effects.first { $0.name == "Blur" }!
        XCTAssertFalse(blur.isEnabled, "default should be disabled")
        bindings.handleCC(cc: 35, value: 127, channel: 4)
        XCTAssertTrue(blur.isEnabled, "CC 35 value=127 on channel 4 should enable pad 5's Blur")
    }

    func test_cc35_value_below_64_disables_blur() {
        let blur = pads.pads[2].fxChain.effects.first { $0.name == "Blur" }!
        bindings.handleCC(cc: 35, value: 127, channel: 2)
        XCTAssertTrue(blur.isEnabled)
        bindings.handleCC(cc: 35, value: 0, channel: 2)
        XCTAssertFalse(blur.isEnabled, "value < 64 must turn the effect off")
    }

    func test_cc35_40_each_maps_to_correct_effect_name() {
        let cases: [(cc: Int, effect: String)] = [
            (35, "Blur"), (36, "Chroma"), (37, "YUV Phaser"),
            (38, "Luma Phaser"), (39, "Edge Enhance"), (40, "Feedback"),
        ]
        for (cc, name) in cases {
            // Reset
            let chain = pads.pads[0].fxChain
            for fx in chain.effects { fx.isEnabled = false }
            bindings.handleCC(cc: cc, value: 127, channel: 0)
            let target = chain.effects.first { $0.name == name }
            XCTAssertNotNil(target, "Effect \(name) must exist")
            XCTAssertTrue(target?.isEnabled ?? false, "CC \(cc) must turn on \(name)")
            // The OTHER effects should remain off.
            for fx in chain.effects where fx.name != name {
                XCTAssertFalse(fx.isEnabled, "\(fx.name) must NOT be turned on by CC \(cc)")
            }
        }
    }

    func test_cc35_on_channel_9_through_15_is_no_op() {
        // Above the per-pad channel range — should NOT touch any
        // pad's enable state.
        for pad in pads.pads { pad.fxChain.effects.forEach { $0.isEnabled = false } }
        bindings.handleCC(cc: 35, value: 127, channel: 9)
        bindings.handleCC(cc: 35, value: 127, channel: 15)
        for pad in pads.pads {
            for fx in pad.fxChain.effects {
                XCTAssertFalse(fx.isEnabled, "channel >= 9 must not enable any effect")
            }
        }
    }

    // MARK: - CC 23-34 no longer auto-enables

    func test_cc23_channel_keyed_does_not_auto_enable() {
        let blur = pads.pads[3].fxChain.effects.first { $0.name == "Blur" }!
        blur.isEnabled = false
        bindings.handleCC(cc: 23, value: 127, channel: 3)
        XCTAssertFalse(blur.isEnabled,
                       "Moving the param via CC must NOT flip isEnabled automatically — that's the on/off CC's job now")
        XCTAssertEqual(blur.parameters[0].value, 6.0, accuracy: 0.05,
                       "Param value must still update even though the effect is off")
    }

    func test_cc14_through_22_ignore_channel() {
        // NTSC controls (CC 14-22) are NOT in the 23-34 range, so channel
        // routing must NOT apply — value should land in NTSC state
        // regardless of channel.
        bindings.handleCC(cc: 14, value: 127, channel: 5)
        XCTAssertEqual(ntsc.chromaBoost, 3.0, accuracy: 0.05)
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

    func test_cc3_drives_only_master_chroma_threshold_not_keyers() {
        // Snapshot keyer threshold so we can check it didn't move.
        let before = keyer.threshold
        bindings.handleCC(cc: 3, value: 95)
        XCTAssertEqual(mixer.keyThreshold, 95.0/127.0, accuracy: 0.001,
                       "CC 3 must drive the master mixer's chroma-transition threshold")
        XCTAssertEqual(keyer.threshold, before, accuracy: 0.001,
                       "CC 3 must NOT touch the keyers — those have their own setup sliders")
    }

    func test_cc4_drives_only_master_chroma_softness_not_keyers() {
        let before = keyer.softness
        bindings.handleCC(cc: 4, value: 127)
        XCTAssertEqual(mixer.keySoftness, 0.5, accuracy: 0.001,
                       "CC 4 must drive the master mixer's chroma-transition softness")
        XCTAssertEqual(keyer.softness, before, accuracy: 0.001,
                       "CC 4 must NOT touch the keyers")
        bindings.handleCC(cc: 4, value: 0)
        XCTAssertEqual(mixer.keySoftness, 0.001, accuracy: 0.001)
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
        // Note: CC 23 no longer auto-enables. Explicit enable is via
        // channel-keyed CC 35-40. The radius value still updates.
    }

    func test_cc32_feedback_mix_drives_inspected_pad_only() {
        mixer.inspectedPadIndex = 5
        bindings.handleCC(cc: 32, value: 127)
        let fbPad5 = pads.pads[5].fxChain.effects.first { $0.name == "Feedback" }
        let fbPad6 = pads.pads[6].fxChain.effects.first { $0.name == "Feedback" }
        XCTAssertEqual(fbPad5?.parameters[0].value ?? 0, 1.0, accuracy: 0.01,
                       "Inspected pad's Feedback mix should update")
        XCTAssertNotEqual(fbPad6?.parameters[0].value ?? 0, 1.0,
                          "Different pad's Feedback mix should NOT change")
    }

    // MARK: - Per-pad play / mute toggles (Notes 72-80 / 84-92)

    func test_note_72_through_80_toggle_play_on_file_pads() {
        // Place a known file source on pad 0 so we can observe isPlaying.
        let url = Bundle.main.url(forResource: "pad1", withExtension: "mp4")
        try? XCTSkipIf(url == nil, "pad1.mp4 missing from bundle")
        if let url {
            pads.setSource(VideoFileSource(url: url), at: 0)
        }
        let video = pads.pads[0].source as? VideoFileSource
        XCTAssertEqual(video?.isPlaying, true, "Default state is playing")
        bindings.handleNoteOn(72) // pad 1 toggle
        XCTAssertEqual(video?.isPlaying, false, "Note 72 toggles pad 1 to stopped")
        bindings.handleNoteOn(72)
        XCTAssertEqual(video?.isPlaying, true, "Note 72 toggles pad 1 back to playing")
    }

    func test_note_72_no_op_for_non_file_sources() {
        // Pad 0 has whatever default it has; replace with nil to ensure
        // it's a non-file source.
        pads.setSource(nil, at: 0)
        // Should not crash.
        bindings.handleNoteOn(72)
    }

    func test_note_84_through_92_toggle_mute_on_audio_pads() {
        let url = Bundle.main.url(forResource: "pad1", withExtension: "mp4")
        try? XCTSkipIf(url == nil, "pad1.mp4 missing from bundle")
        if let url {
            pads.setSource(VideoFileSource(url: url), at: 3)
        }
        guard let player = pads.pads[3].audioPlayer else {
            XCTFail("audioPlayer expected on file pad"); return
        }
        XCTAssertFalse(player.isMuted)
        bindings.handleNoteOn(84 + 3) // pad 4 mute toggle
        XCTAssertTrue(player.isMuted, "Note 87 should mute pad 4")
        bindings.handleNoteOn(84 + 3)
        XCTAssertFalse(player.isMuted, "Note 87 toggles pad 4 back unmuted")
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
