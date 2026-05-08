import Foundation
import UIKit

@MainActor
final class ScreenshotCapturer {
    private var counter: Int = 0
    private let outputDir: URL
    private var timer: Timer?
    private let intervalSeconds: TimeInterval = 5.0
    private let maxScreenshots = 60

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.outputDir = docs.appendingPathComponent("screenshots", isDirectory: true)
        try? FileManager.default.removeItem(at: outputDir)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        P10Logger.log("[Screenshot] writing to \(outputDir.path)")
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.capture()
            }
        }
    }

    private func capture() {
        guard counter < maxScreenshots else { return }
        guard let window = primaryWindow() else {
            P10Logger.log("[Screenshot] #\(counter) skipped — no key window")
            return
        }
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            P10Logger.log("[Screenshot] #\(counter) skipped — zero-size window")
            return
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        guard let data = image.pngData() else {
            P10Logger.log("[Screenshot] #\(counter) skipped — pngData failed")
            return
        }
        let url = outputDir.appendingPathComponent(String(format: "%03d.png", counter))
        do {
            try data.write(to: url)
            P10Logger.log("[Screenshot] #\(counter) wrote \(Int(bounds.width))x\(Int(bounds.height)) to \(url.lastPathComponent)")
            counter += 1
        } catch {
            P10Logger.log("[Screenshot] #\(counter) write failed: \(error)")
        }
    }

    private func primaryWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  scene.session.role == .windowApplication else { continue }
            if let key = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return key
            }
            return windowScene.windows.first
        }
        return nil
    }
}
