import XCTest
@testable import P10Entrancer

@MainActor
final class FXChainTests: XCTestCase {

    func test_padslot_returns_source_texture_when_no_fx_enabled() {
        let pads = PadSystem()
        let pad = pads.pads[0]
        XCTAssertFalse(pad.fxChain.isAnyEnabled)
    }

    func test_padslot_isAnyEnabled_reflects_individual_effect_states() {
        let pads = PadSystem()
        let pad = pads.pads[0]
        for effect in pad.fxChain.effects {
            effect.isEnabled = false
        }
        XCTAssertFalse(pad.fxChain.isAnyEnabled)

        if let first = pad.fxChain.effects.first {
            first.isEnabled = true
            XCTAssertTrue(pad.fxChain.isAnyEnabled)
            first.isEnabled = false
            XCTAssertFalse(pad.fxChain.isAnyEnabled)
        }
    }

    func test_fxchain_has_six_effects() {
        let pads = PadSystem()
        XCTAssertEqual(pads.pads[0].fxChain.effects.count, 6, "Each pad should have 6 effects: blur/chroma/yuv/luma/edge/feedback")
    }

    func test_fxchain_effect_names() {
        let pads = PadSystem()
        let names = Set(pads.pads[0].fxChain.effects.map { $0.name })
        XCTAssertTrue(names.contains("Blur"))
        XCTAssertTrue(names.contains("Chroma"))
        XCTAssertTrue(names.contains("YUV Phaser"))
        XCTAssertTrue(names.contains("Luma Phaser"))
        XCTAssertTrue(names.contains("Edge Enhance"))
        XCTAssertTrue(names.contains("Feedback"))
    }

    func test_each_effect_has_at_least_one_parameter() {
        let pads = PadSystem()
        for effect in pads.pads[0].fxChain.effects {
            XCTAssertGreaterThan(effect.parameters.count, 0, "Effect \(effect.name) has no parameters")
        }
    }

    func test_fxparameter_get_set_round_trip() {
        let pads = PadSystem()
        let blur = pads.pads[0].fxChain.effects.first { $0.name == "Blur" }
        XCTAssertNotNil(blur)
        guard let radiusParam = blur?.parameters.first else { return XCTFail("blur radius param missing") }
        radiusParam.value = 3.5
        XCTAssertEqual(radiusParam.value, 3.5, accuracy: 0.001)
    }
}
