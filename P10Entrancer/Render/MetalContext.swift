import Metal
import MetalKit

final class MetalContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary

    static let shared: MetalContext = {
        guard let ctx = MetalContext() else {
            fatalError("Metal is required and not available on this device.")
        }
        return ctx
    }()

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        guard let queue = device.makeCommandQueue() else { return nil }
        guard let library = device.makeDefaultLibrary() else { return nil }
        self.device = device
        self.commandQueue = queue
        self.library = library
    }

    func makePipeline(vertex: String, fragment: String, pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private(set) lazy var blankTexture: MTLTexture = {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1, height: 1,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: descriptor) else {
            fatalError("Failed to create blank texture")
        }
        var pixel: UInt32 = 0xFF101010
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        return tex
    }()
}
