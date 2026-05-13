import Metal
import CoreVideo

/// Center-crops a camera frame to a fixed 4:3 aspect ratio. Owned by the
/// camera source; produces a stable 4:3 texture regardless of whether the
/// underlying sensor frame arrives in landscape (sensor native), portrait
/// (post-rotation), or some other ratio.
@MainActor
final class CameraCrop4x3 {
    static let aspect: Float = 4.0 / 3.0

    private let context: MetalContext
    private var croppedTexture: MTLTexture?
    private var lastSrcSize: (Int, Int) = (0, 0)
    private var lastCropOrigin: (Int, Int) = (0, 0)
    private var lastCropSize: (Int, Int) = (0, 0)

    init(context: MetalContext = .shared) {
        self.context = context
    }

    /// Returns a 4:3 center-cropped copy of `source`. Pool-allocated so each
    /// call costs one blit + one (small) allocation only on resize.
    func crop(_ source: MTLTexture) -> MTLTexture? {
        let srcW = source.width
        let srcH = source.height
        guard srcW > 0, srcH > 0 else { return nil }

        // Compute the largest 4:3 rectangle that fits inside the source.
        let target: Float = Self.aspect
        var cropW = srcW
        var cropH = srcH
        let srcAspect = Float(srcW) / Float(srcH)
        if srcAspect > target {
            // Source wider than 4:3 → crop horizontally.
            cropW = Int((Float(srcH) * target).rounded())
        } else if srcAspect < target {
            // Source taller than 4:3 → crop vertically.
            cropH = Int((Float(srcW) / target).rounded())
        }
        // Round to even values so blit doesn't choke on odd-pixel sizes.
        cropW = max(2, cropW & ~1)
        cropH = max(2, cropH & ~1)
        let originX = (srcW - cropW) / 2
        let originY = (srcH - cropH) / 2

        if (srcW, srcH) != lastSrcSize ||
           (originX, originY) != lastCropOrigin ||
           (cropW, cropH) != lastCropSize ||
           croppedTexture == nil {
            croppedTexture = makeTexture(width: cropW, height: cropH)
            lastSrcSize = (srcW, srcH)
            lastCropOrigin = (originX, originY)
            lastCropSize = (cropW, cropH)
        }
        guard let dest = croppedTexture else { return nil }

        guard let cmd = context.commandQueue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else { return nil }
        blit.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: originX, y: originY, z: 0),
            sourceSize: MTLSize(width: cropW, height: cropH, depth: 1),
            to: dest,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        cmd.commit()
        return dest
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
