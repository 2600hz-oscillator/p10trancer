import XCTest
@testable import P10Entrancer

@MainActor
final class PerformancePackageTests: XCTestCase {

    /// Saving a performance package writes manifest.json, copies the
    /// referenced video files into <package>/videos/, and rewrites
    /// the manifest's pad entries to point at those copies.
    func test_save_writes_manifest_and_copies_videos() throws {
        let appState = AppState.shared
        appState.startIfNeeded()
        appState.resetToFactoryDefaults()
        let name = "test-pkg-\(UUID().uuidString.prefix(6))"
        let saved = appState.savePerformance(named: name)
        XCTAssertTrue(saved)
        defer { appState.performances.delete(name) }

        let manifest = try XCTUnwrap(appState.performances.loadManifest(name: name))
        // At least one pad has a packagedVideoBasename (the bundled
        // pad1.mp4 should have been copied).
        let packagedCount = manifest.pads.compactMap { $0.packagedVideoBasename }.count
        XCTAssertGreaterThan(packagedCount, 0,
                             "Expected at least one pad to have its video copied into the package")
        // And the copied file actually exists.
        if let firstPad = manifest.pads.first(where: { $0.packagedVideoBasename != nil }),
           let basename = firstPad.packagedVideoBasename {
            let url = appState.performances.videoURL(name: name, basename: basename)
            XCTAssertNotNil(url,
                            "video at <package>/videos/\(basename) should exist on disk")
        }
    }

    /// Loading a package replaces each packaged pad's source with a
    /// VideoFileSource pointing at the package-local file (not the
    /// bundle copy).
    func test_load_replaces_pads_with_packaged_video_url() throws {
        let appState = AppState.shared
        appState.startIfNeeded()
        appState.resetToFactoryDefaults()
        let name = "load-test-\(UUID().uuidString.prefix(6))"
        XCTAssertTrue(appState.savePerformance(named: name))
        defer { appState.performances.delete(name) }
        // Replace pad 0 with nil so we can prove the load restores it.
        appState.pads.setSource(nil, at: 0)
        XCTAssertNil(appState.pads.pads[0].source)
        appState.loadPerformance(named: name)
        let restored = appState.pads.pads[0].source as? VideoFileSource
        XCTAssertNotNil(restored, "Loading the package should restore pad 0's video source")
        // And it should point at the PACKAGE's copy, not the bundle.
        let packageDir = appState.performances.packageURL(for: name).path
        XCTAssertTrue(restored?.url.path.hasPrefix(packageDir) ?? false,
                      "Restored video URL should be inside the package, was: \(restored?.url.path ?? "nil")")
    }
}
