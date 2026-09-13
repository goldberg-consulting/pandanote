import Foundation

public enum ChangeError: LocalizedError {
    case stale, invalidRange, wrongDocument
    public var errorDescription: String? {
        switch self {
        case .stale: return "The document changed after this revision was requested. Keep your newer work and request a fresh revision."
        case .invalidRange: return "Select a passage in the editor before requesting a revision."
        case .wrongDocument: return "Open the original document to apply this revision."
        }
    }
}

public struct ChangeProposal: Codable, Identifiable, Sendable {
    public let id: UUID
    public let created: Date
    public let relativePath: String
    public let instruction: String
    public let provider: String
    public let base: String
    public let location: Int
    public let length: Int
    public var replacement: String
    public var decision: String
    public init(relativePath: String, instruction: String, provider: String, base: String, range: NSRange, replacement: String) throws {
        guard range.location >= 0, range.length > 0, range.location <= (base as NSString).length, range.length <= (base as NSString).length - range.location,
              Self.boundary(range.location, in: base), Self.boundary(NSMaxRange(range), in: base) else { throw ChangeError.invalidRange }
        id = UUID(); created = Date(); self.relativePath = relativePath; self.instruction = instruction; self.provider = provider
        self.base = base; location = range.location; length = range.length; self.replacement = replacement; decision = "pending"
    }
    private static func boundary(_ offset: Int, in text: String) -> Bool {
        let units = Array(text.utf16)
        return offset == 0 || offset == units.count || !(0xDC00...0xDFFF).contains(units[offset]) || !(0xD800...0xDBFF).contains(units[offset - 1])
    }
    private var validRange: Bool { location >= 0 && length > 0 && location <= (base as NSString).length && length <= (base as NSString).length - location && Self.boundary(location, in: base) && Self.boundary(location + length, in: base) }
    public var original: String { validRange ? (base as NSString).substring(with: NSRange(location: location, length: length)) : "" }
    public func applying(to current: String, relativePath: String) throws -> String {
        guard validRange else { throw ChangeError.invalidRange }
        guard relativePath == self.relativePath else { throw ChangeError.wrongDocument }
        guard current == base, decision == "pending" else { throw ChangeError.stale }
        return (base as NSString).replacingCharacters(in: NSRange(location: location, length: length), with: replacement)
    }
}

public struct ChangeArchive {
    public let vault: Vault
    public init(vault: Vault) { self.vault = vault }
    private var directory: URL { vault.root.appendingPathComponent(".pandanote/reviews") }
    public func store(_ proposal: ChangeProposal) throws {
        guard vault.contains(directory) else { throw VaultError.outsideVault }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(proposal.id.uuidString + ".json")
        guard vault.contains(url) else { throw VaultError.outsideVault }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(proposal).write(to: url, options: .atomic)
    }
    public func list() throws -> [ChangeProposal] {
        guard vault.contains(directory) else { throw VaultError.outsideVault }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && vault.contains($0) }
            .compactMap { try? JSONDecoder().decode(ChangeProposal.self, from: Data(contentsOf: $0)) }
            .sorted { $0.created > $1.created }
    }
}

public struct DiffLine: Identifiable, Sendable {
    public let id: Int
    public let kind: String
    public let text: String
}
public enum TextDiff {
    public static func lines(before: String, after: String) -> [DiffLine] {
        let old = before.components(separatedBy: "\n"), new = after.components(separatedBy: "\n")
        // Bound the quadratic worst case of CollectionDifference for very long documents.
        if old.count + new.count > 8000 {
            return [DiffLine(id: 0, kind: "-", text: before), DiffLine(id: 1, kind: "+", text: after)]
        }
        let diff = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff { switch change { case .remove(let i, _, _): removed.insert(i); case .insert(let i, _, _): inserted.insert(i) } }
        var result: [DiffLine] = [], a = 0, b = 0
        func append(_ kind: String, _ text: String) { result.append(DiffLine(id: result.count, kind: kind, text: text)) }
        while a < old.count || b < new.count {
            if a < old.count && removed.contains(a) { append("-", old[a]); a += 1 }
            else if b < new.count && inserted.contains(b) { append("+", new[b]); b += 1 }
            else if a < old.count && b < new.count { append(" ", old[a]); a += 1; b += 1 }
            else { break }
        }
        return result
    }
}
