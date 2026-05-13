import Foundation
import Metal

/// Renders one XYZ unit as a forward-scatter raster scope. The
/// vertex shader walks a grid of source-pixel sample points; the
/// renderer issues one indexed draw call per frame with line-list
/// topology so each row becomes a series of line segments between
/// adjacent column samples. Luma displaces each vertex by the
/// configured X/Y amount — bright source pixels push their
/// scanline outward, producing the classic Rutt-Etra heightmap
/// look. Additive blending keeps overlapping scanlines from
/// occluding each other (CRT phosphor-style).
@MainActor
final class XYZRenderer {
    private(set) var outputTexture: MTLTexture?

    /// Wired by MasterMixerOffscreen so XYZ can read another
    /// unit's last-frame output texture (1-frame lag resolves
    /// cycles, matching keyer + feedback).
    var sourceResolver: ((SourceRef) -> MTLTexture?)?

    /// Grid resolution. 320×180 = 57,600 vertex samples per frame —
    /// runs comfortably on M2, dense enough to look like a real
    /// scanline raster but sparse enough that the heightmap
    /// displacement reads clearly.
    private static let cols: Int = 320
    private static let rows: Int = 180

    private let context: MetalContext
    private let state: XYZState
    private let pipeline: MTLRenderPipelineState
    private let indexBuffer: MTLBuffer
    private let indexCount: Int
    private var lastSize: (Int, Int) = (0, 0)

    init(state: XYZState, context: MetalContext = .shared) throws {
        self.context = context
        self.state = state

        // Manual pipeline build — we need line topology + additive
        // blending, neither of which MetalContext.makePipeline
        // exposes today.
        let library = context.library
        guard let vfn = library.makeFunction(name: "xyzVertex"),
              let ffn = library.makeFunction(name: "xyzFragment") else {
            throw NSError(domain: "XYZRenderer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "xyzVertex / xyzFragment not in library"])
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        // Source contribution scaled by its own value (so brighter
        // segments push harder); destination kept (additive).
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .one
        self.pipeline = try context.device.makeRenderPipelineState(descriptor: desc)

        // Index buffer: line list connecting adjacent columns in
        // each row. 2 * (cols-1) * rows indices. UInt32 because
        // 320×180 = 57,600 vertex indices still fits in UInt16, but
        // we keep UInt32 to allow scaling up without re-allocating.
        let cols = Self.cols
        let rows = Self.rows
        var indices: [UInt32] = []
        indices.reserveCapacity(2 * (cols - 1) * rows)
        for r in 0..<rows {
            for c in 0..<(cols - 1) {
                indices.append(UInt32(r * cols + c))
                indices.append(UInt32(r * cols + c + 1))
            }
        }
        self.indexCount = indices.count
        guard let buf = context.device.makeBuffer(
            bytes: indices,
            length: indices.count * MemoryLayout<UInt32>.size,
            options: [.storageModeShared]
        ) else {
            throw NSError(domain: "XYZRenderer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "index buffer alloc failed"])
        }
        self.indexBuffer = buf
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
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
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
            yPhase: state.yPhase,
            cols: UInt32(Self.cols),
            rows: UInt32(Self.rows)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexTexture(src, index: 0)
        encoder.setVertexBytes(&params, length: MemoryLayout<XYZParamsBuffer>.size, index: 0)
        encoder.drawIndexedPrimitives(
            type: .line,
            indexCount: indexCount,
            indexType: .uint32,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )
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
    var cols: UInt32
    var rows: UInt32
}
