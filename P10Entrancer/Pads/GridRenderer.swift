import Foundation
import Metal
import MetalKit

@MainActor
final class GridRenderer: NSObject, FrameRenderer, MTKViewDelegate {
    private weak var view: MTKView?
    private let context = MetalContext.shared
    private let pads: PadSystem
    private var pipeline: MTLRenderPipelineState?

    init(pads: PadSystem) {
        self.pads = pads
        super.init()
    }

    func attach(view: MTKView) {
        self.view = view
        view.delegate = self
        do {
            self.pipeline = try context.makePipeline(
                vertex: "gridVertex",
                fragment: "gridFragment",
                pixelFormat: view.colorPixelFormat
            )
        } catch {
            assertionFailure("Grid pipeline failed: \(error)")
        }
    }

    func render(frameIndex: UInt64, elapsedTime: CFTimeInterval) {
        pads.tick(timestamp: elapsedTime)
        view?.draw()
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline = pipeline,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let cmd = context.commandQueue.makeCommandBuffer(),
              let encoder = cmd.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        let drawableW = Float(view.drawableSize.width)
        let drawableH = Float(view.drawableSize.height)
        let cellAspect: Float = (drawableW / 3.0) / max(drawableH / 3.0, 1)
        var params = GridParamsBuffer(cellAspect: cellAspect, _pad0: 0, _pad1: 0, _pad2: 0)
        var aspects: [Float] = pads.pads.map { $0.aspect }
        while aspects.count < 9 { aspects.append(16.0 / 9.0) }

        encoder.setRenderPipelineState(pipeline)
        let blank = context.blankTexture
        for i in 0..<PadSystem.padCount {
            encoder.setFragmentTexture(pads.pads[i].texture ?? blank, index: i)
        }
        encoder.setFragmentBytes(&params, length: MemoryLayout<GridParamsBuffer>.size, index: 0)
        encoder.setFragmentBytes(&aspects, length: MemoryLayout<Float>.size * 9, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

private struct GridParamsBuffer {
    var cellAspect: Float
    var _pad0: Float
    var _pad1: Float
    var _pad2: Float
}
