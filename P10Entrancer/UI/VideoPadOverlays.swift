import SwiftUI

/// Overlays for video file pads only: a thin scrub slider at the
/// bottom, a speed slider at the top, and two trim brackets on the
/// left/right edges that shorten the playback region like a sample
/// player. All three use custom DragGestures (not SwiftUI's Slider)
/// because pads are small and the standard sliders need too much
/// vertical space.
struct VideoPadOverlays: View {
    @ObservedObject var video: VideoFileSource

    var body: some View {
        GeometryReader { geo in
            ZStack {
                trimDimming(geo: geo)
                speedSlider(geo: geo)
                scrubSlider(geo: geo)
                trimBrackets(geo: geo)
            }
            .allowsHitTesting(true)
        }
    }

    // MARK: - Dimming outside trim

    /// Greys out the parts of the pad outside the trim region so the
    /// active clip is visually obvious. Doesn't block taps because
    /// .allowsHitTesting(false) on the dim panels.
    private func trimDimming(geo: GeometryProxy) -> some View {
        let w = geo.size.width
        let h = geo.size.height
        let leftEnd = CGFloat(video.trimStart) * w
        let rightStart = CGFloat(video.trimEnd) * w
        return ZStack {
            if leftEnd > 0 {
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .frame(width: leftEnd, height: h)
                    .position(x: leftEnd / 2, y: h / 2)
                    .allowsHitTesting(false)
            }
            if rightStart < w {
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .frame(width: w - rightStart, height: h)
                    .position(x: (rightStart + w) / 2, y: h / 2)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Bottom scrub slider

    private func scrubSlider(geo: GeometryProxy) -> some View {
        let w = geo.size.width
        let h = geo.size.height
        let track = SCRUB_TRACK_HEIGHT
        let inset: CGFloat = 6
        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(.black.opacity(0.55))
                .frame(width: w - inset * 2, height: track)
            // Trim region indicator
            Rectangle()
                .fill(.cyan.opacity(0.18))
                .frame(width: max(0, CGFloat(video.trimEnd - video.trimStart) * (w - inset * 2)),
                       height: track)
                .offset(x: CGFloat(video.trimStart) * (w - inset * 2))
            // Played-up-to bar
            Rectangle()
                .fill(.cyan.opacity(0.7))
                .frame(width: max(0, CGFloat(video.position) * (w - inset * 2)),
                       height: track)
            // Playhead
            Rectangle()
                .fill(.white)
                .frame(width: 2, height: track)
                .offset(x: CGFloat(video.position) * (w - inset * 2) - 1)
        }
        .frame(width: w - inset * 2, height: track)
        .contentShape(Rectangle())
        .position(x: w / 2, y: h - track / 2 - 6)
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let x = max(0, min(w - inset * 2, drag.location.x))
                    video.seek(toNormalized: Double(x / (w - inset * 2)))
                }
        )
    }

    // MARK: - Top speed slider

