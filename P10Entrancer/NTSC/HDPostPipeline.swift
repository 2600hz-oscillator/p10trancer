import Foundation
import Metal

/// Single-pass HD output post-processing. Applies HDPostState's
/// gamma / contrast / saturation / brightness / bloom on top of the
/// master mixer's output. Only active when outputMode == .hd720p;
/// MasterMixerOffscreen.currentOutputTexture routes here.
@MainActor
final class HDPostPipeline {
    private(set) var outputTexture: MTLTexture?

    private let context: MetalContext
    private let state: HDPostState
    private let pipeline: MTLRenderPipelineState
    private var lastInputSize: (Int, Int) = (0, 0)

    init(state: HDPostState, context: MetalContext = .shared) throws {
        self.context = context
        self.state = state
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = context.library.makeFunction(name: "hdPostVertex")
        desc.fragmentFunction = context.library.makeFunction(name: "hdPostFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.pipeline = try context.device.makeRenderPipelineState(descriptor: desc)
    }

    func render(input: MTLTexture) {
        let w = input.width
        let h = input.height
        if (w, h) != lastInputSize {
            outputTexture = makeOutput(width: w, height: h)
            lastInputSize = (w, h)
        }
        guard let outputTexture = outputTexture else { return }
        guard let cmd = context.commandQueue.makeCommandBuffer() else { return }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = outputTexture
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = cmd.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        var params = HDPostParamsBuffer(
            gamma: state.gamma,
            contrast: state.contrast,
            saturation: state.saturation,
            brightness: state.brightness,
            bloom: state.bloom,
            bloomThresh: state.bloomThresh,
            _pad0: 0,
            _pad1: 0
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<HDPostParamsBuffer>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        cmd.commit()
    }

    private func makeOutput(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .private
        return context.device.makeTexture(descriptor: desc)
    }
}

private struct HDPostParamsBuffer {
    var gamma: Float
    var contrast: Float
    var saturation: Float
    var brightness: Float
    var bloom: Float
    var bloomThresh: Float
    var _pad0: Float
    var _pad1: Float
}
