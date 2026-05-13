import Metal
import QuartzCore

@MainActor
protocol PadSource: AnyObject {
    var currentTexture: MTLTexture? { get }
    var displayAspect: Float { get }
    func tick(timestamp: CFTimeInterval)
}

extension PadSource {
    var displayAspect: Float { 16.0 / 9.0 }
}
