import Foundation
import Metal

@MainActor
final class FeedbackEffect: FXEffect {
    let name = "Feedback"
    var isEnabled: Bool = false
    var mix: Float = 0.6
    var zoom: Float = 1.02
    var rotation: Float = 0.01
    var decay: Float = 0.95

    private let pipeline: MTLRenderPipelineState

    init(context: MetalContext = .shared) throws {
        self.pipeline = try context.makePipeline(
            vertex: "fxVertex",
            fragment: "fxFeedbackFragment",
            pixelFormat: .bgra8Unorm
        )
    }

    var parameters: [FXParameter] {
        [
            FXParameter(name: "Mix", range: 0...1, get: { [weak self] in self?.mix ?? 0 }, set: { [weak self] in self?.mix = $0 }),
            FXParameter(name: "Zoom", range: 0.85...1.15, get: { [weak self] in self?.zoom ?? 1 }, set: { [weak self] in self?.zoom = $0 }),
            FXParameter(name: "Rotate", range: -0.1...0.1, get: { [weak self] in self?.rotation ?? 0 }, set: { [weak self] in self?.rotation = $0 }),
            FXParameter(name: "Decay", range: 0.5...1.0, get: { [weak self] in self?.decay ?? 1 }, set: { [weak self] in self?.decay = $0 })
        ]
    }

    func encode(input: MTLTexture, previousFrame: MTLTexture, output: MTLTexture, encoder: MTLRenderCommandEncoder, elapsedTime: Float) {
        var params = FeedbackParams(mix: mix, zoom: zoom, rotation: rotation, decay: decay)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentTexture(previousFrame, index: 1)
        encoder.setFragmentBytes(&params, length: MemoryLayout<FeedbackParams>.size, index: 0)
        FXFullscreenVertex.encode(encoder)
    }
}

private struct FeedbackParams {
    var mix: Float
    var zoom: Float
    var rotation: Float
    var decay: Float
}
