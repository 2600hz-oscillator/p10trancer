import XCTest
@testable import P10Entrancer

@MainActor
final class XYZPadTests: XCTestCase {

    func test_default_fx_pad_slots_are_fixed_keyer_feedback_xyz() {
        let system = FXPadSystem()
        XCTAssertEqual(system.slots.count, 3)
        XCTAssertEqual(system.slots[0].kind, .keyer)
        XCTAssertEqual(system.slots[1].kind, .feedback)
        XCTAssertEqual(system.slots[2].kind, .xyz)
    }

    func test_fx_pad_slot_kind_is_immutable_through_channel_source() {
        // The slot's `kind` is `let`, but verify the channelSource it
        // computes points at the canonical single instance (index 0)
        // of each FX type.
        let system = FXPadSystem()
        XCTAssertEqual(system.slots[0].kind.channelSource, .keyer(0))
        XCTAssertEqual(system.slots[1].kind.channelSource, .feedback(0))
        XCTAssertEqual(system.slots[2].kind.channelSource, .xyz(0))
    }

    func test_fx_pad_slot_underlying_lfo_slot_ids() {
        let system = FXPadSystem()
        XCTAssertEqual(system.slots[0].kind.underlyingLFOSlotID, "keyer-0")
        XCTAssertEqual(system.slots[1].kind.underlyingLFOSlotID, "feedback")
        XCTAssertEqual(system.slots[2].kind.underlyingLFOSlotID, "xyz-0")
    }

    func test_xyz_lfo_target_scoping() {
        let transport = Transport()
        let engine = LFOEngine(transport: transport)
        engine.registerTargets([
            LFOTarget(id: "xyz.0.intensity", displayName: "X1 int", range: 0...2,
                      getBase: { 0 }, setEffective: { _ in }),
            LFOTarget(id: "pad.0.volume", displayName: "P1 vol", range: 0...1,
                      getBase: { 0 }, setEffective: { _ in }),
        ])
        let xyz0Targets = engine.availableTargets(forSlot: "xyz-0")
        XCTAssertEqual(xyz0Targets.map(\.id), ["xyz.0.intensity"])
    }

    func test_session_capture_roundtrips_xyz_channel_source() {
        let app = AppState.shared
        app.startIfNeeded()
        app.mixer.ch1Source = .xyz(0)
        app.mixer.ch2Source = .xyz(0)
        let spec = SessionCapture.snapshot(
            name: "test",
            pads: app.pads,
            keyerSystem: app.keyerSystem,
            mixer: app.mixer,
            ntsc: app.ntscState,
            cameras: app.cameras,
            liveRecordings: app.liveRecordings
        )
        app.mixer.ch1Source = .pad(0)
        app.mixer.ch2Source = .pad(1)
        SessionCapture.apply(spec, to: app)
        XCTAssertEqual(app.mixer.ch1Source, .xyz(0))
        XCTAssertEqual(app.mixer.ch2Source, .xyz(0))
    }

    func test_xyz_renderer_skips_when_no_resolver() throws {
        let state = XYZState(inputSource: .pad(0))
        let renderer = try XYZRenderer(state: state)
        renderer.render()
        XCTAssertNil(renderer.outputTexture)
    }
}
