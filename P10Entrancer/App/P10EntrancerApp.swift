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
        }
    }
}
