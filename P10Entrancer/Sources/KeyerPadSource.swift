import Metal
import QuartzCore

/// Lets a regular source pad show the atomic keyer's composite as its
/// source. The keyer's foreground / background pads are configured on
/// `KeyerState`; this source just forwards the keyer renderer's output
/// texture.
///
/// Self-loops (pad N's source = the keyer, where keyer.foregroundPadIndex = N)
/// produce 1-frame feedback by design, since the renderer reads the pad's
/// texture which is this object's last-frame output.
@MainActor
final class KeyerPadSource: PadSource {
    private let renderer: KeyerRenderer

    init(renderer: KeyerRenderer) {
        self.renderer = renderer
    }

    var currentTexture: MTLTexture? { renderer.outputTexture }
    var displayAspect: Float { 16.0 / 9.0 }
    func tick(timestamp: CFTimeInterval) {}
}
