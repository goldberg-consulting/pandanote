import XCTest
@testable import PandanoteCore

final class GitRepositoryTests: XCTestCase {
    func fixture() async throws -> (URL, GitRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        try await repo.initialize()
        _ = try git(root, ["config", "commit.gpgsign", "false"])
        return (root, repo)
    }
    @discardableResult func git(_ root: URL, _ args: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C",root.path] + args
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        var env = ProcessInfo.processInfo.environment; env["GIT_LITERAL_PATHSPECS"] = "1"; process.environment = env
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    func write(_ root: URL, _ file: String, _ value: String) throws { try value.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8) }
    func commit(_ repo: GitRepository, _ paths: [String], _ snapshot: GitSnapshot) async throws -> String {
        try await repo.commit(paths: paths, message: "Reviewed revision", expected: snapshot, authorName: "Pandanote Test", authorEmail: "test@example.invalid")
    }
    func testFirstCommitAndHistoryIncludingLiteralSpecialFilenames() async throws {
        let (root, repo) = try await fixture()
        let name = "[draft] 🐼\nchapter.md"
        try write(root, name, "First")
        let snapshot = try await repo.snapshot()
        XCTAssertTrue(snapshot.changes.contains { $0.path == name })
        let hash = try await commit(repo, [name, ".gitignore"], snapshot)
        let after = try await repo.snapshot()
        XCTAssertTrue(after.changes.isEmpty)
        XCTAssertEqual(after.commits.first?.hash, hash)
        XCTAssertEqual(try git(root, ["show", "HEAD:" + name]), "First")
    }
    func testCommitSelectedWorkingFilesPreservesUnrelatedStagedBytes() async throws {
        let (root, repo) = try await fixture()
        try write(root, "A.md", "A1"); try write(root, "B.md", "B1")
        _ = try await commit(repo, ["A.md", "B.md", ".gitignore"], repo.snapshot())
        try write(root, "B.md", "B staged"); try git(root, ["add", "B.md"])
        try write(root, "B.md", "B unstaged"); try write(root, "A.md", "A2")
        _ = try await commit(repo, ["A.md"], repo.snapshot())
        XCTAssertEqual(try git(root, ["show", "HEAD:A.md"]), "A2")
        XCTAssertEqual(try git(root, ["show", "HEAD:B.md"]), "B1")
        XCTAssertEqual(try git(root, ["show", ":B.md"]), "B staged")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("B.md"), encoding: .utf8), "B unstaged")
    }
    func testStaleReviewRefusesCommitAndLeavesIndexAndHeadUntouched() async throws {
        let (root, repo) = try await fixture(); try write(root, "A.md", "Original")
        let snapshot = try await repo.snapshot()
        try write(root, "A.md", "Unreviewed change")
        do { _ = try await commit(repo, ["A.md"], snapshot); XCTFail("Stale snapshot committed") } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        let after = try await repo.snapshot()
        XCTAssertTrue(after.head.isEmpty)
        XCTAssertTrue(after.changes.contains { $0.path == "A.md" && $0.status == "??" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
    }
    func testIndexLockAndActiveMergeAreRespected() async throws {
        let (root, repo) = try await fixture(); try write(root, "A.md", "Original")
        let snapshot = try await repo.snapshot()
        try write(root, ".git/index.lock", "another client")
        do { _ = try await commit(repo, ["A.md"], snapshot); XCTFail("Ignored lock") } catch { XCTAssertTrue(error.localizedDescription.contains("lock")) }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".git/index.lock"), encoding: .utf8), "another client")
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git/index.lock"))
        try write(root, ".git/MERGE_HEAD", "abc")
        do { _ = try await commit(repo, ["A.md"], snapshot); XCTFail("Ignored merge") } catch { XCTAssertTrue(error.localizedDescription.contains("merge")) }
    }
    func testDeletionAndRenameAreCommittedAsReviewedWithoutTouchingOtherFiles() async throws {
        let (root, repo) = try await fixture(); try write(root, "Old.md", "Original")
        _ = try await commit(repo, ["Old.md", ".gitignore"], repo.snapshot())
        try FileManager.default.moveItem(at: root.appendingPathComponent("Old.md"), to: root.appendingPathComponent("New.md"))
        _ = try await commit(repo, ["Old.md", "New.md"], repo.snapshot())
        let after = try await repo.snapshot()
        XCTAssertTrue(after.changes.isEmpty)
        XCTAssertEqual(try git(root, ["ls-tree", "--name-only", "HEAD"]), ".gitignore\nNew.md")
    }
}
