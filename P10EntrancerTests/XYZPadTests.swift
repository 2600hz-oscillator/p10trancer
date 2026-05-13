import XCTest
@testable import P10Entrancer

@MainActor
final class XYZPadTests: XCTestCase {

    func test_default_fx_pad_slots_are_keyer_feedback_xyz() {
        let system = FXPadSystem()
        XCTAssertEqual(system.slots.count, 3)
        XCTAssertEqual(system.slots[0].kind, .keyer(0))
        XCTAssertEqual(system.slots[1].kind, .feedback(0))
        XCTAssertEqual(system.slots[2].kind, .xyz(0))
    }

    func test_xyz_lfo_target_scoping() {
        let transport = Transport()
        let engine = LFOEngine(transport: transport)
        engine.registerTargets([
            LFOTarget(id: "xyz.0.intensity", displayName: "X1 int", range: 0...2,
                      getBase: { 0 }, setEffective: { _ in }),
            LFOTarget(id: "xyz.1.intensity", displayName: "X2 int", range: 0...2,
                      getBase: { 0 }, setEffective: { _ in }),
            LFOTarget(id: "pad.0.volume", displayName: "P1 vol", range: 0...1,
                      getBase: { 0 }, setEffective: { _ in }),
        ])
        let xyz0Targets = engine.availableTargets(forSlot: "xyz-0")
        XCTAssertEqual(xyz0Targets.map(\.id), ["xyz.0.intensity"])
        // XYZ-1 LFO mustn't see XYZ-0 targets either.
        let xyz1Targets = engine.availableTargets(forSlot: "xyz-1")
        XCTAssertEqual(xyz1Targets.map(\.id), ["xyz.1.intensity"])
    }

    func test_session_capture_roundtrips_xyz_channel_source() {
        let app = AppState.shared
        app.startIfNeeded()
        app.mixer.ch1Source = .xyz(0)
        app.mixer.ch2Source = .xyz(2)
        let spec = SessionCapture.snapshot(
            name: "test",
            pads: app.pads,
            keyerSystem: app.keyerSystem,
            mixer: app.mixer,
            ntsc: app.ntscState,
            cameras: app.cameras,
            liveRecordings: app.liveRecordings
        )
        // Reset to a non-xyz value to confirm apply restores xyz.
        app.mixer.ch1Source = .pad(0)
        app.mixer.ch2Source = .pad(1)
        SessionCapture.apply(spec, to: app)
        XCTAssertEqual(app.mixer.ch1Source, .xyz(0))
        XCTAssertEqual(app.mixer.ch2Source, .xyz(2))
    }

    func test_xyz_renderer_skips_when_no_resolver() throws {
        let state = XYZState(inputSource: .pad(0))
        let renderer = try XYZRenderer(state: state)
        // No sourceResolver wired → render() returns silently, no
        // crash, no output texture allocated.
        renderer.render()
        XCTAssertNil(renderer.outputTexture)
    }
}
