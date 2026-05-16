import Metal
import QuartzCore

/// Lets a regular source pad use the atomic feedback unit's output as
/// its source. Configuration (input pad, zoom/pan/tilt/decay/etc.)
/// lives on `FeedbackState`; this source just forwards the renderer's
/// current output texture.
@MainActor
final class FeedbackPadSource: PadSource {
    private let renderer: FeedbackRenderer

    init(renderer: FeedbackRenderer) {
        self.renderer = renderer
    }

    var currentTexture: MTLTexture? { renderer.outputTexture }
    var displayAspect: Float { 16.0 / 9.0 }
    func tick(timestamp: CFTimeInterval) {}
}
