import XCTest
@testable import P10Entrancer

@MainActor
final class PadChainTests: XCTestCase {

    /// AppState is a singleton — restore the default bundled clip on
    /// each pad so an earlier test's chain doesn't leak into the
    /// pre-condition of the next.
    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            let app = AppState.shared
            app.startIfNeeded()
            for i in 0..<PadSystem.padCount {
                if let url = Bundle.main.url(forResource: "pad\(i + 1)", withExtension: "mp4") {
                    app.pads.setSource(VideoFileSource(url: url), at: i)
                } else {
                    app.pads.setSource(nil, at: i)
                }
            }
        }
    }

    func test_self_chain_is_refused() {
        let app = AppState.shared
        let original = app.pads.pads[0].source
        app.setPadChainSource(at: 0, sourcePadIndex: 0)
        XCTAssertFalse(app.pads.pads[0].source is PadChainSource,
                       "Self-chain (pad N → pad N) must be refused")
        // Pad's existing source should be unchanged.
        XCTAssertTrue(app.pads.pads[0].source === original ||
                      type(of: app.pads.pads[0].source) == type(of: original),
                      "Refused chain shouldn't replace the existing source")
    }

    func test_chain_replaces_source_with_PadChainSource() {
        let app = AppState.shared
        app.setPadChainSource(at: 5, sourcePadIndex: 2)
        guard let chain = app.pads.pads[5].source as? PadChainSource else {
            XCTFail("Pad 6's source should be a PadChainSource"); return
        }
        XCTAssertEqual(chain.sourcePadIndex, 2)
    }

    func test_chain_forwards_upstream_texture() {
        let app = AppState.shared
        // Replace pad 4's source with something that returns nil
        // texture (no source). Chain pad 1 from pad 4 — its texture
        // should also be nil (forwarded).
        app.pads.setSource(nil, at: 3)
        app.setPadChainSource(at: 0, sourcePadIndex: 3)
        let chain = app.pads.pads[0].source as? PadChainSource
        XCTAssertNil(chain?.currentTexture,
                     "Chain reads upstream's texture; if upstream has no source the chain shows nil")
    }
}
