import UIKit
import MetalKit
#if DEBUG
import Combine
#endif

@MainActor
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var presenter: ScreenPresenter?
    private weak var owningScene: UIWindowScene?
    #if DEBUG
    private var presentationCancellable: AnyCancellable?
    #endif

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        self.owningScene = windowScene
        print("[ExternalDisplay] connecting, screen size: \(windowScene.screen.bounds.size)")

        AppState.shared.startIfNeeded()

        #if DEBUG
        // Presentation mode mirrors the whole iPad UI to HDMI. The OS
        // mirrors an external scene only while we DON'T own a window on it;
        // creating one (program-out) kicks it out of mirroring. So we map
        // presentation-mode → no window (mirror), normal → program-out
        // window, and flip live as the toggle changes (no reconnect).
        presentationCancellable = AppState.shared.$presentationModeEnabled
            .removeDuplicates()
            .sink { [weak self] present in
                self?.applyExternalContent(presentationMode: present)
            }
        applyExternalContent(presentationMode: AppState.shared.presentationModeEnabled)
        #else
        showProgramOut(on: windowScene)
        #endif

        print("[ExternalDisplay] window ready: \(window?.bounds.size as Any)")
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        print("[ExternalDisplay] disconnected")
        teardownWindow()
        owningScene = nil
        #if DEBUG
        presentationCancellable = nil
        #endif
    }

    #if DEBUG
    private func applyExternalContent(presentationMode: Bool) {
        guard let windowScene = owningScene else { return }
        if presentationMode {
            // Drop our window → scene falls back to system hardware mirroring
            // of the whole iPad UI (incl. the neon touch overlay).
            teardownWindow()
        } else if window == nil {
            showProgramOut(on: windowScene)
        }
    }
    #endif

    /// Releasing the presenter is enough to stop it rendering: RenderEngine
    /// holds renderers weakly and prunes dead ones each tick. Niling the
    /// window releases the MTKView (held weakly by the presenter).
    private func teardownWindow() {
        presenter = nil
        window?.isHidden = true
        window = nil
    }

    private func showProgramOut(on windowScene: UIWindowScene) {
        guard window == nil else { return }
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
        let presenter = try! ScreenPresenter(mixerOffscreen: appState.masterMixerOffscreen)
        presenter.attach(view: mtkView)
        RenderEngine.shared.register(presenter)
        RenderEngine.shared.start()

        self.window = window
        self.presenter = presenter
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
