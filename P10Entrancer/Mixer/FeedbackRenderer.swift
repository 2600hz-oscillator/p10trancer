import Foundation
import Metal

/// Renders one feedback unit's composite per frame. Ping-pongs between
/// two textures so each frame's output can sample the previous frame's
/// content. The shader applies the (zoom, pan, tilt) transform to the
/// previous-frame sample, producing the recursive camera-on-monitor
/// fractal effect when zoom > 1.
@MainActor
final class FeedbackRenderer {
    var outputTexture: MTLTexture? { useA ? texA : texB }

    private let context: MetalContext
    private let pads: PadSystem
    private let state: FeedbackState
    private let pipeline: MTLRenderPipelineState

    private var texA: MTLTexture?
    private var texB: MTLTexture?
    private var useA = true
    private var lastSize: (Int, Int) = (0, 0)

    /// Resolves the current input source (pad or keyer) to a texture.
    /// Set after all renderers exist so the feedback unit can reference
    /// keyer outputs as inputs.
    var sourceResolver: ((SourceRef) -> MTLTexture?)?

    init(pads: PadSystem, state: FeedbackState, context: MetalContext = .shared) throws {
        self.context = context
        self.pads = pads
        self.state = state
        self.pipeline = try context.makePipeline(
            vertex: "feedbackCameraVertex",
            fragment: "feedbackCameraFragment",
            pixelFormat: .bgra8Unorm
        )
    }

    func render() {
        guard let resolver = sourceResolver else { return }
        guard let src = resolver(state.inputSource) else { return }

        let w = src.width
        let h = src.height
        if (w, h) != lastSize || texA == nil || texB == nil {
            texA = makeTexture(width: w, height: h)
            texB = makeTexture(width: w, height: h)
            lastSize = (w, h)
            // First frame: clear both so the initial sample of "prev" doesn't
            // pull garbage memory.
            clear(texA)
            clear(texB)
        }
        guard let texA = texA, let texB = texB else { return }

        let (dest, prev): (MTLTexture, MTLTexture) = useA ? (texA, texB) : (texB, texA)

        guard let cmd = context.commandQueue.makeCommandBuffer() else { return }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = dest
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = cmd.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        // Map normalized tilt -1…1 → radians -π/2…π/2 (90° in either direction).
        let tiltRadians = state.tilt * Float.pi / 2
        var params = FeedbackParamsBuffer(
            zoom: state.zoom,
            panX: state.panX,
            panY: state.panY,
            tilt: tiltRadians,
            decay: state.decay,
            feedbackMix: state.feedbackMix,
            luminosity: state.luminosity,
            chromaBoost: state.chromaBoost
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(src, index: 0)
        encoder.setFragmentTexture(prev, index: 1)
        encoder.setFragmentBytes(&params, length: MemoryLayout<FeedbackParamsBuffer>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        cmd.commit()

        useA.toggle()
    }

    private func makeTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        return context.device.makeTexture(descriptor: descriptor)
    }

    private func clear(_ tex: MTLTexture?) {
        guard let tex = tex,
              let cmd = context.commandQueue.makeCommandBuffer() else { return }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = tex
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = cmd.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.endEncoding()
        cmd.commit()
    }
}

private struct FeedbackParamsBuffer {
    var zoom: Float
    var panX: Float
    var panY: Float
    var tilt: Float
    var decay: Float
    var feedbackMix: Float
    var luminosity: Float
    var chromaBoost: Float
}
