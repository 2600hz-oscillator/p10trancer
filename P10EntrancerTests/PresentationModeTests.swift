import XCTest
import CoreGraphics
@testable import P10Entrancer

/// Unit coverage for presentation mode's pure cores — the physical sizing
/// of the neon indicators and the touch lifecycle that decides when to
/// ripple / track / clear. No display, no swizzling, no audio HAL, so
/// these run on the simulator and device alike.
final class PresentationModeTests: XCTestCase {

    // MARK: - PresentationMetrics

    func test_metrics_physical_sizes_on_m_series_ipad() {
        // 264 ppi ÷ 2× backing scale = 132 pt/inch.
        XCTAssertEqual(PresentationMetrics.pointsPerInch, 132, accuracy: 0.0001)
        XCTAssertEqual(PresentationMetrics.dotDiameter, 33, accuracy: 0.0001)        // ¼″
        XCTAssertEqual(PresentationMetrics.ringStroke, 16.5, accuracy: 0.0001)       // ⅛″
        XCTAssertEqual(PresentationMetrics.rippleMaxDiameter, 99, accuracy: 0.0001)  // ¾″
        XCTAssertEqual(PresentationMetrics.rippleDuration, 0.25, accuracy: 0.0001)
    }

    func test_metrics_inch_to_point_conversion() {
        XCTAssertEqual(PresentationMetrics.points(inches: 1), 132, accuracy: 0.0001)
        XCTAssertEqual(PresentationMetrics.points(inches: 0.5), 66, accuracy: 0.0001)
    }

    func test_tracking_ring_sits_between_dot_and_ripple() {
        XCTAssertGreaterThan(PresentationMetrics.trackingRingDiameter, PresentationMetrics.dotDiameter)
        XCTAssertLessThan(PresentationMetrics.trackingRingDiameter, PresentationMetrics.rippleMaxDiameter)
    }

    // MARK: - TouchRingModel

    func test_touch_down_creates_ring_and_one_ripple() {
        var m = TouchRingModel()
        m.apply(id: 1, phase: .began, at: CGPoint(x: 10, y: 20))
        XCTAssertEqual(m.activeCount, 1)
        XCTAssertEqual(m.rings[1]?.location, CGPoint(x: 10, y: 20))
        XCTAssertEqual(m.drainRipples(), [CGPoint(x: 10, y: 20)])
        XCTAssertTrue(m.drainRipples().isEmpty, "ripples drain exactly once")
    }

    func test_drag_moves_ring_without_new_ripple() {
        var m = TouchRingModel()
        m.apply(id: 1, phase: .began, at: .zero)
        _ = m.drainRipples()
        m.apply(id: 1, phase: .moved, at: CGPoint(x: 5, y: 7))
        XCTAssertEqual(m.rings[1]?.location, CGPoint(x: 5, y: 7))
        XCTAssertTrue(m.drainRipples().isEmpty, "dragging must not spawn ripples")
    }

    func test_touch_up_removes_ring() {
        var m = TouchRingModel()
        m.apply(id: 1, phase: .began, at: .zero)
        m.apply(id: 1, phase: .ended, at: .zero)
        XCTAssertEqual(m.activeCount, 0)
        XCTAssertNil(m.rings[1])
    }

    func test_moved_or_ended_on_unknown_id_is_noop() {
        var m = TouchRingModel()
        m.apply(id: 99, phase: .moved, at: CGPoint(x: 1, y: 1))
        m.apply(id: 99, phase: .ended, at: .zero)
        XCTAssertEqual(m.activeCount, 0)
        XCTAssertTrue(m.drainRipples().isEmpty)
    }

    func test_multitouch_tracks_each_finger_independently() {
        var m = TouchRingModel()
        m.apply(id: 1, phase: .began, at: CGPoint(x: 1, y: 1))
        m.apply(id: 2, phase: .began, at: CGPoint(x: 2, y: 2))
        XCTAssertEqual(m.activeCount, 2)
        XCTAssertEqual(m.drainRipples().count, 2)
        m.apply(id: 1, phase: .ended, at: .zero)
        XCTAssertEqual(m.activeCount, 1)
        XCTAssertEqual(m.rings[2]?.location, CGPoint(x: 2, y: 2))
    }

    func test_reset_clears_rings_and_pending_ripples() {
        var m = TouchRingModel()
        m.apply(id: 1, phase: .began, at: .zero)
        m.apply(id: 2, phase: .began, at: .zero)
        m.reset()
        XCTAssertEqual(m.activeCount, 0)
        XCTAssertTrue(m.drainRipples().isEmpty)
    }
}
