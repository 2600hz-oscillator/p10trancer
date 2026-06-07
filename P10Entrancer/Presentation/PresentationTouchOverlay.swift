#if DEBUG
import UIKit

/// A transparent, non-interactive window that floats above the whole app
/// and draws the neon touch indicators. It is installed on the MAIN
/// (interactive) scene; because presentation mode also drops the
/// program-out window so the external display falls back to system
/// hardware mirroring, everything drawn here is mirrored to HDMI for free
/// — including these rings — without a separate external draw path.
///
/// DEBUG-only: the whole presentation-mode feature is dev tooling for
/// recording training videos and never ships in a Release build.
@MainActor
final class PresentationTouchOverlay {
    private var window: PassthroughWindow?
    private let ringView = TouchRingView()
    /// Map each live `UITouch` to a stable integer id for the ring model.
    private var ids: [ObjectIdentifier: Int] = [:]
    private var nextID = 0

    func show() {
        ensureWindow()
        window?.isHidden = false
    }

    func hide() {
        window?.isHidden = true
        ringView.clearAll()
        ids.removeAll()
    }

    /// Called from the swizzled `UIWindow.sendEvent` on the main thread.
    /// We observe (never consume) touches and forward them to the ring
    /// view; the original `sendEvent` has already delivered them to the
    /// app, so pad multitouch is unaffected.
    func process(event: UIEvent, from sourceWindow: UIWindow) {
        guard window != nil, let touches = event.allTouches else { return }
        for touch in touches {
            let key = ObjectIdentifier(touch)
            let point = touch.location(in: sourceWindow)
            switch touch.phase {
            case .began:
                let id = nextID
                nextID &+= 1
                ids[key] = id
                ringView.handle(id: id, phase: .began, at: point)
            case .moved, .stationary:
                if let id = ids[key] {
                    ringView.handle(id: id, phase: .moved, at: point)
                }
            case .ended, .cancelled:
                if let id = ids.removeValue(forKey: key) {
                    ringView.handle(id: id, phase: .ended, at: point)
                }
            default:
                break   // hover / region phases — ignore
            }
        }
    }

    private func ensureWindow() {
        guard window == nil, let scene = Self.activeWindowScene() else { return }
        let w = PassthroughWindow(windowScene: scene)
        w.windowLevel = .statusBar + 100
        w.backgroundColor = .clear
        w.isUserInteractionEnabled = false

        let host = UIViewController()
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        ringView.frame = host.view.bounds
        ringView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        ringView.backgroundColor = .clear
        ringView.isUserInteractionEnabled = false
        host.view.addSubview(ringView)

        w.rootViewController = host
        w.isHidden = true
        window = w
    }

    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.session.role == .windowApplication && $0.activationState == .foregroundActive }
            ?? scenes.first { $0.session.role == .windowApplication }
    }
}

/// Never participates in hit-testing, so touches always fall through to
/// the app windows below it.
final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// Renders the neon dot/ring/ripple indicators with Core Animation.
/// Shares the touch-down → ripple rule with `TouchRingModel` so behaviour
/// stays in lockstep with the unit tests; persistent tracking rings are
/// driven directly by phase here.
final class TouchRingView: UIView {
    private var model = TouchRingModel()
    private var trackingLayers: [Int: CALayer] = [:]

    static let neon = UIColor(red: 0.16, green: 0.74, blue: 1.0, alpha: 1.0)

    func handle(id: Int, phase: TouchRingModel.Phase, at point: CGPoint) {
        model.apply(id: id, phase: phase, at: point)
        for origin in model.drainRipples() { spawnRipple(at: origin) }

        switch phase {
        case .began:
            let layer = makeTrackingRing(at: point)
            self.layer.addSublayer(layer)
            trackingLayers[id] = layer
        case .moved:
            guard let l = trackingLayers[id] else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)   // no implicit move animation
            l.position = point
            CATransaction.commit()
        case .ended:
            if let l = trackingLayers.removeValue(forKey: id) { fadeAndRemove(l) }
        }
    }

    func clearAll() {
        model.reset()
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        trackingLayers.removeAll()
    }

    // MARK: - Layer construction

    private func spawnRipple(at point: CGPoint) {
        let maxD = PresentationMetrics.rippleMaxDiameter
        let startD = PresentationMetrics.dotDiameter

        let ripple = CAShapeLayer()
        ripple.bounds = CGRect(x: 0, y: 0, width: maxD, height: maxD)
        ripple.position = point
        ripple.fillColor = UIColor.clear.cgColor
        ripple.strokeColor = Self.neon.cgColor
        ripple.lineWidth = PresentationMetrics.ringStroke
        applyGlow(to: ripple)

        let startPath = Self.centeredOval(diameter: startD, in: ripple.bounds)
        let endPath = Self.centeredOval(diameter: maxD - PresentationMetrics.ringStroke, in: ripple.bounds)
        ripple.path = endPath
        layer.addSublayer(ripple)

        // Animate the PATH (not transform.scale) so the ⅛″ stroke keeps
        // its width as the ring grows, matching the physical spec.
        let grow = CABasicAnimation(keyPath: "path")
        grow.fromValue = startPath
        grow.toValue = endPath
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = PresentationMetrics.rippleDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak ripple] in ripple?.removeFromSuperlayer() }
        ripple.add(group, forKey: "ripple")
        CATransaction.commit()
    }

    private func makeTrackingRing(at point: CGPoint) -> CALayer {
        let d = PresentationMetrics.trackingRingDiameter
        let container = CALayer()
        container.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        container.position = point

        let ring = CAShapeLayer()
        ring.bounds = container.bounds
        ring.position = CGPoint(x: d / 2, y: d / 2)
        let inset = PresentationMetrics.trackingRingStroke / 2
        ring.path = Self.centeredOval(diameter: d - inset * 2, in: container.bounds)
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = Self.neon.cgColor
        ring.lineWidth = PresentationMetrics.trackingRingStroke
        applyGlow(to: ring)
        container.addSublayer(ring)

        let dot = CAShapeLayer()
        dot.bounds = container.bounds
        dot.position = CGPoint(x: d / 2, y: d / 2)
        dot.path = Self.centeredOval(diameter: PresentationMetrics.dotDiameter, in: container.bounds)
        dot.fillColor = Self.neon.withAlphaComponent(0.9).cgColor
        applyGlow(to: dot)
        container.addSublayer(dot)

        return container
    }

    private func fadeAndRemove(_ l: CALayer) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.duration = PresentationMetrics.trackingFadeDuration
        fade.isRemovedOnCompletion = false
        fade.fillMode = .forwards
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak l] in l?.removeFromSuperlayer() }
        l.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    private func applyGlow(to l: CALayer) {
        l.shadowColor = Self.neon.cgColor
        l.shadowRadius = 8
        l.shadowOpacity = 0.9
        l.shadowOffset = .zero
    }

    private static func centeredOval(diameter: CGFloat, in bounds: CGRect) -> CGPath {
        let rect = CGRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        return UIBezierPath(ovalIn: rect).cgPath
    }
}
#endif
