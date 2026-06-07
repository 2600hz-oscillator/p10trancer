import CoreGraphics

/// Physical sizing for the presentation-mode touch indicators.
///
/// All iPads since the M-series (incl. iPad Pro M2 / iPad Air M2) render
/// at 264 physical ppi with a 2× backing scale, which is exactly
/// **132 points per physical inch**. Sizing the neon rings in points off
/// that constant makes them land at the intended real-world diameter on
/// the device glass (and, mirrored, proportionally on the HDMI frame).
///
/// Pure value type with no UIKit/side effects so it is unit-testable and
/// safe to compile into any configuration; nothing drives it unless
/// presentation mode (DEBUG-only) is active.
enum PresentationMetrics {
    /// Logical points per physical inch on an M-series iPad (264 ppi ÷ 2×).
    static let pointsPerInch: CGFloat = 132

    static func points(inches: CGFloat) -> CGFloat { inches * pointsPerInch }

    /// Solid neon dot at the exact touch point — spec: ¼″.
    static var dotDiameter: CGFloat { points(inches: 0.25) }        // 33 pt

    /// Stroke width of the expanding ripple ring — spec: ⅛″.
    static var ringStroke: CGFloat { points(inches: 0.125) }        // 16.5 pt

    /// Ripple grows from `dotDiameter` to this, then fades — spec: ¾″.
    static var rippleMaxDiameter: CGFloat { points(inches: 0.75) }  // 99 pt

    /// Ripple expand-and-vanish duration — spec: 250 ms.
    static let rippleDuration: CFTimeInterval = 0.25

    /// While a finger is held/dragged, a persistent "ring with a dot in
    /// the centre" tracks it. Sized between the dot and the ripple max so
    /// it reads clearly as a circle around the dot without being huge.
    static var trackingRingDiameter: CGFloat { points(inches: 0.45) } // ~59.4 pt
    static var trackingRingStroke: CGFloat { 4 }

    /// Fade-out applied to the tracking ring on touch-up (so a quick tap
    /// shows the dot momentarily, then it clears).
    static let trackingFadeDuration: CFTimeInterval = 0.15
}
