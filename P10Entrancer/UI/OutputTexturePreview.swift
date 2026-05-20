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
        // Explicit black clear so undefined / partial-write frames
        // (the first few ticks while the FX renderer warms up or
        // while SwiftUI's layout is still resolving the drawable
        // size) come up solid black instead of a stale-memory slash.
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
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

        /// Throttle thumbnail previews to ~15 fps (every 4 ticks at
        /// 60 fps). The async Task hop that used to be here drifted
        /// the read across frame boundaries from the underlying FX
        /// renderer's writes, causing visible jitter; the
        /// synchronous direct-draw eliminates that drift, and lower
        /// cadence keeps the GPU cost modest with N previews on
        /// screen.
        func render(frameIndex: UInt64, elapsedTime: CFTimeInterval) {
            guard frameIndex % 4 == 0 else { return }
            drawFrame()
        }

        private func drawFrame() {
            guard let view = view else { return }
            // Skip ticks where the drawable is too small to be a real
            // pad cell — SwiftUI emits intermediate layout passes at
            // 0×0 / 1×N before the GeometryReader settles. Drawing
            // into those produces the "slash of content at the top"
            // visual that bleeds through after the drawable expands.
            let size = view.drawableSize
            guard size.width >= 16, size.height >= 16 else { return }
            guard let drawable = view.currentDrawable,
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
