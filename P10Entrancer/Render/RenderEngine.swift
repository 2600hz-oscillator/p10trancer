import Foundation
import MetalKit
import QuartzCore

@MainActor
final class RenderEngine {
    static let shared = RenderEngine()

    private let context = MetalContext.shared
    private var displayLink: CADisplayLink?
    private var registeredRenderers: [WeakRenderer] = []
    private(set) var frameIndex: UInt64 = 0
    private(set) var startTime: CFTimeInterval = 0

    private struct WeakRenderer {
        weak var renderer: FrameRenderer?
    }

    private init() {}

    func start() {
        guard displayLink == nil else { return }
        startTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func register(_ renderer: FrameRenderer) {
        registeredRenderers.removeAll { $0.renderer == nil || $0.renderer === renderer }
        registeredRenderers.append(WeakRenderer(renderer: renderer))
    }

    @objc private func tick(_ link: CADisplayLink) {
        frameIndex &+= 1
        let elapsed = link.timestamp - startTime
        registeredRenderers.removeAll { $0.renderer == nil }
        for entry in registeredRenderers {
            entry.renderer?.render(frameIndex: frameIndex, elapsedTime: elapsed)
        }
    }
}

@MainActor
protocol FrameRenderer: AnyObject {
    func render(frameIndex: UInt64, elapsedTime: CFTimeInterval)
}
