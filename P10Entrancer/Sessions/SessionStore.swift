import Foundation
import Combine

/// Manages the catalog of saved sessions and the current "default preset"
/// that loads on app launch. Sessions live in `Documents/Sessions/<name>.json`.
/// Every read/write is the user's data; `factory` is a synthetic name that
/// returns a snapshot of the code-baked defaults.
@MainActor
final class SessionStore: ObservableObject {
    static let factoryName = "factory"

    @Published private(set) var savedNames: [String] = []
    @Published var defaultPresetName: String {
        didSet {
            UserDefaults.standard.set(defaultPresetName, forKey: Self.defaultsKey)
        }
    }
    @Published var hasUnsavedChanges: Bool = false

    private static let defaultsKey = "p10e.defaultPresetName"

    private let storageDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        self.defaultPresetName = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? Self.factoryName
        refreshList()
    }

    // MARK: - Catalog

    func refreshList() {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: storageDir,
                                                                          includingPropertiesForKeys: nil) else {
            savedNames = []
            return
        }
        savedNames = entries
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    func exists(_ name: String) -> Bool {
        name == Self.factoryName || savedNames.contains(name)
    }

    // MARK: - Save / Load / Delete

    /// Persists the spec under `name`. The name `factory` is reserved.
    @discardableResult
    func save(_ spec: SessionSpec, as name: String) -> Bool {
        guard !name.isEmpty, name != Self.factoryName else { return false }
        var copy = spec
        copy.name = name
        let url = storageDir.appendingPathComponent("\(name).json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(copy)
            try data.write(to: url, options: .atomic)
            refreshList()
            hasUnsavedChanges = false
            P10Logger.log("[SessionStore] saved '\(name)' (\(data.count) bytes)")
            return true
        } catch {
            P10Logger.log("[SessionStore] save '\(name)' failed: \(error)")
            return false
        }
    }

    /// Loads a saved spec by name. Returns nil for `factory` (caller should
    /// build that synthetically) or for missing/corrupt files.
    func load(_ name: String) -> SessionSpec? {
        guard name != Self.factoryName else { return nil }
        let url = storageDir.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(SessionSpec.self, from: data)
        } catch {
            P10Logger.log("[SessionStore] load '\(name)' decode failed: \(error)")
            return nil
        }
    }

    func delete(_ name: String) {
        guard name != Self.factoryName else { return }
        let url = storageDir.appendingPathComponent("\(name).json")
        try? FileManager.default.removeItem(at: url)
        if defaultPresetName == name { defaultPresetName = Self.factoryName }
        refreshList()
    }
}
