import SwiftUI
import MetalKit

/// Lightweight MTKView wrapper that draws whatever texture the closure
/// returns each frame. Used by OutputPadCell to preview a keyer or
/// feedback unit's last-frame output without owning rendering itself.
struct OutputTexturePreview: UIViewRepresentable {
    let texture: () -> MTLTexture?

    func makeCoordinator() -> Coordinator {
        Coordinator(textureProvider: texture)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MetalContext.shared.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = true
        view.delegate = context.coordinator
        context.coordinator.attach(view: view)
        RenderEngine.shared.register(context.coordinator)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate, FrameRenderer {
        private let textureProvider: () -> MTLTexture?
        private weak var view: MTKView?
        private let pipeline: MTLRenderPipelineState?

        init(textureProvider: @escaping () -> MTLTexture?) {
            self.textureProvider = textureProvider
            // Reuse the keyer's vertex/fragment for a simple textured
            // quad — we just want to copy a texture into the drawable.
            self.pipeline = try? MetalContext.shared.makePipeline(
                vertex: "outputPreviewVertex",
                fragment: "outputPreviewFragment",
                pixelFormat: .bgra8Unorm
            )
        }

        func attach(view: MTKView) { self.view = view }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {}

        nonisolated func render(frameIndex: UInt64, elapsedTime: CFTimeInterval) {
            Task { @MainActor in self.drawFrame() }
        }

        private func drawFrame() {
            guard let view = view,
                  let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor,
                  let pipeline = pipeline,
                  let cmd = MetalContext.shared.commandQueue.makeCommandBuffer(),
                  let encoder = cmd.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }
            if let tex = textureProvider() {
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(tex, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            encoder.endEncoding()
            cmd.present(drawable)
            cmd.commit()
        }
    }
}
