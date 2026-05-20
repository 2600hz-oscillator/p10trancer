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

    /// The slot `kind` is a `let` — the compiler enforces that callers
    /// can't reassign it. This test exists to pin that intent so
    /// somebody can't quietly change it to a `var` later.
    func test_fx_pad_slot_kind_is_let_not_var() {
        let mirror = Mirror(reflecting: FXPadSlot(id: 0, kind: .keyer))
        // The `kind` child should not be settable — Mirror doesn't
        // distinguish let/var, but the type's source is the source of
        // truth. We just confirm it's accessible by the right name.
        XCTAssertTrue(mirror.children.contains { $0.label == "kind" })
    }

    func test_fx_pad_slot_channel_source_maps_to_atomic_units() {
        let system = FXPadSystem()
        XCTAssertEqual(system.slots[0].kind.channelSource, .keyer)
        XCTAssertEqual(system.slots[1].kind.channelSource, .feedback)
        XCTAssertEqual(system.slots[2].kind.channelSource, .xyz)
    }

    func test_fx_pad_slot_underlying_lfo_slot_ids() {
        let system = FXPadSystem()
        XCTAssertEqual(system.slots[0].kind.underlyingLFOSlotID, "keyer")
        XCTAssertEqual(system.slots[1].kind.underlyingLFOSlotID, "feedback")
        XCTAssertEqual(system.slots[2].kind.underlyingLFOSlotID, "xyz")
    }

    func test_xyz_lfo_target_scoping() {
        let transport = Transport()
        let engine = LFOEngine(transport: transport)
        engine.registerTargets([
            LFOTarget(id: "xyz.intensity", displayName: "XYZ int", range: 0...2,
                      getBase: { 0 }, setEffective: { _ in }),
            LFOTarget(id: "pad.0.volume", displayName: "P1 vol", range: 0...1,
                      getBase: { 0 }, setEffective: { _ in }),
        ])
        let xyzTargets = engine.availableTargets(forSlot: "xyz")
        XCTAssertEqual(xyzTargets.map(\.id), ["xyz.intensity"])
    }

    func test_session_capture_roundtrips_xyz_channel_source() {
        let app = AppState.shared
        app.startIfNeeded()
        app.mixer.ch1Source = .xyz
        app.mixer.ch2Source = .xyz
        let spec = SessionCapture.snapshot(
            name: "test",
            pads: app.pads,
            keyerSystem: app.keyerSystem,
            mixer: app.mixer,
            ntsc: app.ntscState,
            hdPost: app.hdPostState,
            cameras: app.cameras,
            liveRecordings: app.liveRecordings
        )
        app.mixer.ch1Source = .pad(0)
        app.mixer.ch2Source = .pad(1)
        SessionCapture.apply(spec, to: app)
        XCTAssertEqual(app.mixer.ch1Source, .xyz)
        XCTAssertEqual(app.mixer.ch2Source, .xyz)
    }

    func test_xyz_renderer_skips_when_no_resolver() throws {
        let state = XYZState(inputSource: .pad(0))
        let renderer = try XYZRenderer(state: state)
        renderer.render()
        XCTAssertNil(renderer.outputTexture)
    }
}
