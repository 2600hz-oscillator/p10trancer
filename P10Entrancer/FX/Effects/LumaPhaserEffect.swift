import Foundation
import Metal

@MainActor
final class LumaPhaserEffect: FXEffect {
    let name = "Luma Phaser"
    var isEnabled: Bool = false
    var phase: Float = 0.0
    var strength: Float = 0.3
    var curve: Float = 2.0
    var autoAnimate: Bool = true

    private let pipeline: MTLRenderPipelineState

    init(context: MetalContext = .shared) throws {
        self.pipeline = try context.makePipeline(
            vertex: "fxVertex",
            fragment: "fxLumaPhaserFragment",
            pixelFormat: .bgra8Unorm
        )
    }

    var parameters: [FXParameter] {
        [
            FXParameter(name: "Phase", range: 0...1, get: { [weak self] in self?.phase ?? 0 }, set: { [weak self] in self?.phase = $0 }),
            FXParameter(name: "Strength", range: 0...1, get: { [weak self] in self?.strength ?? 0 }, set: { [weak self] in self?.strength = $0 }),
            FXParameter(name: "Curve", range: 0.5...8, get: { [weak self] in self?.curve ?? 1 }, set: { [weak self] in self?.curve = $0 })
        ]
    }

    func encode(input: MTLTexture, previousFrame: MTLTexture, output: MTLTexture, encoder: MTLRenderCommandEncoder, elapsedTime: Float) {
        let activePhase = autoAnimate ? phase + elapsedTime * 0.25 : phase
        var params = LumaPhaserParams(phase: activePhase.truncatingRemainder(dividingBy: 1.0), strength: strength, curve: curve, _pad: 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<LumaPhaserParams>.size, index: 0)
        FXFullscreenVertex.encode(encoder)
    }
}

private struct LumaPhaserParams {
    var phase: Float
    var strength: Float
    var curve: Float
    var _pad: Float
}
