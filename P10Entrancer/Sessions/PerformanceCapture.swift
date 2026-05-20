import Foundation

/// Save / apply for full Performance packages (settings + bundled
/// video files). Sits next to SessionCapture: same snapshot logic
/// for the spec, but the file URLs get copied into the package and
/// rewritten on load.
@MainActor
enum PerformanceCapture {

    /// Snapshot current state into a SessionSpec + a map of pad→
    /// source URL for everything that's currently a VideoFileSource.
    /// PerformanceStore copies those files into the package and
    /// rewrites the spec's pad entries to point at the copies.
    static func snapshotForPackage(name: String,
                                    appState: AppState) -> (SessionSpec, [Int: URL]) {
        let spec = SessionCapture.snapshot(
            name: name,
            pads: appState.pads,
            keyerSystem: appState.keyerSystem,
            mixer: appState.mixer,
            ntsc: appState.ntscState,
            hdPost: appState.hdPostState,
            cameras: appState.cameras,
            liveRecordings: appState.liveRecordings
        )
        var urls: [Int: URL] = [:]
        for (i, pad) in appState.pads.pads.enumerated() {
            if let v = pad.source as? VideoFileSource {
                urls[i] = v.url
            }
        }
        return (spec, urls)
    }

    /// Apply a saved Performance package. Loads `manifest.json`,
    /// then patches every pad whose spec carries a packagedVideoBasename
    /// to point at the file inside the package folder. Everything
    /// else (FX, keyers, mixer, NTSC) goes through the normal
    /// SessionCapture.apply path.
    static func apply(packageName: String,
                       store: PerformanceStore,
                       to appState: AppState) {
        guard let spec = store.loadManifest(name: packageName) else { return }
        // Apply the spec normally first — sets all settings + non-
        // packaged sources (camera, keyer, master feedback, etc).
        SessionCapture.apply(spec, to: appState)
        // Now override every pad whose spec carries a
        // packagedVideoBasename. We do this AFTER SessionCapture.apply
        // so its applyPad doesn't clobber what we set here.
        for padSpec in spec.pads {
            guard let basename = padSpec.packagedVideoBasename,
                  let url = store.videoURL(name: packageName, basename: basename) else { continue }
            appState.pads.setSource(VideoFileSource(url: url), at: padSpec.index)
            // Re-apply the FX chain values for this pad (SessionCapture
            // already applied them once, but if it nuked the source the
            // FXChain may have lost references — re-applying is cheap).
            let chain = appState.pads.pads[padSpec.index].fxChain
            for effectSpec in padSpec.fx.effects {
                guard let target = chain.effects.first(where: { $0.name == effectSpec.name }) else { continue }
                target.isEnabled = effectSpec.isEnabled
                for (paramIndex, value) in effectSpec.values.enumerated() {
                    guard paramIndex < target.parameters.count else { break }
                    target.parameters[paramIndex].value = value
                }
            }
        }
        P10Logger.log("[PerformanceCapture] applied package '\(packageName)'")
    }
}
