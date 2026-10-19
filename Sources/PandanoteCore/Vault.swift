import Foundation
import CryptoKit

public struct NoteFile: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let relativePath: String
    public let modified: Date
    public let text: String
    public var title: String { url.deletingPathExtension().lastPathComponent }
    public var folder: String { (relativePath as NSString).deletingLastPathComponent }
    public let tags: [String]
    public let excerpt: String
    public init(url: URL, relativePath: String, modified: Date, text: String) {
        self.url = url; self.relativePath = relativePath; self.modified = modified; self.text = text
        tags = MarkdownInfo.tags(text)
        excerpt = MarkdownInfo.body(text).components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }.first.map { String($0.prefix(110)) } ?? "Empty note"
    }
}

public enum VaultError: LocalizedError {
    case outsideVault, externalChange, invalidName, tooLarge
    case nameAlreadyExists, invalidDestination, unsupportedFileType, symbolicLink
    public var errorDescription: String? {
        switch self {
        case .outsideVault: return "This file is outside the selected vault."
        case .externalChange: return "This note changed in another app. Your edits are still here. Save a copy or reload the disk version before continuing."
        case .invalidName: return "Choose a name without slashes, colons, or a leading dot."
        case .tooLarge: return "This file is larger than the 8 MB editing limit."
        case .nameAlreadyExists: return "An item with that name already exists in this folder."
        case .invalidDestination: return "Choose an existing folder outside the item you are moving."
        case .unsupportedFileType: return "Use a Markdown, text, LaTeX, or BibTeX filename (.md, .markdown, .txt, .tex, or .bib)."
        case .symbolicLink: return "Choose the original file or folder instead of a symbolic link."
        }
    }
}

