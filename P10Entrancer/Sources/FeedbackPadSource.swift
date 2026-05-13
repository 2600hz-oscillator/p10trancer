import Metal
import QuartzCore

/// Lets a pad use a feedback unit's output as its source. The unit's source
/// pad and zoom/pan/tilt are configured on `FeedbackState` directly. This
/// source just forwards the renderer's current output texture.
@MainActor
final class FeedbackPadSource: PadSource {
    let feedbackIndex: Int
    private let renderer: FeedbackRenderer

    init(feedbackIndex: Int, renderer: FeedbackRenderer) {
        self.feedbackIndex = feedbackIndex
        self.renderer = renderer
    }

    var currentTexture: MTLTexture? { renderer.outputTexture }
    var displayAspect: Float { 16.0 / 9.0 }
    func tick(timestamp: CFTimeInterval) {}
}
