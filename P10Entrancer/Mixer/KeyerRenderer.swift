import Foundation
import Metal

@MainActor
final class KeyerRenderer {
    private(set) var outputTexture: MTLTexture?

    private let context: MetalContext
    private let pads: PadSystem
    private let keyer: KeyerState
    private let pipeline: MTLRenderPipelineState
    private var lastSize: (Int, Int) = (0, 0)

    /// Other renderers in the graph — populated AFTER all renderers
    /// exist (since keyers can reference each other). The renderer
    /// reads each reference's last-frame outputTexture, so cycles
    /// resolve naturally with one frame of latency per hop.
    var sourceResolver: ((SourceRef) -> MTLTexture?)?

    init(pads: PadSystem, keyer: KeyerState, context: MetalContext = .shared) throws {
        self.context = context
        self.pads = pads
        self.keyer = keyer
        self.pipeline = try context.makePipeline(
            vertex: "keyerVertex",
            fragment: "keyerFragment",
            pixelFormat: .bgra8Unorm
        )
    }

    func render() {
        guard let resolver = sourceResolver else {
            outputTexture = nil
            return
        }
        guard let fg = resolver(keyer.foregroundSource),
              let bg = resolver(keyer.backgroundSource) else {
            return
        }

        let w = max(fg.width, bg.width)
        let h = max(fg.height, bg.height)
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

        var params = KeyerParamsBuffer(
            kind: Int32(keyer.kind.rawValue),
            keyR: keyer.keyColor.x,
            keyG: keyer.keyColor.y,
            keyB: keyer.keyColor.z,
            threshold: keyer.threshold,
            softness: keyer.softness,
            _pad0: 0,
            _pad1: 0
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(fg, index: 0)
        encoder.setFragmentTexture(bg, index: 1)
        encoder.setFragmentBytes(&params, length: MemoryLayout<KeyerParamsBuffer>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        cmd.commit()
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
}

private struct KeyerParamsBuffer {
    var kind: Int32
    var keyR: Float
    var keyG: Float
    var keyB: Float
    var threshold: Float
    var softness: Float
    var _pad0: Float
    var _pad1: Float
}