    private func speedSlider(geo: GeometryProxy) -> some View {
        let w = geo.size.width
        let trackW = w * 0.6
        let track = SPEED_TRACK_HEIGHT
        // Bipolar slider: left edge = -2× (reverse 2×), center = +1×
        // (normal forward, the "default" the user lands on), right
        // edge = +2×. Note this is asymmetric in speed range: left
        // half covers -2..+1, right half covers +1..+2. Linear
        // mapping on each half — the range is small enough that an
        // exponential curve isn't needed.
        let normalized = speedToNormalized(video.playbackRate)
        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(.black.opacity(0.55))
                .frame(width: trackW, height: track)
            // Tick at center (1× neutral) — emphasized, taller.
            Rectangle()
                .fill(.white.opacity(0.55))
                .frame(width: 1, height: track + 6)
                .offset(x: trackW * 0.5 - 0.5)
            // Tick at 0 (paused) — sits at n = 1/3 since the left
            // half spans -2..+1.
            Rectangle()
                .fill(.white.opacity(0.35))
                .frame(width: 1, height: track + 2)
                .offset(x: trackW * (1.0/3.0) - 0.5)
            // Tick at -1× — sits at n = 1/6.
            Rectangle()
                .fill(.white.opacity(0.3))
                .frame(width: 1, height: track + 2)
                .offset(x: trackW * (1.0/6.0) - 0.5)
            // Played indicator (white bar). Orange when running
            // reverse so direction is obvious at a glance.
            Rectangle()
                .fill(video.playbackRate < 0 ? Color.orange : Color.white)
                .frame(width: 8, height: track)
                .offset(x: CGFloat(normalized) * trackW - 4)
            HStack {
                Text(String(format: "%.2fx", video.playbackRate))
                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .background(.black.opacity(0.5))
            }
            .offset(x: trackW + 4)
        }
        .frame(width: trackW, height: track)
        .contentShape(Rectangle())
        .position(x: w / 2, y: 8 + track / 2)
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let x = max(0, min(trackW, drag.location.x))
                    video.playbackRate = normalizedToSpeed(Float(x / trackW))
                }
        )
    }

    /// Speed slider's "speed → slider position" mapping. Center
    /// (n=0.5) is the user's default of +1× forward. Left half maps
    /// linearly to the -2×..+1× range; right half maps linearly to
    /// +1×..+2×. Asymmetric on purpose so the "useful" reverse range
    /// gets most of the slider travel and the normal-speed default
    /// sits dead center.
    private func speedToNormalized(_ speed: Float) -> Float {
        let s = max(-2, min(2, speed))
        if s >= 1 {
            // 1..2 → 0.5..1
            return 0.5 + (s - 1) * 0.5
        }
        // -2..1 → 0..0.5
        return (s + 2) / 6
    }

    private func normalizedToSpeed(_ n: Float) -> Float {
        // ±0.03 dead zone around center snaps to +1× — makes it
        // easy to return the slider to the default speed without
        // hairline-precision dragging.
        if abs(n - 0.5) < 0.03 { return 1.0 }
        if n > 0.5 {
            // 0.5..1 → 1..2
            return 1.0 + (n - 0.5) * 2
        }
        // 0..0.5 → -2..1
        return -2.0 + n * 6
    }

    // MARK: - Trim brackets

    /// Left/right vertical handles. Drag inward to shorten the clip.
    private func trimBrackets(geo: GeometryProxy) -> some View {
        let w = geo.size.width
        let h = geo.size.height
        let handleW: CGFloat = 10
        let leftX = CGFloat(video.trimStart) * w
        let rightX = CGFloat(video.trimEnd) * w
        return ZStack {
            // Left bracket
            ZStack {
                Rectangle().fill(.yellow.opacity(0.6)).frame(width: 2, height: h - SCRUB_TRACK_HEIGHT - SPEED_TRACK_HEIGHT - 24)
                    .offset(x: 1)
                Rectangle().fill(.yellow.opacity(0.85)).frame(width: handleW, height: 24)
                    .offset(x: handleW / 2 - 1)
            }
            .frame(width: handleW, height: h)
            .contentShape(Rectangle())
            .position(x: leftX + handleW / 2, y: h / 2)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let x = max(0, min(w, drag.location.x))
                        video.setTrimStart(Double(x / w))
                    }
            )
            // Right bracket
            ZStack {
                Rectangle().fill(.yellow.opacity(0.6)).frame(width: 2, height: h - SCRUB_TRACK_HEIGHT - SPEED_TRACK_HEIGHT - 24)
                    .offset(x: -1)
                Rectangle().fill(.yellow.opacity(0.85)).frame(width: handleW, height: 24)
                    .offset(x: -handleW / 2 + 1)
            }
            .frame(width: handleW, height: h)
            .contentShape(Rectangle())
            .position(x: rightX - handleW / 2, y: h / 2)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let x = max(0, min(w, drag.location.x))
                        video.setTrimEnd(Double(x / w))
                    }
            )
        }
    }
}

private let SCRUB_TRACK_HEIGHT: CGFloat = 6
/// Speed slider visual + hit-area height. Deliberately tall (~4×
/// the scrub track) so the slider is easy to grab on the small
/// pad; it overlaps the thumbnail, which is fine.
private let SPEED_TRACK_HEIGHT: CGFloat = 20
