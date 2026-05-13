import Foundation
import Combine

/// A "Performance Package" is a self-contained folder under
/// Documents/Performances/<name>/ that bundles all of an app
/// session's settings (pads, mixer, FX, LFOs, NTSC, etc.) PLUS
/// the video file content each pad references. Loading a
/// performance from another device works without needing those
/// files to be in the user's UserVideos folder.
///
/// Layout on disk:
///
///   Documents/Performances/<Name>/
///     manifest.json    ← serialized SessionSpec (with packagedVideoBasename
///                       set on any pad whose source is in this folder)
///     videos/
///       <padN-source-file>.mp4
///       <another>.mp4
///
/// Camera sources don't get bundled (cameras are physical hardware
/// and we just store the device ID; if the device is missing on the
/// receiving side, that pad loads empty).
@MainActor
final class PerformanceStore: ObservableObject {
    @Published private(set) var names: [String] = []

    private let storageDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Performances", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() { refreshList() }

    func refreshList() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: storageDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            names = []
            return
        }
        names = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.lastPathComponent }
            .sorted()
    }

    func packageURL(for name: String) -> URL {
        storageDir.appendingPathComponent(name, isDirectory: true)
    }

    /// Save a SessionSpec as a Performance package. Video files
    /// referenced by `videosToCopy` (one URL per pad index that has
    /// a file-backed video) are duplicated into `<package>/videos/`
    /// and the spec's pad entries are rewritten to point at the
    /// packaged copies. Returns the package URL on success.
    @discardableResult
    func savePackage(name: String,
                     spec: SessionSpec,
                     videoFilesByPad: [Int: URL]) -> URL? {
        guard !name.isEmpty else { return nil }
        let dir = packageURL(for: name)
        let videosDir = dir.appendingPathComponent("videos", isDirectory: true)
        do {
            // Fresh slate: blow away any prior package with this name
            // so leftover files don't linger.
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)

            var updatedSpec = spec
            updatedSpec.name = name
            for i in updatedSpec.pads.indices {
                let padIndex = updatedSpec.pads[i].index
                guard let srcURL = videoFilesByPad[padIndex] else { continue }
                // Use the SOURCE filename so re-saving the same
                // performance with the same files is a no-op-ish copy.
                let basename = srcURL.lastPathComponent
                let dest = videosDir.appendingPathComponent(basename)
                if !FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.copyItem(at: srcURL, to: dest)
                }
                updatedSpec.pads[i].packagedVideoBasename = basename
            }
            let data = try JSONEncoder().encode(updatedSpec)
            try data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
            refreshList()
            P10Logger.log("[PerformanceStore] saved '\(name)' (\(updatedSpec.pads.count) pads)")
            return dir
        } catch {
            P10Logger.log("[PerformanceStore] save '\(name)' failed: \(error)")
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }

    func loadManifest(name: String) -> SessionSpec? {
        let dir = packageURL(for: name)
        let manifest = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest) else { return nil }
        return try? JSONDecoder().decode(SessionSpec.self, from: data)
    }

    /// Returns the on-disk URL for a video referenced by a pad in
    /// this package. nil if the pad doesn't carry a packagedVideoBasename
    /// or the file isn't where we expect.
    func videoURL(name: String, basename: String) -> URL? {
        let url = packageURL(for: name)
            .appendingPathComponent("videos", isDirectory: true)
            .appendingPathComponent(basename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func delete(_ name: String) {
        let dir = packageURL(for: name)
        try? FileManager.default.removeItem(at: dir)
        refreshList()
    }

    // MARK: - Bootstrap

    /// On first launch, materialize a "Factory" package by copying
    /// the bundled padN.mp4 files into Documents/Performances/Factory/
    /// and writing a manifest from a fresh-defaults SessionSpec.
    /// Tracked in UserDefaults so we don't overwrite a user's edits
    /// after they LOAD + tweak + re-SAVE "Factory".
    static let factoryName = "Factory"
    /// Bump this key's version suffix any time the bundled pad
    /// videos change so existing installs re-bootstrap Factory and
    /// pick up the new content. Older flag values are ignored.
    private static let bootstrappedDefaultsKey = "p10e.factoryBootstrapped.v3"

    func bootstrapFactoryIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.bootstrappedDefaultsKey) {
            return
        }
        let dir = packageURL(for: Self.factoryName)
        let videosDir = dir.appendingPathComponent("videos", isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)
            var padSpecs: [SessionSpec.PadSpec] = []
            for i in 0..<PadSystem.padCount {
                let resource = "pad\(i + 1)"
                let fx = SessionSpec.FXChainSpec(effects: [])
                if let src = Bundle.main.url(forResource: resource, withExtension: "mp4") {
                    let dest = videosDir.appendingPathComponent("\(resource).mp4")
                    try FileManager.default.copyItem(at: src, to: dest)
                    padSpecs.append(SessionSpec.PadSpec(
                        index: i, kind: .empty,
                        bundledIndex: nil, userVideoBasename: nil,
                        packagedVideoBasename: "\(resource).mp4",
                        cameraID: nil, keyerIndex: nil, fx: fx
                    ))
                } else {
                    padSpecs.append(SessionSpec.PadSpec(
                        index: i, kind: .empty,
                        bundledIndex: nil, userVideoBasename: nil,
                        packagedVideoBasename: nil,
                        cameraID: nil, keyerIndex: nil, fx: fx
                    ))
                }
            }
            let spec = SessionSpec(
                name: Self.factoryName,
                pads: padSpecs,
                keyers: [
                    .init(foregroundPadIndex: 6, backgroundPadIndex: 7, kind: 0,
                          threshold: 0.35, softness: 0.1, keyColor: [0, 1, 0]),
                    .init(foregroundPadIndex: 7, backgroundPadIndex: 8, kind: 0,
                          threshold: 0.35, softness: 0.1, keyColor: [0, 1, 0])
                ],
                mixer: .init(
                    ch1Source: .init(kind: .pad, index: 0),
                    ch2Source: .init(kind: .pad, index: 1),
                    activeChannel: 0, transition: 0,
                    position: 0, masterVolume: 0, outputMode: 0
                ),
                ntsc: .init(chromaBoost: 1.0, lumaNoise: 0, chromaNoise: 0,
                             hsyncWobble: 0, dropoutRate: 0, burstPhaseShift: 0,
                             subcarrierDrift: 0, ycDelay: 0, combStrength: 0.7,
                             lumaPeaking: 0),
                liveRecordings: []
            )
            let data = try JSONEncoder().encode(spec)
            try data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
            defaults.set(true, forKey: Self.bootstrappedDefaultsKey)
            refreshList()
            P10Logger.log("[PerformanceStore] bootstrapped Factory package")
        } catch {
            P10Logger.log("[PerformanceStore] bootstrap Factory failed: \(error)")
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
