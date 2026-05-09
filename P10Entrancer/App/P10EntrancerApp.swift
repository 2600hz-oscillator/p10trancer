import SwiftUI
import UIKit

@main
struct P10EntrancerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .ignoresSafeArea()
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                .onAppear {
                    forceLandscape()
                }
        }
    }

    /// The Info.plist already restricts to landscape orientations, but iOS
    /// only flips the device when it physically rotates. Forcing geometry
    /// here makes the app open in landscape on first launch (and keeps the
    /// simulator captures landscape during App Store screenshot work).
    private func forceLandscape() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .landscapeRight)
        scene.requestGeometryUpdate(prefs) { _ in }
    }
}
