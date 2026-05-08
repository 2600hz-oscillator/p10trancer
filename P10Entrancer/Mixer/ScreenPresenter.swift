import Foundation
import Metal
import MetalKit

@MainActor
final class ScreenPresenter: NSObject, FrameRenderer, MTKViewDelegate {
    private weak var view: MTKView?
    private let context = MetalContext.shared
    private let mixerOffscreen: MasterMixerOffscreen
    private let pipeline: MTLRenderPipelineState

    init(mixerOffscreen: MasterMixerOffscreen) throws {
        self.mixerOffscreen = mixerOffscreen
        self.pipeline = try context.makePipeline(
            vertex: "passthroughVertex",
            fragment: "passthroughFragment",
            pixelFormat: .bgra8Unorm
        )
        super.init()
    }

    func attach(view: MTKView) {
        self.view = view
        view.delegate = self
    }

    func render(frameIndex: UInt64, elapsedTime: CFTimeInterval) {
        view?.draw()
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private var loggedAspect = false

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let cmd = context.commandQueue.makeCommandBuffer(),
              let encoder = cmd.makeRenderCommandEncoder(descriptor: descriptor),
              let source = mixerOffscreen.currentOutputTexture
        else { return }

        let drawableW = Float(view.drawableSize.width)
        let drawableH = Float(view.drawableSize.height)
        let srcW = Float(source.width)
        let srcH = Float(source.height)
        let drawableAspect = drawableW / max(drawableH, 1)
        let srcAspect = srcW / max(srcH, 1)

        var params = PassthroughParams(
            aspectScaleX: drawableAspect > srcAspect ? drawableAspect / srcAspect : 1.0,
            aspectScaleY: drawableAspect > srcAspect ? 1.0 : srcAspect / drawableAspect,
            _pad0: 0,
            _pad1: 0
        )

        if !loggedAspect {
            loggedAspect = true
            P10Logger.log("[ScreenPresenter] drawable=\(Int(drawableW))x\(Int(drawableH)) src=\(Int(srcW))x\(Int(srcH)) dAspect=\(drawableAspect) sAspect=\(srcAspect) scaleX=\(params.aspectScaleX) scaleY=\(params.aspectScaleY)")
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<PassthroughParams>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

private struct PassthroughParams {
    var aspectScaleX: Float
    var aspectScaleY: Float
    var _pad0: Float
    var _pad1: Float
}
