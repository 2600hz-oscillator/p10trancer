import Foundation
import AVFoundation
import UIKit
import Combine

struct LiveRecording: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let createdAt: Date
    var thumbnail: UIImage?

    static func == (lhs: LiveRecording, rhs: LiveRecording) -> Bool { lhs.id == rhs.id }
}

/// Session-only ring of the 8 most recent live recordings. Newest at index 0;
/// inserting pushes the rest right and drops the oldest beyond 8. Empty on
/// app launch — the mp4 files persist in Documents/UserVideos/ regardless.
@MainActor
final class LiveRecordingsStore: ObservableObject {
    static let capacity = 8

    @Published private(set) var recent: [LiveRecording] = []
    @Published var selectedID: UUID? = nil

    private let pads: PadSystem
    private let mixer: MixerState

    init(pads: PadSystem, mixer: MixerState) {
        self.pads = pads
        self.mixer = mixer
    }

    /// Drop the new recording into the leftmost slot. Returns immediately with
    /// a placeholder thumbnail; the real one is filled in asynchronously.
    func insert(url: URL) {
        let recording = LiveRecording(id: UUID(), url: url, createdAt: Date(), thumbnail: nil)
        recent.insert(recording, at: 0)
        if recent.count > Self.capacity {
            recent.removeLast(recent.count - Self.capacity)
        }
        Task.detached(priority: .userInitiated) { [id = recording.id, url] in
            let img = await Self.generateThumbnail(for: url)
            await self.applyThumbnail(img, for: id)
        }
        P10Logger.log("[LiveRecordings] inserted \(url.lastPathComponent), now \(recent.count) of \(Self.capacity)")
    }

    private func applyThumbnail(_ image: UIImage?, for id: UUID) {
        guard let idx = recent.firstIndex(where: { $0.id == id }) else { return }
        var rec = recent[idx]
        rec.thumbnail = image
        recent[idx] = rec
    }

    /// If a thumbnail is selected, route its recording to the given pad and
    /// clear the selection. Channels follow because they reference the pad
    /// by index.
    func loadIntoPad(_ padIndex: Int) -> Bool {
        guard let id = selectedID,
              let rec = recent.first(where: { $0.id == id }) else { return false }
        guard pads.pads.indices.contains(padIndex) else { return false }
        pads.setSource(VideoFileSource(url: rec.url), at: padIndex)
        selectedID = nil
        P10Logger.log("[LiveRecordings] routed \(rec.url.lastPathComponent) → pad \(padIndex + 1)")
        return true
    }

    func toggleSelection(_ id: UUID) {
        selectedID = (selectedID == id) ? nil : id
    }

    private static func generateThumbnail(for url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        return await withCheckedContinuation { cont in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: 0.1, preferredTimescale: 600))]) { _, cg, _, _, _ in
                if let cg = cg {
                    cont.resume(returning: UIImage(cgImage: cg))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}
