import XCTest
@testable import P10Entrancer

/// Cheap invariants the app must hold at launch. These run in <50ms on
/// the simulator so the iteration loop catches regressions fast.
@MainActor
final class LaunchInvariantsTests: XCTestCase {

    /// Master volume must be 0 after startIfNeeded so a saved session
    /// (which restores `mixer.masterVolume` to whatever was persisted)
    /// can never blast the speakers when the app launches. Regression
    /// fired when wireMasterVolume started propagating session-loaded
    /// values into the engine.
    func test_master_volume_is_zero_after_start() {
        let app = AppState.shared
        app.startIfNeeded()
        XCTAssertEqual(app.mixer.masterVolume, 0,
                       "mixer.masterVolume must default to 0 at launch")
    }

    /// All four iPad orientations must remain in Info.plist —
    /// regression for "portrait isn't full screen" symptoms.
    func test_info_plist_supports_all_iPad_orientations() throws {
        let bundle = Bundle.main
        let key = "UISupportedInterfaceOrientations~ipad"
        let orientations = try XCTUnwrap(
            bundle.object(forInfoDictionaryKey: key) as? [String],
            "Info.plist missing \(key)"
        )
        XCTAssertTrue(orientations.contains("UIInterfaceOrientationPortrait"),
                      "Portrait orientation must be supported")
        XCTAssertTrue(orientations.contains("UIInterfaceOrientationPortraitUpsideDown"))
        XCTAssertTrue(orientations.contains("UIInterfaceOrientationLandscapeLeft"))
        XCTAssertTrue(orientations.contains("UIInterfaceOrientationLandscapeRight"))
    }

    /// `UIApplicationSupportsMultipleScenes=true` makes iPadOS 26 treat
    /// the app as multitasking-eligible — and the primary scene then
    /// stops resizing on rotation, leaving portrait letterboxed inside
    /// a landscape-shaped window. Lock to single-scene.
    func test_info_plist_does_not_support_multiple_scenes() throws {
        let bundle = Bundle.main
        let manifest = try XCTUnwrap(
            bundle.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any],
            "Info.plist missing UIApplicationSceneManifest"
        )
        let supports = manifest["UIApplicationSupportsMultipleScenes"] as? Bool
        XCTAssertEqual(supports, false,
                       "Multiple scenes must be off so primary scene resizes on rotation")
    }
}
