import Foundation
import CryptoKit
import Darwin

public struct GitFailure: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}
public struct GitChange: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let status: String
}
public struct GitCommit: Identifiable, Sendable {
    public var id: String { hash }
    public let hash: String, title: String, author: String, date: String
}
public struct GitSnapshot: Sendable {
    public let branch: String, head: String, token: String
    public let changes: [GitChange]
    public let commits: [GitCommit]
    public let authorName: String, authorEmail: String
}

/// Local, reviewed commits. A private index keeps unrelated staged changes intact.
/// The real index lock and compare-and-swap HEAD protect against concurrent writers.
public actor GitRepository {
    public let root: URL
    private let fm = FileManager.default
    public init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }
    private func command(_ args: [String], input: Data? = nil, environment: [String: String] = [:], allowFailure: Bool = false) throws -> (Data, Int32) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "--no-pager"] + args
        var env = ProcessInfo.processInfo.environment
        // Do not inherit another process's repository or index selection.
        for key in env.keys.filter({ $0.hasPrefix("GIT_") }) { env.removeValue(forKey: key) }
        env.merge(["GIT_LITERAL_PATHSPECS":"1", "GIT_TERMINAL_PROMPT":"0", "GIT_OPTIONAL_LOCKS":"0", "LC_ALL":"C"]) { _, v in v }
        env.merge(environment) { _, v in v }; process.environment = env
        let temp = fm.temporaryDirectory.appendingPathComponent("pandanote-git-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let output = temp.appendingPathComponent("output"), error = temp.appendingPathComponent("error"), stdin = temp.appendingPathComponent("input")
        fm.createFile(atPath: output.path, contents: nil); fm.createFile(atPath: error.path, contents: nil)
        try (input ?? Data()).write(to: stdin)
        let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: error), source = try FileHandle(forReadingFrom: stdin)
        defer { try? out.close(); try? err.close(); try? source.close() }
        process.standardOutput = out; process.standardError = err; process.standardInput = source
        try process.run(); process.waitUntilExit()
        if process.terminationStatus != 0 && !allowFailure {
            throw GitFailure(String(data: try Data(contentsOf: error), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Git could not complete this operation.")
        }
        return (try Data(contentsOf: output), process.terminationStatus)
    }
    private func string(_ args: [String], environment: [String: String] = [:], allowFailure: Bool = false) throws -> String {
        String(decoding: try command(args, environment: environment, allowFailure: allowFailure).0, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    private func checkRoot() throws {
        let top = try string(["rev-parse", "--show-toplevel"], allowFailure: true)
        guard !top.isEmpty else { throw GitFailure("This vault has no Git repository. Choose Start Git tracking to create one.") }
        guard URL(fileURLWithPath: top).resolvingSymlinksInPath() == root else { throw GitFailure("This vault is inside a larger repository. Open \(top) as the vault to manage its changes.") }
    }
    private func indexURL() throws -> URL {
        let path = try string(["rev-parse", "--path-format=absolute", "--git-path", "index"])
        return URL(fileURLWithPath: path)
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func safeFile(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), Vault(root: root).contains(url) else { throw VaultError.outsideVault }
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else { throw GitFailure("Review symbolic links in your Git client: \(path)") }
        return url
    }
    public func initialize() throws {
        let existing = try string(["rev-parse", "--show-toplevel"], allowFailure: true)
        guard existing.isEmpty else { try checkRoot(); return }
        _ = try command(["init", "-b", "main"])
        let ignore = root.appendingPathComponent(".gitignore")
        let previous = (try? String(contentsOf: ignore, encoding: .utf8)) ?? ""
        let additions = [".DS_Store", ".pandanote/history/", ".pandanote/reviews/", ".pandanote/git-transaction.json", ".inkwell/outputs/", ".inkwell/cache/", "*.aux", "*.log", "*.synctex.gz"]
            .filter { !previous.components(separatedBy: .newlines).contains($0) }
        if !additions.isEmpty { try Vault(root: root).save(previous + (previous.isEmpty || previous.hasSuffix("\n") ? "" : "\n") + "\n# Pandanote local working files\n" + additions.joined(separator: "\n") + "\n", to: ignore, expected: fm.fileExists(atPath: ignore.path) ? previous : nil) }
    }
    private struct Transaction: Codable { let oldHead: String, newHead: String, indexDigest: String }
    private var journal: URL { root.appendingPathComponent(".pandanote/git-transaction.json") }
    private func recover() throws {
        guard Vault(root: root).contains(journal) else { throw VaultError.outsideVault }
        guard fm.fileExists(atPath: journal.path) else { return }
        let saved = try JSONDecoder().decode(Transaction.self, from: Data(contentsOf: journal))
        let index = try indexURL(), lock = URL(fileURLWithPath: index.path + ".lock")
        let head = try string(["rev-parse", "--verify", "HEAD"], allowFailure: true)
        if let data = try? Data(contentsOf: lock), digest(data) == saved.indexDigest {
            if head == saved.newHead {
                guard Darwin.rename(lock.path, index.path) == 0 else { throw GitFailure("Git saved the commit but could not finish its index. Close other Git clients and refresh to recover.") }
            } else if head == saved.oldHead { try fm.removeItem(at: lock) }
            else { throw GitFailure("Another Git operation changed HEAD during recovery. The saved transaction is preserved for inspection.") }
        } else if head != saved.newHead || (try? Data(contentsOf: index)).map(digest) != saved.indexDigest {
            throw GitFailure("An interrupted Git operation needs inspection. Its recovery record and index have been preserved.")
        }
        try fm.removeItem(at: journal)
    }
    public func snapshot() throws -> GitSnapshot {
        try checkRoot(); try recover()
        return try readSnapshot()
    }
    private func readSnapshot() throws -> GitSnapshot {
        let head = try string(["rev-parse", "--verify", "HEAD"], allowFailure: true)
        let branch = try string(["symbolic-ref", "--short", "-q", "HEAD"], allowFailure: true)
        let raw = try command(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames"]).0
        let changes = String(decoding: raw, as: UTF8.self).split(separator: "\0").compactMap { entry -> GitChange? in
            guard entry.utf8.count >= 4 else { return nil }
            return GitChange(path: String(entry.dropFirst(3)), status: String(entry.prefix(2)))
        }
        var tokenData = Data((head + "\n" + branch).utf8); tokenData.append(raw)
        tokenData.append((try? Data(contentsOf: indexURL())) ?? Data())
        for change in changes {
            let url = root.appendingPathComponent(change.path)
            if let file = try? safeFile(change.path), let bytes = try? Data(contentsOf: file, options: .mappedIfSafe) {
                tokenData.append(Data(digest(bytes).utf8))
                let mode = (try? fm.attributesOfItem(atPath: file.path)[.posixPermissions]) as? NSNumber
                tokenData.append(Data(String(mode?.intValue ?? 0).utf8))
            }
            else { tokenData.append(Data("missing-or-link:\(url.path)".utf8)) }
        }
        let log = head.isEmpty ? "" : try string(["log", "-30", "--format=%H%x00%s%x00%an%x00%aI%x00"])
        let fields = log.components(separatedBy: "\0")
        var commits: [GitCommit] = []
        for i in stride(from: 0, to: max(0, fields.count - 3), by: 4) {
            commits.append(GitCommit(hash: fields[i].trimmingCharacters(in: .newlines), title: fields[i+1], author: fields[i+2], date: fields[i+3]))
        }
        return GitSnapshot(branch: branch.isEmpty ? "Detached HEAD" : branch, head: head, token: digest(tokenData), changes: changes, commits: commits, authorName: try string(["config", "user.name"], allowFailure: true), authorEmail: try string(["config", "user.email"], allowFailure: true))
    }
    public func diff(path: String, snapshot: GitSnapshot) throws -> String {
        let file = try safeFile(path)
        guard snapshot.changes.contains(where: { $0.path == path }) else { throw GitFailure("Refresh the change list first.") }
        if snapshot.head.isEmpty || snapshot.changes.first(where: { $0.path == path })?.status == "??" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return "New binary file: \(path)" }
            return "+++ \(path)\n" + text.components(separatedBy: "\n").map { "+" + $0 }.joined(separator: "\n")
        }
        return try string(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "HEAD", "--", path])
    }
    public func commitDiff(_ hash: String) throws -> String {
        guard hash.range(of: "^[a-f0-9]{40,64}$", options: .regularExpression) != nil else { throw GitFailure("Choose a commit from history.") }
        return try string(["show", "--no-ext-diff", "--no-textconv", "--no-color", "--format=fuller", hash, "--"])
    }
    public func commit(paths: [String], message: String, expected: GitSnapshot, authorName: String, authorEmail: String) throws -> String {
        try checkRoot(); try recover()
        for state in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"] {
            let location = try string(["rev-parse", "--path-format=absolute", "--git-path", state])
            if fm.fileExists(atPath: location) { throw GitFailure("Finish the active merge, rebase, or cherry-pick in your Git client before creating a Pandanote commit.") }
        }
        if try string(["config", "--bool", "commit.gpgsign"], allowFailure: true) == "true" { throw GitFailure("This repository requires signed commits. Commit in your configured Git client; Pandanote currently creates local unsigned commits.") }
        let paths = Array(Set(paths)).sorted()
        guard !paths.isEmpty, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitFailure("Choose files and describe this change.") }
        guard !authorName.trimmingCharacters(in: .whitespaces).isEmpty, !authorEmail.trimmingCharacters(in: .whitespaces).isEmpty else { throw GitFailure("Enter your name and email for the Git commit.") }
        for path in paths { _ = try safeFile(path); guard expected.changes.contains(where: { $0.path == path }) else { throw GitFailure("The change list is out of date. Refresh and review again.") } }
        guard !expected.changes.contains(where: { $0.status.contains("U") || ["AA", "DD"].contains($0.status) }) else { throw GitFailure("Resolve the repository’s merge conflicts before committing.") }
        let index = try indexURL(), lock = URL(fileURLWithPath: index.path + ".lock")
        let descriptor = Darwin.open(lock.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw GitFailure("Another Git operation holds the index lock. Let it finish, then refresh.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var published = false
        defer { try? handle.close(); if !published { try? fm.removeItem(at: lock); try? fm.removeItem(at: journal) } }
        guard try readSnapshot().token == expected.token else { throw GitFailure("Files, staging, or history changed since you reviewed them. Refresh before committing.") }
        let temp = fm.temporaryDirectory.appendingPathComponent("pandanote-commit-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let privateIndex = temp.appendingPathComponent("commit-index"), preservedIndex = temp.appendingPathComponent("preserved-index")
        let commitEnv = ["GIT_INDEX_FILE":privateIndex.path, "GIT_AUTHOR_NAME":authorName, "GIT_AUTHOR_EMAIL":authorEmail, "GIT_COMMITTER_NAME":authorName, "GIT_COMMITTER_EMAIL":authorEmail]
        _ = try command(expected.head.isEmpty ? ["read-tree", "--empty"] : ["read-tree", expected.head], environment: commitEnv)
        _ = try command(["add", "-A", "--"] + paths, environment: commitEnv)
        let tree = try string(["write-tree"], environment: commitEnv)
        if !expected.head.isEmpty, tree == (try string(["rev-parse", "HEAD^{tree}"])) { throw GitFailure("The selected files have no changes to commit.") }
        let staged = try command(["ls-files", "--stage", "-z", "--"] + paths, environment: commitEnv).0
        let preservedEnv = ["GIT_INDEX_FILE":preservedIndex.path]
        if fm.fileExists(atPath: index.path) { try fm.copyItem(at: index, to: preservedIndex) }
        else { _ = try command(["read-tree", "--empty"], environment: preservedEnv) }
        _ = try command(["update-index", "--force-remove", "--"] + paths, environment: preservedEnv)
        _ = try command(["update-index", "-z", "--index-info"], input: staged, environment: preservedEnv)
        let newIndex = try Data(contentsOf: preservedIndex)
        // Build the object without touching HEAD or the real index. No hooks run.
        var args = ["commit-tree", tree]
        if !expected.head.isEmpty { args += ["-p", expected.head] }
        let hash = String(decoding: try command(args, input: Data((message + "\n").utf8), environment: commitEnv).0, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard try readSnapshot().token == expected.token else { throw GitFailure("Files changed while preparing the commit. Nothing was committed; refresh and review again.") }
        try handle.write(contentsOf: newIndex); try handle.synchronize()
        guard Vault(root: root).contains(journal) else { throw VaultError.outsideVault }
        try fm.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Transaction(oldHead: expected.head, newHead: hash, indexDigest: digest(newIndex))).write(to: journal, options: .atomic)
        let emptyHead = String(repeating: "0", count: hash.count)
        _ = try command(["update-ref", "-m", "commit: " + String(message.prefix(100)), "HEAD", hash, expected.head.isEmpty ? emptyHead : expected.head])
        published = true
        guard Darwin.rename(lock.path, index.path) == 0 else { throw GitFailure("Commit \(hash.prefix(8)) was saved. Refresh to finish the recoverable index update.") }
        try fm.removeItem(at: journal)
        return hash
    }
}
