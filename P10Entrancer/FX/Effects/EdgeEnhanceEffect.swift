import Foundation
import Metal

@MainActor
final class EdgeEnhanceEffect: FXEffect {
    let name = "Edge Enhance"
    var isEnabled: Bool = false
    var strength: Float = 1.0

    private let pipeline: MTLRenderPipelineState

    init(context: MetalContext = .shared) throws {
        self.pipeline = try context.makePipeline(
            vertex: "fxVertex",
            fragment: "fxEdgeEnhanceFragment",
            pixelFormat: .bgra8Unorm
        )
    }

    var parameters: [FXParameter] {
        [FXParameter(name: "Strength", range: 0...3, get: { [weak self] in self?.strength ?? 0 }, set: { [weak self] in self?.strength = $0 })]
    }

    func encode(input: MTLTexture, previousFrame: MTLTexture, output: MTLTexture, encoder: MTLRenderCommandEncoder, elapsedTime: Float) {
        var params = EdgeEnhanceParams(strength: strength, _pad0: 0, _pad1: 0, _pad2: 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<EdgeEnhanceParams>.size, index: 0)
        FXFullscreenVertex.encode(encoder)
    }
}

private struct EdgeEnhanceParams {
    var strength: Float
    var _pad0: Float
    var _pad1: Float
    var _pad2: Float
}
