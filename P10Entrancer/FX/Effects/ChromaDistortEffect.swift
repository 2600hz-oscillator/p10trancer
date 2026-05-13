import Foundation
import Metal

@MainActor
final class ChromaDistortEffect: FXEffect {
    let name = "Chroma"
    var isEnabled: Bool = false
    var hueShift: Float = 0.0
    var saturation: Float = 1.5
    var channelOffset: Float = 0.5

    private let pipeline: MTLRenderPipelineState

    init(context: MetalContext = .shared) throws {
        self.pipeline = try context.makePipeline(
            vertex: "fxVertex",
            fragment: "fxChromaDistortFragment",
            pixelFormat: .bgra8Unorm
        )
    }

    var parameters: [FXParameter] {
        [
            FXParameter(name: "Hue", range: 0...1, get: { [weak self] in self?.hueShift ?? 0 }, set: { [weak self] in self?.hueShift = $0 }),
            FXParameter(name: "Saturation", range: 0...3, get: { [weak self] in self?.saturation ?? 1 }, set: { [weak self] in self?.saturation = $0 }),
            FXParameter(name: "RGB Split", range: 0...3, get: { [weak self] in self?.channelOffset ?? 0 }, set: { [weak self] in self?.channelOffset = $0 })
        ]
    }

    func encode(input: MTLTexture, previousFrame: MTLTexture, output: MTLTexture, encoder: MTLRenderCommandEncoder, elapsedTime: Float) {
        var params = ChromaDistortParams(hueShift: hueShift, saturation: saturation, channelOffset: channelOffset, _pad: 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<ChromaDistortParams>.size, index: 0)
        FXFullscreenVertex.encode(encoder)
    }
}

private struct ChromaDistortParams {
    var hueShift: Float
    var saturation: Float
    var channelOffset: Float
    var _pad: Float
}
