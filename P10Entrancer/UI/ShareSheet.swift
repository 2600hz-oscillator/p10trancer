import SwiftUI
import UIKit

/// SwiftUI wrapper around UIActivityViewController for AirDrop /
/// Files / Mail / etc. SwiftUI's ShareLink works on iOS 16+ for
/// simple URLs but the activity controller is more flexible and
/// the iPad-specific popoverPresentationController is easier here.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
