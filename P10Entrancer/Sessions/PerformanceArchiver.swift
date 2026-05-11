import Foundation
import AppleArchive
import System

/// Archives a Performance package folder (manifest.json + videos/*)
/// into a single `.aar` file (Apple Archive Format) so it can be
/// shared via AirDrop / Files / iCloud / Mail. The receiving end
/// can extract with macOS's `aa` CLI, the Files.app long-press
/// menu, or by tapping the file in Mail.
@MainActor
enum PerformanceArchiver {
    enum Failure: Error {
        case createWriteStreamFailed
        case createCompressionFailed
        case createEncoderFailed
        case keysetFailed
        case writeFailed(String)
    }

    /// Archive `sourceDir` (a Performance package folder) into
    /// `destURL` (which should end in `.aar`). Returns the destURL
    /// on success. The destination file is overwritten if it
    /// already exists.
    static func archive(sourceDir: URL, to destURL: URL) throws -> URL {
        try? FileManager.default.removeItem(at: destURL)
        let archivePath = FilePath(destURL.path)
        let sourcePath = FilePath(sourceDir.path)

        guard let writeStream = ArchiveByteStream.fileStream(
            path: archivePath,
            mode: .writeOnly,
            options: [.create],
            permissions: FilePermissions(rawValue: 0o644)
        ) else { throw Failure.createWriteStreamFailed }
        defer { try? writeStream.close() }

        guard let compressStream = ArchiveByteStream.compressionStream(
            using: .lzfse,
            writingTo: writeStream
        ) else { throw Failure.createCompressionFailed }
        defer { try? compressStream.close() }

        guard let encoder = ArchiveStream.encodeStream(writingTo: compressStream) else {
            throw Failure.createEncoderFailed
        }
        defer { try? encoder.close() }

        guard let keys = ArchiveHeader.FieldKeySet("TYP,PAT,DAT,UID,GID,MOD,FLG,MTM,CTM") else {
            throw Failure.keysetFailed
        }
        do {
            try encoder.writeDirectoryContents(archiveFrom: sourcePath, keySet: keys)
        } catch {
            throw Failure.writeFailed("\(error)")
        }
        P10Logger.log("[PerformanceArchiver] archived \(sourceDir.lastPathComponent) → \(destURL.lastPathComponent)")
        return destURL
    }

    /// Build a destination URL for a Performance package's archive
    /// in a tmp directory the share sheet can read. We use a tmp
    /// path so leftover archives don't pile up in Documents.
    static func tempArchiveURL(for name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safe).p10trancer.aar")
    }
}
