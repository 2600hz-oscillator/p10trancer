import CoreGraphics

/// Pure, UIKit-free lifecycle of the on-screen touch indicators.
///
/// The overlay view (`TouchRingView`) turns this state into CALayers, but
/// the decision logic — which touches are alive, where they are, and when
/// to fire an expanding ripple — lives here so it can be unit-tested with
/// no display, no swizzling, and no simulator audio HAL.
///
/// Touches are keyed by a caller-supplied stable id (the overlay uses one
/// id per `UITouch`), so multi-finger play tracks each finger
/// independently.
struct TouchRingModel {
    enum Phase { case began, moved, ended }

    /// A persistent "ring + dot" that follows one finger.
    struct Ring: Equatable {
        var id: Int
        var location: CGPoint
    }

    /// Live tracking rings, keyed by touch id.
    private(set) var rings: [Int: Ring] = [:]

    /// Touch-down points that still need a one-shot ripple spawned for
    /// them. Drained by the view each step.
    private(set) var pendingRipples: [CGPoint] = []

    var activeCount: Int { rings.count }

    /// Feed a touch event. Returns nothing; inspect `rings` /
    /// `drainRipples()` afterwards.
    mutating func apply(id: Int, phase: Phase, at point: CGPoint) {
        switch phase {
        case .began:
            rings[id] = Ring(id: id, location: point)
            pendingRipples.append(point)   // every touch-down ripples once
        case .moved:
            if rings[id] != nil { rings[id]?.location = point }
        case .ended:
            rings.removeValue(forKey: id)
        }
    }

    /// Hand the view the ripple origins queued since the last drain.
    mutating func drainRipples() -> [CGPoint] {
        defer { pendingRipples.removeAll() }
        return pendingRipples
    }

    /// Drop everything (presentation mode turned off / scene torn down).
    mutating func reset() {
        rings.removeAll()
        pendingRipples.removeAll()
    }
}
