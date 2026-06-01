import XCTest
import Combine
@testable import P10Entrancer

@MainActor
final class MixerStateTests: XCTestCase {

    func test_initial_defaults() {
        let m = MixerState()
        XCTAssertEqual(m.activeChannel, .ch1)
        XCTAssertEqual(m.ch1PadIndex, 0)
        XCTAssertEqual(m.ch2PadIndex, 1)
        XCTAssertFalse(m.ch1IsKeyer)
        XCTAssertFalse(m.ch2IsKeyer)
    }

    func test_routeActivePad_with_ch1_active_changes_ch1_only() {
        let m = MixerState()
        m.activeChannel = .ch1
        m.routeActivePad(7)
        XCTAssertEqual(m.ch1Source, .pad(7), "Tapping a pad while CH1 is active must route to ch1Source")
        XCTAssertEqual(m.ch2Source, .pad(1), "ch2Source must NOT change when CH1 is active")
    }

    func test_routeActivePad_with_ch2_active_changes_ch2_only() {
        let m = MixerState()
        m.activeChannel = .ch2
        m.routeActivePad(7)
        XCTAssertEqual(m.ch2Source, .pad(7), "Tapping a pad while CH2 is active must route to ch2Source")
        XCTAssertEqual(m.ch1Source, .pad(0), "ch1Source must NOT change when CH2 is active")
    }

    func test_routeActivePad_does_not_swap_channels() {
        // Regression test for: changing channel 1 changes channel 2 incorrectly.
        let m = MixerState()
        m.ch1Source = .pad(2)
        m.ch2Source = .pad(5)

        m.activeChannel = .ch1
        m.routeActivePad(8)
        XCTAssertEqual(m.ch1Source, .pad(8))
        XCTAssertEqual(m.ch2Source, .pad(5), "ch2Source must NOT have moved")

        m.activeChannel = .ch2
        m.routeActivePad(3)
        XCTAssertEqual(m.ch2Source, .pad(3))
        XCTAssertEqual(m.ch1Source, .pad(8), "ch1Source must NOT have moved")
    }

    func test_routeKeyerTo_target_only() {
        let m = MixerState()
        m.routeKeyerTo(.ch1)
        XCTAssertTrue(m.ch1IsKeyer)
        XCTAssertFalse(m.ch2IsKeyer)
        XCTAssertNil(m.ch1PadIndex)
        XCTAssertEqual(m.ch2PadIndex, 1)

        m.routeKeyerTo(.ch2)
        XCTAssertTrue(m.ch1IsKeyer)
        XCTAssertTrue(m.ch2IsKeyer)
    }

    func test_atomic_fx_channel_sources_are_unindexed() {
        // ChannelSource.keyer / .feedback / .xyz carry no payload —
        // both channels routed to .keyer compare equal.
        let m = MixerState()
        m.ch1Source = .keyer
        m.ch2Source = .keyer
        XCTAssertEqual(m.ch1Source, m.ch2Source)
        m.ch2Source = .feedback
        XCTAssertNotEqual(m.ch1Source, m.ch2Source)
        m.ch2Source = .xyz
        XCTAssertNotEqual(m.ch1Source, m.ch2Source)
    }

    func test_toggleActiveChannel_alternates() {
        let m = MixerState()
        XCTAssertEqual(m.activeChannel, .ch1)
        m.toggleActiveChannel()
        XCTAssertEqual(m.activeChannel, .ch2)
        m.toggleActiveChannel()
        XCTAssertEqual(m.activeChannel, .ch1)
    }

    func test_channel_source_index_helpers() {
        let m = MixerState()
        m.ch1Source = .pad(4)
        XCTAssertEqual(m.ch1PadIndex, 4)
        XCTAssertFalse(m.ch1IsKeyer)

        m.ch1Source = .keyer
        XCTAssertNil(m.ch1PadIndex)
        XCTAssertTrue(m.ch1IsKeyer)
    }

    func test_active_channel_independent_of_routing() {
        let m = MixerState()
        m.activeChannel = .ch2
        XCTAssertEqual(m.activeChannel, .ch2)
        // Routing to active should not change which channel is active.
        m.routeActivePad(3)
        XCTAssertEqual(m.activeChannel, .ch2)
    }

    func test_outputGeometry_default_and_assignment() {
        let m = MixerState()
        XCTAssertEqual(m.outputGeometry, .ar16_9, "default output geometry is 16:9")
        m.outputGeometry = .ar4_3
        XCTAssertEqual(m.outputGeometry, .ar4_3, "assigning .ar4_3 must take effect")
        m.outputGeometry = .ar16_9
        XCTAssertEqual(m.outputGeometry, .ar16_9, "assigning back to .ar16_9 must take effect")
    }

    func test_canvasSize_follows_geometry_and_resolution() {
        let m = MixerState()
        // Defaults: 16:9 @ 1280x720, 4:3 @ 640x480.
        m.outputGeometry = .ar16_9
        XCTAssertEqual(m.canvasSize.width, 1280)
        XCTAssertEqual(m.canvasSize.height, 720)
        m.outputGeometry = .ar4_3
        XCTAssertEqual(m.canvasSize.width, 640)
        XCTAssertEqual(m.canvasSize.height, 480)
        // Picking a different per-geometry resolution flows through canvasSize.
        m.resolution4_3 = OutputResolution(width: 1440, height: 1080)
        XCTAssertEqual(m.canvasSize.width, 1440)
        XCTAssertEqual(m.canvasSize.height, 1080)
    }

    func test_geometry_aspect_values() {
        XCTAssertEqual(OutputGeometry.ar16_9.aspect, 16.0 / 9.0, accuracy: 1e-6)
        XCTAssertEqual(OutputGeometry.ar4_3.aspect, 4.0 / 3.0, accuracy: 1e-6)
    }

    func test_outputGeometry_publishes_changes() {
        let m = MixerState()
        var observed: [OutputGeometry] = []
        let cancellable = m.$outputGeometry.sink { observed.append($0) }
        m.outputGeometry = .ar4_3
        m.outputGeometry = .ar16_9
        m.outputGeometry = .ar4_3
        cancellable.cancel()
        XCTAssertEqual(observed, [.ar16_9, .ar4_3, .ar16_9, .ar4_3],
                       "Publisher must emit initial + every assignment so SwiftUI views update")
    }
}
