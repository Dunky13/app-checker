import CryptoKit
import Foundation

/// The kept exchanges of AI lookups. Per item: the lookup its verdict comes from, and a later lookup that failed.
public struct LookupLogs: Sendable {
    let folder: URL

    public init(folder: URL) { self.folder = folder }

    private func file(_ id: String, failed: Bool) -> URL {
        // Item ids hold paths and can be long: a hash fits every file system and two ids never differ by case only.
        let name = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name + (failed ? ".failed.json" : ".json"))
    }

    /// A lookup that worked replaces both logs. One that failed leaves the log behind the verdict as it is.
    public func save(_ turns: [LLM.Turn], for id: String, failed: Bool) throws {
        // Removed before writing: when the write fails, no log is better than the log of an older lookup.
        if !failed { removeVerdictLog(for: id) }
        try? FileManager.default.removeItem(at: file(id, failed: true))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(turns).write(to: file(id, failed: failed), options: .atomic)
    }

    /// For an item whose lookup result is no longer used.
    public func removeVerdictLog(for id: String) {
        try? FileManager.default.removeItem(at: file(id, failed: false))
    }

    public func hasLog(for id: String) -> Bool {
        [false, true].contains { FileManager.default.fileExists(atPath: file(id, failed: $0).path) }
    }

    /// nil for a part that is not there or cannot be read.
    public func load(for id: String) -> (verdict: [LLM.Turn]?, failed: [LLM.Turn]?) {
        func read(_ failed: Bool) -> [LLM.Turn]? { try? JSONDecoder().decode([LLM.Turn].self, from: Data(contentsOf: file(id, failed: failed))) }
        return (read(false), read(true))
    }
}
