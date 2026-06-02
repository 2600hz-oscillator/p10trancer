import SwiftUI

/// Top-right per-pad scaling control. Three visual states:
///
/// - NATIVE: when the source's aspect already matches the output geometry
///   there's nothing to fit, so we show a non-interactive green circle with
///   a white "N" instead of the toggle.
/// - Otherwise a toggle whose icon shows the ACTION tapping performs:
///   - .fill (zoom-fit / cover-crop, the default): inward arrows → tap to
///     letterbox (show all content with black bars).
///   - .letterbox: outward arrows → tap to fill (zoom-fit, cropping).
///
/// Neither mode ever distorts the source aspect. fillMode keeps tracking
/// under the Native badge, so the toggle returns if the output geometry
/// changes and the source no longer matches.
struct PadFillModeToggle: View {
    @ObservedObject var pad: PadSlot
    /// Logical aspect of the current output geometry (16:9 ≈ 1.778, 4:3 ≈ 1.333).
    let outputAspect: Float

    private var isNative: Bool { abs(pad.aspect - outputAspect) < 0.02 }

    var body: some View {
        if isNative {
            ZStack {
                Circle().fill(Color.green)
                Text("N")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
            .accessibilityLabel("Native aspect ratio")
        } else {
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
}
