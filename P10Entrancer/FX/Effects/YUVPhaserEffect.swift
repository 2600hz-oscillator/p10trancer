import Foundation
import Metal

@MainActor
final class YUVPhaserEffect: FXEffect {
    let name = "YUV Phaser"
    var isEnabled: Bool = false
    var phase: Float = 0.0
    var depth: Float = 0.5
    var autoAnimate: Bool = true

    private let pipeline: MTLRenderPipelineState

    init(context: MetalContext = .shared) throws {
        self.pipeline = try context.makePipeline(
            vertex: "fxVertex",
            fragment: "fxYUVPhaserFragment",
            pixelFormat: .bgra8Unorm
        )
    }

    var parameters: [FXParameter] {
        [
            FXParameter(name: "Phase", range: 0...1, get: { [weak self] in self?.phase ?? 0 }, set: { [weak self] in self?.phase = $0 }),
            FXParameter(name: "Depth", range: 0...1, get: { [weak self] in self?.depth ?? 0 }, set: { [weak self] in self?.depth = $0 })
        ]
    }

    func encode(input: MTLTexture, previousFrame: MTLTexture, output: MTLTexture, encoder: MTLRenderCommandEncoder, elapsedTime: Float) {
        let activePhase = autoAnimate ? phase + elapsedTime * 0.15 : phase
        var params = YUVPhaserParams(phase: activePhase.truncatingRemainder(dividingBy: 1.0), depth: depth, _pad0: 0, _pad1: 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<YUVPhaserParams>.size, index: 0)
        FXFullscreenVertex.encode(encoder)
    }
}

private struct YUVPhaserParams {
    var phase: Float
    var depth: Float
    var _pad0: Float
    var _pad1: Float
}