public final class Vault: @unchecked Sendable {
    public let root: URL
    private let fm = FileManager.default
    private static let supportedExtensions = ["md", "markdown", "txt", "tex", "bib"]
    private static let skippedDirectories = ["node_modules", "venv", ".venv", "build"]
    public init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }
    /// Validate before replacing the current workspace, including URLs received from Finder.
    public static func validatedRoot(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw VaultError.invalidDestination }
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        guard values.isDirectory == true, values.isPackage != true else { throw VaultError.invalidDestination }
        // An unreadable folder must not silently become an empty vault.
        _ = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return root
    }
    /// Browse one level without Spotlight or a recursive content scan.
    public static func childDirectories(in root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])
            .filter { url in
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
                return values.isDirectory == true && values.isPackage != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    public func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(root.path + "/")
    }
    public func scan() throws -> [NoteFile] {
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var notes: [NoteFile] = []
        for case let entry as URL in enumerator {
            let url = entry.standardizedFileURL
            if Self.skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            guard Self.supportedExtensions.contains(url.pathExtension.lowercased()), contains(url) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 8_000_000 else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            notes.append(NoteFile(url: url, relativePath: String(url.path.dropFirst(root.path.count + 1)), modified: values.contentModificationDate ?? .distantPast, text: text))
        }
        return notes.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }
    /// Return visible vault-relative folder paths, including empty nested folders.
    public func directories() throws -> [String] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var paths: [String] = []
        for case let entry as URL in enumerator {
            let url = entry.standardizedFileURL
            if Self.skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            let values = try url.resourceValues(forKeys: keys)
            guard contains(url), values.isSymbolicLink != true, values.isPackage != true else {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true { paths.append(String(url.path.dropFirst(root.path.count + 1))) }
        }
        return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    public func read(_ url: URL) throws -> String {
        guard contains(url) else { throw VaultError.outsideVault }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8_000_000 else { throw VaultError.tooLarge }
        return try String(contentsOf: url, encoding: .utf8)
    }
    public func save(_ text: String, to url: URL, expected: String?) throws {
        guard contains(url) else { throw VaultError.outsideVault }
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinated in
            do {
                let exists = self.fm.fileExists(atPath: coordinated.path)
                let previous = exists ? try String(contentsOf: coordinated, encoding: .utf8) : nil
                if let expected, previous != expected { throw VaultError.externalChange }
                if let previous, previous != text { try self.snapshot(previous, for: url) }
                try text.write(to: coordinated, atomically: true, encoding: .utf8)
            } catch { writeError = error }
        }
        if let error = coordinationError { throw error }
        if let error = writeError { throw error }
    }
    /// Create a Markdown note with a unique name, creating its parent folders if needed.
    public func create(name: String, folder: String = "", text: String = "") throws -> URL {
        try validateName(name)
        return try createFile(name: name + ".md", folder: folder, text: text)
    }
    /// Create a supported text file with a full filename; existing files receive a numbered sibling.
    public func createFile(name: String, folder: String = "", text: String = "") throws -> URL {
        try validateName(name)
        guard Self.supportedExtensions.contains((name as NSString).pathExtension.lowercased()) else { throw VaultError.unsupportedFileType }
        let directory = try directoryURL(for: folder, creatingIfNeeded: true)
        let file = uniqueURL(named: name, in: directory, isDirectory: false)
        guard contains(file) else { throw VaultError.outsideVault }
        // An exclusive write also protects an item created between choosing and writing the name.
        try Data(text.utf8).write(to: file, options: .withoutOverwriting)
        return file
    }
    /// Create a uniquely named folder inside the vault.
    public func createFolder(name: String, folder: String = "") throws -> URL {
        try validateName(name)
        let directory = try directoryURL(for: folder, creatingIfNeeded: true)
        let target = uniqueURL(named: name, in: directory, isDirectory: true)
        guard contains(target) else { throw VaultError.outsideVault }
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        return target
    }
    /// Copy a file or folder to a uniquely named sibling without replacing an existing item.
    public func duplicate(_ url: URL) throws -> URL {
        let source = try mutableItem(url)
        let isDirectory = try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let name = isDirectory ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
        let fileExtension = isDirectory || source.pathExtension.isEmpty ? "" : "." + source.pathExtension
        let target = uniqueURL(named: name + " copy" + fileExtension, in: source.deletingLastPathComponent(), isDirectory: isDirectory)
        guard contains(target) else { throw VaultError.outsideVault }
        try fm.copyItem(at: source, to: target)
        return target
    }
    /// Rename a file or folder using its full leaf name, refusing to overwrite an existing item.
    public func rename(_ url: URL, to name: String) throws -> URL {
        try validateName(name)
        let source = try mutableItem(url)
        if try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true {
            guard Self.supportedExtensions.contains((name as NSString).pathExtension.lowercased()) else { throw VaultError.unsupportedFileType }
        }
        return try relocate(source, to: source.deletingLastPathComponent().appendingPathComponent(name))
    }
    /// Move a file or folder into an existing vault-relative folder; an empty path selects the vault root.
    public func move(_ url: URL, toFolder folder: String) throws -> URL {
        let source = try mutableItem(url)
        let directory = try directoryURL(for: folder, creatingIfNeeded: false)
        return try relocate(source, to: directory.appendingPathComponent(source.lastPathComponent))
    }
    /// Move a file or folder to the system Trash, leaving the vault root and external items untouched.
    public func trash(_ url: URL) throws {
        try fm.trashItem(at: mutableItem(url), resultingItemURL: nil)
    }
    private func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.hasPrefix("."), !name.contains("/"), !name.contains(":"),
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw VaultError.invalidName }
    }
    private func directoryURL(for folder: String, creatingIfNeeded: Bool) throws -> URL {
        let directory = (folder.isEmpty ? root : root.appendingPathComponent(folder, isDirectory: true)).standardizedFileURL
        guard directory == root || contains(directory) else { throw VaultError.outsideVault }
        if creatingIfNeeded { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw VaultError.symbolicLink }
        guard values.isDirectory == true else { throw VaultError.invalidDestination }
        return directory
    }
    private func mutableItem(_ url: URL) throws -> URL {
        let source = url.standardizedFileURL
        guard contains(source) else { throw VaultError.outsideVault }
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw VaultError.symbolicLink }
        return source
    }
    private func entryExists(at url: URL) -> Bool {
        // attributesOfItem also detects a dangling symbolic link, which must never be replaced.
        (try? fm.attributesOfItem(atPath: url.path)) != nil
    }
    private func uniqueURL(named name: String, in directory: URL, isDirectory: Bool) -> URL {
        let fileExtension = isDirectory ? "" : (name as NSString).pathExtension
        let stem = fileExtension.isEmpty ? name : (name as NSString).deletingPathExtension
        let suffix = fileExtension.isEmpty ? "" : "." + fileExtension
        var target = directory.appendingPathComponent(name, isDirectory: isDirectory)
        var number = 2
        while entryExists(at: target) {
            target = directory.appendingPathComponent("\(stem) \(number)\(suffix)", isDirectory: isDirectory)
            number += 1
        }
        return target
    }
    private func relocate(_ source: URL, to destination: URL) throws -> URL {
        let target = destination.standardizedFileURL
        guard contains(target) else { throw VaultError.outsideVault }
        if source == target { return source }
        let sourcePath = source.resolvingSymlinksInPath().path
        let targetPath = target.resolvingSymlinksInPath().path
        guard !targetPath.hasPrefix(sourcePath + "/") else { throw VaultError.invalidDestination }
        if entryExists(at: target) {
            guard try isCaseOnlyRename(source, to: target) else { throw VaultError.nameAlreadyExists }
        }
        try preserveHistory(from: source, to: target)
        try fm.moveItem(at: source, to: target)
        return target
    }
    private func isCaseOnlyRename(_ source: URL, to target: URL) throws -> Bool {
        guard source.deletingLastPathComponent() == target.deletingLastPathComponent(),
              source.lastPathComponent.caseInsensitiveCompare(target.lastPathComponent) == .orderedSame else { return false }
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let sourceIdentifier = try source.resourceValues(forKeys: keys).fileResourceIdentifier as? NSObject,
              let targetIdentifier = try target.resourceValues(forKeys: keys).fileResourceIdentifier as? NSObject else { return false }
        return sourceIdentifier == targetIdentifier
    }
    private func preserveHistory(from source: URL, to target: URL) throws {
        var files = [source]
        if try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            files = []
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
            if let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let entry as URL in enumerator {
                    let file = entry.standardizedFileURL
                    let values = try file.resourceValues(forKeys: keys)
                    guard contains(file), values.isSymbolicLink != true else { enumerator.skipDescendants(); continue }
                    if values.isRegularFile == true { files.append(file) }
                }
            }
        }
        for file in files {
            let oldHistory = historyDirectory(for: file)
            guard entryExists(at: oldHistory) else { continue }
            guard contains(oldHistory) else { throw VaultError.outsideVault }
            let movedFile = file == source ? target : target.appendingPathComponent(String(file.path.dropFirst(source.path.count + 1)))
            let newHistory = historyDirectory(for: movedFile)
            guard contains(newHistory) else { throw VaultError.outsideVault }
            try fm.createDirectory(at: newHistory, withIntermediateDirectories: true)
            for version in try fm.contentsOfDirectory(at: oldHistory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                let values = try version.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard contains(version), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                var destination = newHistory.appendingPathComponent(version.lastPathComponent)
                guard contains(destination) else { throw VaultError.outsideVault }
                if entryExists(at: destination) {
                    if try Data(contentsOf: version) == Data(contentsOf: destination) { continue }
                    destination = uniqueURL(named: version.lastPathComponent, in: newHistory, isDirectory: false)
                }
                // Retain the old copy so a failed filesystem move cannot lose existing history.
                try fm.copyItem(at: version, to: destination)
            }
        }
    }
    private func historyDirectory(for url: URL) -> URL {
        let key = SHA256.hash(data: Data(url.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(".pandanote/history/\(key)", isDirectory: true)
    }
    private func snapshot(_ text: String, for url: URL) throws {
        let directory = historyDirectory(for: url)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent > $1.lastPathComponent }) ?? []
        // Keep minute-level history to avoid duplicating every autosave.
        let minute = Int(Date().timeIntervalSince1970 / 60)
        let target = directory.appendingPathComponent("\(minute).md")
        if !fm.fileExists(atPath: target.path) { try text.write(to: target, atomically: true, encoding: .utf8) }
        for old in existing.dropFirst(99) { try fm.removeItem(at: old) }
    }
    public func versions(for url: URL) -> [URL] {
        ((try? fm.contentsOfDirectory(at: historyDirectory(for: url), includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

public struct Heading: Identifiable, Sendable {
    public var id: Int { offset }
    public let level: Int
    public let title: String
    public let offset: Int
}

public enum MarkdownInfo {
    private static func bodyOffset(_ text: String) -> Int {
        let source = text as NSString
        guard let opening = try? NSRegularExpression(pattern: "\\A\\x{FEFF}?---[ \\t]*\\r?\\n"),
              let first = opening.firstMatch(in: text, range: NSRange(location: 0, length: source.length)),
              let closing = try? NSRegularExpression(pattern: "(?m)^(?:---|\\.\\.\\.)[ \\t]*(?:\\r?\\n|$)"),
              let end = closing.firstMatch(in: text, range: NSRange(location: NSMaxRange(first.range), length: source.length - NSMaxRange(first.range))) else { return 0 }
        return NSMaxRange(end.range)
    }
    public static func body(_ text: String) -> String {
        (text as NSString).substring(from: bodyOffset(text)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func headings(_ text: String) -> [Heading] {
        var offset = 0, fenced = false
        var result: [Heading] = []
        let bodyStart = bodyOffset(text)
        for line in text.components(separatedBy: "\n") {
            defer { offset += (line as NSString).length + 1 }
            if offset < bodyStart { continue }
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle(); continue }
            if fenced { continue }
            let hashes = line.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") {
                result.append(Heading(level: hashes, title: String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespacesAndNewlines), offset: offset))
            }
        }
        return result
    }
    public static func tags(_ text: String) -> [String] {
        let pattern = "(?<![\\w#])#([\\p{L}][\\p{L}\\p{N}_/-]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let content = body(text), s = content as NSString
        return Array(Set(regex.matches(in: content, range: NSRange(location: 0, length: s.length)).map { s.substring(with: $0.range(at: 1)) })).sorted()
    }
    public static func words(_ text: String) -> Int { body(text).split(whereSeparator: { $0.isWhitespace }).count }
}
