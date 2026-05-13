import Foundation
import Metal

@MainActor
final class BlurEffect: FXEffect {
    let name = "Blur"
    var isEnabled: Bool = false
    var radius: Float = 1.0

    private let pipeline: MTLRenderPipelineState
    private let context: MetalContext

    init(context: MetalContext = .shared) throws {
        self.context = context
        self.pipeline = try context.makePipeline(
            vertex: "fxVertex",
            fragment: "fxBlurFragment",
            pixelFormat: .bgra8Unorm
        )
    }

    var parameters: [FXParameter] {
        [FXParameter(name: "Radius", range: 0...6, get: { [weak self] in self?.radius ?? 0 }, set: { [weak self] in self?.radius = $0 })]
    }

    func encode(input: MTLTexture, previousFrame: MTLTexture, output: MTLTexture, encoder: MTLRenderCommandEncoder, elapsedTime: Float) {
        var params = BlurParams(radius: radius, _pad0: 0, _pad1: 0, _pad2: 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<BlurParams>.size, index: 0)
        FXFullscreenVertex.encode(encoder)
    }
}

private struct BlurParams {
    var radius: Float
    var _pad0: Float
    var _pad1: Float
    var _pad2: Float
}
