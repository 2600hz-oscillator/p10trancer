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

    /// Bootstrap creates Factory at /Documents/Performances/Factory/
    /// with all bundled pad videos copied in, exactly once (idempotent
    /// across calls so we don't blow away user-edited Factory).
    func test_bootstrap_factory_creates_package_with_videos() throws {
        // Clear every bootstrap flag we've used so far so the
        // bootstrap path actually runs regardless of which version
        // a prior test or app launch already set.
        for key in ["p10e.factoryBootstrapped",
                    "p10e.factoryBootstrapped.v2",
                    "p10e.factoryBootstrapped.v3"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let store = PerformanceStore()
        store.delete("Factory") // ensure a clean start
        store.bootstrapFactoryIfNeeded()
        XCTAssertTrue(store.names.contains("Factory"))
        let manifest = try XCTUnwrap(store.loadManifest(name: "Factory"))
        XCTAssertEqual(manifest.pads.count, PadSystem.padCount)
        let packagedCount = manifest.pads.compactMap { $0.packagedVideoBasename }.count
        XCTAssertEqual(packagedCount, PadSystem.padCount,
                       "Every pad should have its bundled pad-N.mp4 packaged in Factory")
    }

    /// Export round-trip: archive Factory to a .aar, file lands on
    /// disk, non-empty.
    func test_export_writes_aar_file() throws {
        let appState = AppState.shared
        appState.startIfNeeded()
        // Force bootstrap regardless of flag state from prior tests.
        for key in ["p10e.factoryBootstrapped",
                    "p10e.factoryBootstrapped.v2",
                    "p10e.factoryBootstrapped.v3"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        appState.performances.delete("Factory")
        appState.performances.bootstrapFactoryIfNeeded()
        let source = appState.performances.packageURL(for: "Factory")
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("Factory-export-\(UUID().uuidString).aar")
        defer { try? FileManager.default.removeItem(at: dest) }
        let url = try PerformanceArchiver.archive(sourceDir: source, to: dest)
        XCTAssertEqual(url, dest)
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 1024,
                             "Exported .aar should be non-trivial (Factory has 9 video files)")
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
