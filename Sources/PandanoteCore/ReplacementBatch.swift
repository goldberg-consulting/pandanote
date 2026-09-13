import Foundation

public struct ReplacementFileChange: Codable, Sendable, Equatable {
    public let relativePath: String
    public let before: String
    public let after: String
    public let replacementCount: Int
    public init(relativePath: String, before: String, after: String, replacementCount: Int) {
        self.relativePath = relativePath; self.before = before; self.after = after; self.replacementCount = replacementCount
    }
}

public struct ReplacementBatchResult: Sendable {
    public let applied: [ReplacementFileChange]
    public let backupURL: URL?
    public let failure: String?
    public init(applied: [ReplacementFileChange], backupURL: URL?, failure: String?) {
        self.applied = applied; self.backupURL = backupURL; self.failure = failure
    }
}

/// A recoverable batch, with all-file preflight and a fresh comparison inside
/// each coordinated write. A concurrent external write can still stop a batch;
/// its result explicitly identifies the completed subset and preserves originals.
public enum ReplacementBatch {
    private struct Record: Codable {
        let created: Date
        let changes: [ReplacementFileChange]
    }
    public static func apply(_ changes: [ReplacementFileChange], in vault: Vault) throws -> ReplacementBatchResult {
        let changes = changes.filter { $0.before != $0.after }
        guard !changes.isEmpty else { return ReplacementBatchResult(applied: [], backupURL: nil, failure: nil) }
        var seen: Set<String> = []
        for change in changes {
            guard change.after.utf8.count <= 8_000_000 else { throw VaultError.tooLarge }
            let file = try target(change.relativePath, vault: vault)
            guard seen.insert(file.path).inserted else { throw EngineFailure.failed("The replacement contains the same file twice.") }
            guard try vault.read(file) == change.before else {
                throw EngineFailure.failed("\(change.relativePath) changed since the preview. Search again before replacing.")
            }
        }
        let directory = vault.root.appendingPathComponent(".pandanote/replacements", isDirectory: true)
        guard vault.contains(directory) else { throw VaultError.outsideVault }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = directory.appendingPathComponent(UUID().uuidString + ".json")
        try JSONEncoder().encode(Record(created: Date(), changes: changes)).write(to: backup, options: .withoutOverwriting)
        var applied: [ReplacementFileChange] = []
        for change in changes {
            do {
                let file = try target(change.relativePath, vault: vault)
                try vault.save(change.after, to: file, expected: change.before)
                applied.append(change)
            } catch {
                return ReplacementBatchResult(applied: applied, backupURL: backup,
                    failure: "Stopped at \(change.relativePath): \(error.localizedDescription). \(applied.count) file(s) were changed. Originals are saved in the replacement backup.")
            }
        }
        return ReplacementBatchResult(applied: applied, backupURL: backup, failure: nil)
    }
    public static func undo(_ changes: [ReplacementFileChange], in vault: Vault) throws -> ReplacementBatchResult {
        // A note already restored by native Undo needs no additional write.
        let pending = try changes.filter { change in
            let current = try vault.read(target(change.relativePath, vault: vault))
            if current == change.before { return false }
            guard current == change.after else {
                throw EngineFailure.failed("\(change.relativePath) has newer edits. Undo was stopped to preserve them; the original is still in the replacement backup.")
            }
            return true
        }
        return try apply(pending.map {
            ReplacementFileChange(relativePath: $0.relativePath, before: $0.after, after: $0.before, replacementCount: $0.replacementCount)
        }, in: vault)
    }
    private static func target(_ path: String, vault: Vault) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw VaultError.outsideVault }
        let file = vault.root.appendingPathComponent(path).standardizedFileURL
        guard vault.contains(file) else { throw VaultError.outsideVault }
        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw VaultError.symbolicLink }
        return file
    }
}
