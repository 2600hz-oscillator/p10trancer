import SwiftUI
import MetalKit

struct OutputPreviewView: UIViewRepresentable {
    let mixerOffscreen: MasterMixerOffscreen

    func makeCoordinator() -> ScreenPresenter {
        try! ScreenPresenter(mixerOffscreen: mixerOffscreen)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MetalContext.shared.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = true
        context.coordinator.attach(view: view)
        RenderEngine.shared.register(context.coordinator)
        RenderEngine.shared.start()
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
