import Foundation

enum P10Logger {
    private static let logURL: URL? = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return docs?.appendingPathComponent("p10e.log")
    }()

    private static let queue = DispatchQueue(label: "p10e.logger", qos: .utility)
    private static var didTruncate = false

    static func log(_ message: String, file: String = #fileID, line: Int = #line) {
        let timestamp = ISO8601DateFormatter.shared.string(from: Date())
        let fileShort = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
        let formatted = "\(timestamp) [\(fileShort):\(line)] \(message)"
        print(formatted)
        queue.async {
            guard let url = logURL else { return }
            if !didTruncate {
                didTruncate = true
                try? "".write(to: url, atomically: true, encoding: .utf8)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write((formatted + "\n").data(using: .utf8) ?? Data())
                try? handle.close()
            } else if let data = (formatted + "\n").data(using: .utf8) {
                try? data.write(to: url)
            }
        }
    }
}

private extension ISO8601DateFormatter {
    static let shared: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
