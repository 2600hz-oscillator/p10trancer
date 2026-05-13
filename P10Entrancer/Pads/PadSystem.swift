import Foundation
import QuartzCore

@MainActor
final class PadSystem: ObservableObject {
    static let padCount = 9
    let pads: [PadSlot]

    /// Bumped on every source replacement. SwiftUI views that observe
    /// PadSystem re-render when this changes — without that, views like
    /// PadFooterControls keep an `@ObservedObject` reference to the
    /// *old* source, which prevents that source from deallocating and
    /// leaks its audio player into the engine (audio keeps playing
    /// after a pad is reassigned).
    @Published private(set) var sourceVersion: Int = 0

    /// Fires after any pad's source has been replaced. AppState uses this
    /// to re-run audio routing so the new source's audioPlayer picks up
    /// the channel-assignment state.
    var onSourceChanged: (() -> Void)?

    init() {
        var slots: [PadSlot] = []
        for i in 0..<Self.padCount {
            let chain = PadSystem.makeFXChain()
            slots.append(PadSlot(index: i, fxChain: chain))
        }
        self.pads = slots
    }

    func tick(timestamp: CFTimeInterval) {
        let elapsed = Float(timestamp)
        for pad in pads {
            pad.source?.tick(timestamp: timestamp)
            pad.processFX(elapsedTime: elapsed)
        }
    }

    func setSource(_ source: PadSource?, at index: Int) {
        guard pads.indices.contains(index) else { return }
        // Pull the OLD source out of its slot BEFORE it loses its
        // pad-reference: that way, when we mute its mixer and stop its
        // player below, we know we're acting on the right node.
        let oldSource = pads[index].source
        pads[index].source = source
        // If the old source was a video file with audio attached to
        // the engine, mute it immediately rather than waiting for ARC
        // to drop the last reference and run deinit (SwiftUI views
        // can hold the old source alive long enough to keep the
        // audio audible — the deinit-mute path was racing the UI).
        if let oldVideo = oldSource as? VideoFileSource {
            oldVideo.audioPlayer.setRouted(false)
            oldVideo.audioPlayer.setPlaying(false)
        }
        sourceVersion &+= 1
        onSourceChanged?()
    }

    private static func makeFXChain() -> FXChain {
        var effects: [FXEffect] = []
        if let blur = try? BlurEffect() { effects.append(blur) }
        if let chroma = try? ChromaDistortEffect() { effects.append(chroma) }
        if let yuv = try? YUVPhaserEffect() { effects.append(yuv) }
        if let luma = try? LumaPhaserEffect() { effects.append(luma) }
        if let edge = try? EdgeEnhanceEffect() { effects.append(edge) }
        if let feedback = try? FeedbackEffect() { effects.append(feedback) }
        return FXChain(effects: effects)
    }
}
