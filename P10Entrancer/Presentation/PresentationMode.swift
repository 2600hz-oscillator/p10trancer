#if DEBUG
import UIKit
import ObjectiveC

/// Coordinates presentation mode: the neon touch overlay on the main
/// scene. The external-display side (drop the program-out window so the
/// scene falls back to system mirroring) is handled in
/// `ExternalDisplaySceneDelegate`, which observes
/// `AppState.presentationModeEnabled` directly.
///
/// Touches are observed by swizzling `UIWindow.sendEvent(_:)` — the
/// App-Store-safe `TouchVisualizer`/`COSTouchVisualizer` technique. We
/// always call the original implementation first, so the app receives
/// every touch normally; we only mirror them into the overlay. The whole
/// feature (and this swizzle) is DEBUG-only and never compiled into a
/// shipping build.
@MainActor
final class PresentationMode {
    static let shared = PresentationMode()

    private(set) var isActive = false
    private var swizzleInstalled = false
    private let overlay = PresentationTouchOverlay()

    private init() {}

    func setEnabled(_ enabled: Bool) {
        guard enabled != isActive else { return }
        isActive = enabled
        if enabled {
            installSwizzleIfNeeded()
            overlay.show()
        } else {
            overlay.hide()
        }
    }

    /// Entry point from the swizzled `sendEvent`. Cheap no-op when off.
    func process(event: UIEvent, in window: UIWindow) {
        guard isActive, event.type == .touches else { return }
        overlay.process(event: event, from: window)
    }

    private func installSwizzleIfNeeded() {
        guard !swizzleInstalled else { return }
        swizzleInstalled = true
        guard
            let original = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))),
            let replacement = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.pm_sendEvent(_:)))
        else { return }
        method_exchangeImplementations(original, replacement)
    }
}

private extension UIWindow {
    /// After `method_exchangeImplementations`, this selector points at the
    /// ORIGINAL `sendEvent`, so calling `pm_sendEvent` here invokes it.
    @objc func pm_sendEvent(_ event: UIEvent) {
        pm_sendEvent(event)
        // UIKit delivers events on the main thread; assert isolation to
        // reach the @MainActor singleton without an extra hop (which would
        // re-order touches relative to the app's own handling).
        MainActor.assumeIsolated {
            PresentationMode.shared.process(event: event, in: self)
        }
    }
}
#endif
