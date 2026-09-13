import XCTest
@testable import PandanoteCore

final class ReplacementBatchTests: XCTestCase {
    private func fixture() throws -> (Vault, [ReplacementFileChange]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let vault = Vault(root: root)
        _ = try vault.create(name: "A", text: "alpha 🐼")
        _ = try vault.create(name: "B", folder: "Research", text: "beta")
        return (vault, [
            .init(relativePath: "A.md", before: "alpha 🐼", after: "ALPHA 🐼", replacementCount: 1),
            .init(relativePath: "Research/B.md", before: "beta", after: "BETA", replacementCount: 1)
        ])
    }
    func testBatchSavesOriginalsAndUndoRestoresBothFiles() throws {
        let (vault, changes) = try fixture()
        let result = try ReplacementBatch.apply(changes, in: vault)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.applied, changes)
        let backup = try XCTUnwrap(result.backupURL)
        XCTAssertTrue(vault.contains(backup))
        let data = try Data(contentsOf: backup)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stored = try XCTUnwrap(record["changes"] as? [[String: Any]])
        XCTAssertEqual(stored.first?["before"] as? String, "alpha 🐼")
        XCTAssertEqual(try vault.read(vault.root.appendingPathComponent("A.md")), "ALPHA 🐼")
        let undone = try ReplacementBatch.undo(changes, in: vault)
        XCTAssertNil(undone.failure)
        XCTAssertEqual(try vault.read(vault.root.appendingPathComponent("A.md")), "alpha 🐼")
        XCTAssertEqual(try vault.read(vault.root.appendingPathComponent("Research/B.md")), "beta")
    }
    func testPreflightRejectsChangedSecondFileBeforeWritingFirst() throws {
        let (vault, changes) = try fixture()
        try "Newer text".write(to: vault.root.appendingPathComponent("Research/B.md"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ReplacementBatch.apply(changes, in: vault))
        XCTAssertEqual(try vault.read(vault.root.appendingPathComponent("A.md")), "alpha 🐼")
        XCTAssertEqual(try vault.read(vault.root.appendingPathComponent("Research/B.md")), "Newer text")
    }
    func testUndoRefusesNewerEditsAndAllowsAlreadyRestoredNote() throws {
        let (vault, changes) = try fixture()
        _ = try ReplacementBatch.apply(changes, in: vault)
        try vault.save("New writing", to: vault.root.appendingPathComponent("A.md"), expected: "ALPHA 🐼")
        XCTAssertThrowsError(try ReplacementBatch.undo(changes, in: vault))
        XCTAssertEqual(try vault.read(vault.root.appendingPathComponent("Research/B.md")), "BETA")
        try vault.save("alpha 🐼", to: vault.root.appendingPathComponent("A.md"), expected: "New writing")
        let undone = try ReplacementBatch.undo(changes, in: vault)
        XCTAssertEqual(undone.applied.count, 1)
        XCTAssertEqual(try vault.read(vault.root.appendingPathComponent("Research/B.md")), "beta")
    }
    func testBatchRejectsDuplicatePathsTraversalAndOversizedOutput() throws {
        let (vault, changes) = try fixture()
        XCTAssertThrowsError(try ReplacementBatch.apply([changes[0], changes[0]], in: vault))
        XCTAssertThrowsError(try ReplacementBatch.apply([.init(relativePath: "../escape.md", before: "", after: "changed", replacementCount: 1)], in: vault))
        XCTAssertThrowsError(try ReplacementBatch.apply([.init(relativePath: "A.md", before: "alpha 🐼", after: String(repeating: "x", count: 8_000_001), replacementCount: 1)], in: vault))
        XCTAssertEqual(try vault.read(vault.root.appendingPathComponent("A.md")), "alpha 🐼")
    }
}
