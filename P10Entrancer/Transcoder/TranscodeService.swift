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
    @discardableResult
    static func transcodeToMP4(input: URL, output: URL) async throws -> URL {
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

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            // executeAsync's completion block fires on FFmpegKit's
            // own queue, NOT the main actor. We just resume the
            // continuation; the caller hops back to whatever actor
            // it needs.
            FFmpegKit.executeAsync(cmd) { session in
                let elapsed = Date().timeIntervalSince(startedAt)
                let state = session?.getState() ?? .failed
                let rc = session?.getReturnCode()
                let succeeded = ReturnCode.isSuccess(rc)
                let cancelled = ReturnCode.isCancel(rc)

                if succeeded {
                    P10Logger.log("[Transcode] OK in \(String(format: "%.1f", elapsed))s → \(output.lastPathComponent)")
                    cont.resume(returning: output)
                    return
                }

                // Pull the tail of the ffmpeg log so the failure
                // reason ends up somewhere the user can find it.
                // session.getAllLogsAsString blocks until logs are
                // flushed; safe here because we're on FFmpegKit's
                // own callback thread, not the main actor.
                let logs = session?.getAllLogsAsString() ?? ""
                let tail = String(logs.suffix(800))
                let reason = cancelled ? "cancelled" : "state=\(state.rawValue) rc=\(rc?.getValue() ?? -1)"
                P10Logger.log("[Transcode] FAILED (\(reason)) — log tail:\n\(tail)")
                cont.resume(throwing: TranscodeError.failed(reason))
            }
        }
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
