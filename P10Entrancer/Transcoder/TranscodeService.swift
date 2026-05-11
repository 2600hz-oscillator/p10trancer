import Foundation
import ffmpegkit

/// Errors surfaced by the in-app transcoder. The UI layer doesn't
/// look at these yet (this pass only logs to P10Logger), but the
/// types are here so future toasts / progress sheets can pattern-
/// match on a concrete failure.
enum TranscodeError: Error {
    /// Input extension is one AVFoundation already handles — caller
    /// should not invoke the transcoder.
    case notSupported
    /// FFmpegKit returned a non-success state code. The associated
    /// string is the tail of the ffmpeg log so callers can route it
    /// into diagnostics without re-running the session.
    case failed(String)
}

/// Wrapper around FFmpegKit that converts containers AVFoundation
/// can't open (.mkv, .webm, .avi, …) into a plain H.264 + AAC mp4
/// suitable for AVPlayer / VideoFileSource. We use VideoToolbox for
/// H.264 encode and FFmpeg's native AAC encoder so we can stay on
/// the LGPL "min" build of ffmpeg-kit (no libx264, no GPL).
enum TranscodeService {
    /// Containers AVFoundation handles natively. Everything else
    /// gets routed through ffmpeg-kit. Comparison is lowercased so
    /// "Clip.MP4" from Files.app doesn't false-positive.
    private static let avfNativeExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// Returns true when the file's extension isn't one AVFoundation
    /// can decode directly. Caller is expected to skip the transcode
    /// pipeline entirely when this returns false.
    static func needsTranscoding(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return !avfNativeExtensions.contains(ext)
    }

    /// Transcode `input` to an H.264 + AAC mp4 at `output`. Runs
    /// the ffmpeg session off the calling thread (FFmpegKit's
    /// `executeAsync` schedules onto its own pool) and bridges the
    /// callback back into the structured-concurrency caller via a
    /// CheckedContinuation. Throws on non-success return states or
    /// non-zero return codes.
    ///
    /// `onProgress` is called with a 0..1 fraction whenever
    /// FFmpegKit's statistics callback fires (a few times per
    /// second). The fraction is computed from the input's reported
    /// duration (probed via FFprobeKit before the encode starts).
    /// If duration can't be probed the callback still fires but the
    /// fraction stays at 0 — UI should show a spinner rather than a
    /// stalled bar in that case.
    @discardableResult
    static func transcodeToMP4(input: URL,
                                output: URL,
                                onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        // Defensive: if a previous run left an output stub behind,
        // ffmpeg will prompt "y/N" for overwrite on stdin and hang
        // the session. Just remove it before kicking off the job.
        if FileManager.default.fileExists(atPath: output.path) {
            try? FileManager.default.removeItem(at: output)
        }

        // -y                : never prompt, always overwrite
        // -i <input>        : input file
        // -c:v h264_videotoolbox : iOS hardware H.264 encoder (no
        //                      libx264 required — keeps us on the
        //                      "min" LGPL build)
        // -b:v 6M           : sensible bitrate for VJ clips; we'll
        //                      tune later if file sizes get gross
        // -pix_fmt yuv420p  : maximum AVPlayer / QuickTime compat
        // -c:a aac          : FFmpeg's native AAC encoder (built in
        //                      to "min")
        // -b:a 192k         : transparent enough for non-music VJ use
        // -movflags +faststart : moov atom at the front so AVPlayer
        //                      can start playback before the whole
        //                      file is read
        let cmd = [
            "-y",
            "-i", quote(input.path),
            "-c:v", "h264_videotoolbox",
            "-b:v", "6M",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-b:a", "192k",
            "-movflags", "+faststart",
            quote(output.path),
        ].joined(separator: " ")

        P10Logger.log("[Transcode] start: \(input.lastPathComponent) → \(output.lastPathComponent)")
        let startedAt = Date()

        // Probe the input duration so the statistics callback can
        // emit a real 0..1 progress fraction (ffmpeg only reports
        // the current PTS, not a percentage). Best-effort: if
        // probing fails or returns empty the progress just stays
        // at 0 and the UI falls back to a "thinking" spinner.
        let durationMs = probeDurationMs(input: input)
        if durationMs > 0 {
            P10Logger.log("[Transcode] input duration ≈ \(durationMs)ms")
        } else {
            P10Logger.log("[Transcode] input duration unknown — progress will not be reported")
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            FFmpegKit.executeAsync(
                cmd,
                withCompleteCallback: { session in
                    let elapsed = Date().timeIntervalSince(startedAt)
                    let state = session?.getState() ?? .failed
                    let rc = session?.getReturnCode()
                    let succeeded = ReturnCode.isSuccess(rc)
                    let cancelled = ReturnCode.isCancel(rc)

                    if succeeded {
                        P10Logger.log("[Transcode] OK in \(String(format: "%.1f", elapsed))s → \(output.lastPathComponent)")
                        onProgress?(1.0)
                        cont.resume(returning: output)
                        return
                    }
                    let logs = session?.getAllLogsAsString() ?? ""
                    let tail = String(logs.suffix(800))
                    let reason = cancelled ? "cancelled" : "state=\(state.rawValue) rc=\(rc?.getValue() ?? -1)"
                    P10Logger.log("[Transcode] FAILED (\(reason)) — log tail:\n\(tail)")
                    cont.resume(throwing: TranscodeError.failed(reason))
                },
                withLogCallback: { _ in
                    // Ignore — we only care about completion + stats.
                    // The full session log is pulled on failure above.
                },
                withStatisticsCallback: { stats in
                    guard let onProgress, durationMs > 0, let s = stats else { return }
                    let timeMs = s.getTime()
                    let frac = Double(timeMs) / Double(durationMs)
                    onProgress(max(0, min(1, frac)))
                }
            )
        }
    }

    /// Best-effort input duration in milliseconds. Returns 0 when
    /// the file can't be probed (some webms / corrupt headers).
    private static func probeDurationMs(input: URL) -> Int {
        let session = FFprobeKit.getMediaInformation(input.path)
        guard let info = session?.getMediaInformation() else { return 0 }
        // Duration is returned as a NSString like "10.250000"
        // (seconds, fractional). Container-level duration only —
        // close enough for a progress bar even when stream-level
        // durations differ slightly.
        guard let str = info.getDuration() as String?,
              let seconds = Double(str) else { return 0 }
        return Int(seconds * 1000)
    }

    /// Quote a path for the single-string FFmpegKit command line so
    /// spaces / parens in the user's filename don't shred the arg
    /// vector. FFmpegKit accepts standard shell-style double-quotes.
    private static func quote(_ s: String) -> String {
        // Escape any embedded double-quotes (vanishingly rare in
        // iOS sandbox paths, but cheap to handle).
        let escaped = s.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
