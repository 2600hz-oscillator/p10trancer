import Metal
import QuartzCore

/// Lets a pad use a keyer's composite as its source. The keyer's foreground
/// and background pads are configured separately in `KeyerState`; this
/// source just forwards the keyer renderer's output texture.
///
/// Self-loops (pad N's source = Keyer K, where K.foregroundPadIndex = N)
/// produce 1-frame feedback by design, since the renderer reads the pad's
/// texture which is this object's last-frame output.
@MainActor
final class KeyerPadSource: PadSource {
    let keyerIndex: Int
    private let renderer: KeyerRenderer

    init(keyerIndex: Int, renderer: KeyerRenderer) {
        self.keyerIndex = keyerIndex
        self.renderer = renderer
    }

    var currentTexture: MTLTexture? { renderer.outputTexture }
    var displayAspect: Float { 16.0 / 9.0 }
    func tick(timestamp: CFTimeInterval) {}
}
