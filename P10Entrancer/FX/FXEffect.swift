import Foundation
import Metal

@MainActor
protocol FXEffect: AnyObject {
    var isEnabled: Bool { get set }
    var name: String { get }
    var parameters: [FXParameter] { get }
    func encode(
        input: MTLTexture,
        previousFrame: MTLTexture,
        output: MTLTexture,
        encoder: MTLRenderCommandEncoder,
        elapsedTime: Float
    )
}

@MainActor
final class FXParameter: Identifiable {
    let id = UUID()
    let name: String
    let range: ClosedRange<Float>
    private let getter: () -> Float
    private let setter: (Float) -> Void

    init(name: String, range: ClosedRange<Float>, get: @escaping () -> Float, set: @escaping (Float) -> Void) {
        self.name = name
        self.range = range
        self.getter = get
        self.setter = set
    }

    var value: Float {
        get { getter() }
        set { setter(newValue) }
    }
}

struct FXFullscreenVertex {
    static func encode(_ encoder: MTLRenderCommandEncoder) {
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
