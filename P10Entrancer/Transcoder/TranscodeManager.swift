import Foundation
import Combine

/// Tracks in-flight in-app transcodes so the UI can overlay a
/// "THINKING" placard with a progress bar on the affected pad and
/// block the user from queueing additional transcodes while one is
/// running.
///
/// We treat the whole app as single-transcode-at-a-time: FFmpegKit
/// runs serially internally anyway and each transcode is CPU-heavy
/// enough that parallelising would only make every job slower.
/// `isAnyActive` is what the source-picker / Files-importer gates on.
@MainActor
final class TranscodeManager: ObservableObject {
    struct Job: Equatable {
        let inputName: String
        var progress: Double  // 0…1
    }

    @Published private(set) var jobs: [Int: Job] = [:]

    /// True when ANY pad currently has a transcode in flight. UI
    /// uses this to block the Files importer + the Load Video
    /// context-menu entry so the user can't queue a second job.
    var isAnyActive: Bool { !jobs.isEmpty }

    /// Per-pad lookup for the cell overlay.
    func job(for padIndex: Int) -> Job? { jobs[padIndex] }
    func isActive(padIndex: Int) -> Bool { jobs[padIndex] != nil }

    func start(padIndex: Int, inputName: String) {
        jobs[padIndex] = Job(inputName: inputName, progress: 0)
    }

    func update(padIndex: Int, progress: Double) {
        guard var job = jobs[padIndex] else { return }
        job.progress = max(0, min(1, progress))
        jobs[padIndex] = job
    }

    func finish(padIndex: Int) {
        jobs.removeValue(forKey: padIndex)
    }
}
