import SwiftUI

/// Full-cell overlay drawn over a pad while its source is being
/// transcoded by ffmpeg. Blocks the underlying tap/route gesture
/// (the source isn't ready yet) and shows the input name + a real
/// progress bar driven by FFmpegKit's statistics callback.
struct TranscodeOverlayView: View {
    let job: TranscodeManager.Job

    var body: some View {
        ZStack {
            // Dimmed background — soaks up taps so the user can't
            // start routing or chaining the pad mid-transcode.
            Rectangle()
                .fill(Color.black.opacity(0.85))
                .contentShape(Rectangle())
            VStack(spacing: 10) {
                Text("THINKING")
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.yellow)
                    .tracking(2.5)
                Text(job.inputName)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                progressBar
                Text(progressLabel)
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 8)
        }
        .allowsHitTesting(true)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                Rectangle()
                    .fill(Color.yellow)
                    .frame(width: geo.size.width * CGFloat(job.progress))
                    .animation(.linear(duration: 0.25), value: job.progress)
            }
        }
        .frame(height: 6)
        .overlay(Rectangle().strokeBorder(Color.yellow.opacity(0.4), lineWidth: 1))
    }

    private var progressLabel: String {
        if job.progress <= 0.001 { return "starting…" }
        return "\(Int(job.progress * 100))%"
    }
}
