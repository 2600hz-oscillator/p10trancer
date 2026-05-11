import Foundation
import Metal

/// Renders one XYZ unit per frame using the fused Rutt-Etra +
/// shaped-ramps fragment shader. Same shape as KeyerRenderer /
/// FeedbackRenderer: takes a `sourceResolver` closure to look up
/// input textures by SourceRef so the input can be any pad, keyer,
/// or feedback output.
@MainActor
final class XYZRenderer {
    private(set) var outputTexture: MTLTexture?

    /// Wired by MasterMixerOffscreen after all renderers exist so
    /// XYZ can read another unit's output by reference (1-frame lag
    /// resolves cycles, matching the keyer + feedback pattern).
    var sourceResolver: ((SourceRef) -> MTLTexture?)?

    private let context: MetalContext
    private let state: XYZState
    private let pipeline: MTLRenderPipelineState
    private var lastSize: (Int, Int) = (0, 0)

    init(state: XYZState, context: MetalContext = .shared) throws {
        self.context = context
        self.state = state
        self.pipeline = try context.makePipeline(
            vertex: "xyzVertex",
            fragment: "xyzFragment",
            pixelFormat: .bgra8Unorm
        )
    }

    func render() {
        guard let resolver = sourceResolver else { return }
        guard let src = resolver(state.inputSource) else { return }
        let w = src.width
        let h = src.height
        if (w, h) != lastSize || outputTexture == nil {
            outputTexture = makeTexture(width: w, height: h)
            lastSize = (w, h)
        }
        guard let outputTexture = outputTexture else { return }
        guard let cmd = context.commandQueue.makeCommandBuffer() else { return }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = outputTexture
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = cmd.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        var params = XYZParamsBuffer(
            xShape: state.xShape,
            yShape: state.yShape,
            xDisp: state.xDisp,
            yDisp: state.yDisp,
            intensity: state.intensity,
            tintR: state.tintR,
            tintG: state.tintG,
            tintB: state.tintB,
            xFreq: state.xFreq,
            yFreq: state.yFreq,
            xPhase: state.xPhase,
            yPhase: state.yPhase
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(src, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<XYZParamsBuffer>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        cmd.commit()
    }

    private func makeTexture(width: Int, height: Int) -> MTLTexture? {
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

private struct XYZParamsBuffer {
    var xShape: Float
    var yShape: Float
    var xDisp: Float
    var yDisp: Float
    var intensity: Float
    var tintR: Float
    var tintG: Float
    var tintB: Float
    var xFreq: Float
    var yFreq: Float
    var xPhase: Float
    var yPhase: Float
}
