import XCTest
@testable import P10Entrancer

@MainActor
final class AutomationEngineTests: XCTestCase {

    private var engine: AutomationEngine!
    private var sink: CapturingSink!

    override func setUp() {
        super.setUp()
        engine = AutomationEngine()
        sink = CapturingSink()
        engine.attach(router: MIDIRouter.shared, output: sink)
        // Wipe any persisted takes from prior runs so list-state
        // tests start from a known baseline.
        while let id = engine.takes.first?.id {
            engine.selectedTakeId = id
            engine.deleteSelectedTake()
        }
    }

    // MARK: - START REC / STOP REC

    func test_startRecordingNow_moves_state_to_recording() {
        engine.startRecordingNow()
        XCTAssertTrue(engine.state == .recording || engine.state == .armedRecord,
                      "startRecordingNow must leave engine in armedRecord or recording, was \(engine.state)")
    }

    func test_stop_via_disarm_during_recording_saves_take() {
        let baseline = engine.takes.count
        engine.startRecordingNow()
        // Feed an event so the take isn't empty (empty takes are
        // discarded by design).
        engine.captureOutbound([0xB0, 1, 64])
        engine.disarm()
        XCTAssertEqual(engine.takes.count, baseline + 1,
                       "Stopping recording via disarm() must persist the new take")
        XCTAssertEqual(engine.state, .idle)
    }

    func test_stop_with_no_events_discards_take() {
        let baseline = engine.takes.count
        engine.startRecordingNow()
        engine.disarm()
        XCTAssertEqual(engine.takes.count, baseline,
                       "Stopping with zero events must NOT create a take")
    }

    // MARK: - Loop

    func test_loop_default_disabled() {
        XCTAssertFalse(engine.loopEnabled, "Loop must default to off")
    }

    func test_loop_toggle_is_published() {
        engine.loopEnabled = true
        XCTAssertTrue(engine.loopEnabled)
        engine.loopEnabled = false
        XCTAssertFalse(engine.loopEnabled)
    }

    // MARK: - Auto-save shows up in takes list

    func test_saved_take_becomes_selected() {
        engine.startRecordingNow()
        engine.captureOutbound([0xB0, 1, 64])
        engine.disarm()
        XCTAssertNotNil(engine.selectedTakeId)
        let selected = engine.takes.first { $0.id == engine.selectedTakeId }
        XCTAssertNotNil(selected, "selectedTakeId must point at a real take after stop-rec")
        XCTAssertFalse(selected?.events.isEmpty ?? true)
    }
}

@MainActor
private final class CapturingSink: MIDISink {
    var bytes: [[UInt8]] = []
    func send(_ b: [UInt8]) { bytes.append(b) }
}
