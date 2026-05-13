import SwiftUI
import UIKit

@main
struct P10EntrancerApp: App {
    init() {
        // If launched with -AudioSelfTest, run the audio diagnostic
        // probes and exit. Lets us iterate on AVAudioSession config
        // without manual on-iPad testing each round.
        if AudioSelfTest.isRequested {
            Task { @MainActor in await AudioSelfTest.runAndExit() }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .ignoresSafeArea()
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}
