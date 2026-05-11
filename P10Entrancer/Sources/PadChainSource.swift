import Metal
import QuartzCore

/// PadSource that forwards another pad's processed output texture
/// (i.e., `pads[i].texture` — which is the FX chain's output if any
/// FX are enabled, else the raw source). Lets the user chain pads:
/// pad B set to source from pad A inherits A's video + A's FX, then
/// can layer its own FX on top.
///
/// Audio is NOT chained — the upstream pad's audioPlayer keeps its
/// own routing, so chaining is purely a video aliasing mechanism.
/// To play A's audio, route A directly to a channel as well.
///
/// Cycles between chains naturally resolve to a 1-frame lag (same
/// trick the feedback unit uses): each frame's renderer reads
/// whatever's currently published on the upstream pad. If the
/// upstream pad hasn't been processed yet this tick, the texture is
/// last frame's — which is the right behavior, and avoids any kind
/// of infinite-recursion crash.
@MainActor
final class PadChainSource: PadSource {
    let sourcePadIndex: Int
    private let pads: PadSystem

    init(sourcePadIndex: Int, pads: PadSystem) {
        self.sourcePadIndex = sourcePadIndex
        self.pads = pads
    }

    var currentTexture: MTLTexture? {
        guard pads.pads.indices.contains(sourcePadIndex) else { return nil }
        return pads.pads[sourcePadIndex].texture
    }

    var displayAspect: Float {
        guard pads.pads.indices.contains(sourcePadIndex) else { return 16.0 / 9.0 }
        return pads.pads[sourcePadIndex].aspect
    }

    func tick(timestamp: CFTimeInterval) {}
}
