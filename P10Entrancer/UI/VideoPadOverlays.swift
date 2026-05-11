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
        // Speed normalized 0..1 → exponential mapping to 0.1..4 so
        // 1.0 (centered-ish) is in the middle of the slider travel.
        let normalized = speedToNormalized(video.playbackRate)
        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(.black.opacity(0.55))
                .frame(width: trackW, height: track)
            // Tick at 1× (neutral)
            Rectangle()
                .fill(.white.opacity(0.4))
                .frame(width: 1, height: track + 4)
                .offset(x: trackW * 0.5 - 0.5)
            // Played indicator (white dot)
            Rectangle()
                .fill(.white)
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

    /// Speed slider's "normalized to slider x" mapping. We make 1×
    /// land at the middle of the slider; 0.1×..1× on the left half,
    /// 1×..4× on the right half — exponential so each side has
    /// roughly equal pixels per perceptual step.
    private func speedToNormalized(_ speed: Float) -> Float {
        if speed <= 1 {
            // 0.1 → 0, 1 → 0.5
            let t = (log(speed) - log(0.1)) / (log(1.0) - log(0.1))
            return Float(t) * 0.5
        }
        let t = (log(speed) - log(1.0)) / (log(4.0) - log(1.0))
        return 0.5 + Float(t) * 0.5
    }

    private func normalizedToSpeed(_ n: Float) -> Float {
        if n <= 0.5 {
            let t = Double(n / 0.5)
            return Float(exp(log(0.1) + t * (log(1.0) - log(0.1))))
        }
        let t = Double((n - 0.5) / 0.5)
        return Float(exp(log(1.0) + t * (log(4.0) - log(1.0))))
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
