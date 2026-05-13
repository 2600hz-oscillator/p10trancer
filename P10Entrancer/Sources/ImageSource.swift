import Metal
import MetalKit
import UIKit

@MainActor
final class ImageSource: PadSource {
    private(set) var currentTexture: MTLTexture?
    let displayAspect: Float

    init?(image: UIImage, context: MetalContext = .shared) {
        guard let cgImage = image.cgImage else { return nil }
        let loader = MTKTextureLoader(device: context.device)
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            .SRGB: NSNumber(value: false)
        ]
        do {
            self.currentTexture = try loader.newTexture(cgImage: cgImage, options: options)
        } catch {
            return nil
        }
        self.displayAspect = Float(cgImage.width) / Float(max(1, cgImage.height))
    }

    func tick(timestamp: CFTimeInterval) {}
}
