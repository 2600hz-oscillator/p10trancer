import UIKit
import MetalKit

@MainActor
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var presenter: ScreenPresenter?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        print("[ExternalDisplay] connecting, screen size: \(windowScene.screen.bounds.size)")

        Self.applyPreferredMode(to: windowScene)

        let window = UIWindow(windowScene: windowScene)
        window.overrideUserInterfaceStyle = .dark

        let mtkView = MTKView(frame: window.bounds, device: MetalContext.shared.device)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 60
        mtkView.autoResizeDrawable = true
        mtkView.translatesAutoresizingMaskIntoConstraints = false
        mtkView.layer.backgroundColor = UIColor.black.cgColor

        if let metalLayer = mtkView.layer as? CAMetalLayer {
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
        }

        let host = UIViewController()
        host.view.backgroundColor = .black
        host.view.addSubview(mtkView)
        NSLayoutConstraint.activate([
            mtkView.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            mtkView.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            mtkView.topAnchor.constraint(equalTo: host.view.topAnchor),
            mtkView.bottomAnchor.constraint(equalTo: host.view.bottomAnchor)
        ])

        window.rootViewController = host
        window.isHidden = false

        let appState = AppState.shared
        appState.startIfNeeded()
        let presenter = try! ScreenPresenter(mixerOffscreen: appState.masterMixerOffscreen)
        presenter.attach(view: mtkView)
        RenderEngine.shared.register(presenter)
        RenderEngine.shared.start()

        self.window = window
        self.presenter = presenter
        print("[ExternalDisplay] window ready at \(window.bounds.size)")
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        print("[ExternalDisplay] disconnected")
        presenter = nil
        window = nil
    }

    private static func applyPreferredMode(to windowScene: UIWindowScene) {
        let screen = windowScene.screen
        let modes = screen.availableModes
        guard !modes.isEmpty else { return }
        let preferred = modes.max { lhs, rhs in
            (lhs.size.width * lhs.size.height) < (rhs.size.width * rhs.size.height)
        }
        if let preferred = preferred {
            screen.currentMode = preferred
            print("[ExternalDisplay] mode: \(Int(preferred.size.width))x\(Int(preferred.size.height))")
        }
        screen.overscanCompensation = .none
    }
}
