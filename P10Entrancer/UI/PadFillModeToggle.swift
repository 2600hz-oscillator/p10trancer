import SwiftUI

/// Small icon in the top-right of each pad cell. Lets the user toggle
/// the pad's aspect-handling mode for when it's routed to a channel.
///
/// - Letterbox mode (default): show the outward-diagonal-arrows icon.
///   The visual hint is "expand to fill" — tapping makes the source
///   cover the canvas with cropping.
/// - Fill mode: show the inward-diagonal-arrows icon. The hint is
///   "shrink back" — tapping returns to letterbox.
struct PadFillModeToggle: View {
    @ObservedObject var pad: PadSlot

    var body: some View {
        Button {
            pad.fillMode = (pad.fillMode == .letterbox) ? .fill : .letterbox
        } label: {
            Image(systemName: pad.fillMode == .letterbox
                  ? "arrow.up.left.and.arrow.down.right"
                  : "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(5)
                .background(.black.opacity(0.55))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pad.fillMode == .letterbox
                            ? "Switch to fill mode"
                            : "Switch to letterbox mode")
    }
}
