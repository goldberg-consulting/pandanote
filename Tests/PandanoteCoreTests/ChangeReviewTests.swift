import XCTest
@testable import PandanoteCore

final class ChangeReviewTests: XCTestCase {
    func testUnicodePassageReplacementPreservesEverythingOutsideSelection() throws {
        let base = "---\ntitle: 🐼\n---\n\nA naïve sentence.\n\n```python\nprint(1)\n```"
        let range = (base as NSString).range(of: "A naïve sentence.")
        let proposal = try ChangeProposal(relativePath: "Paper.md", instruction: "Reword", provider: "Test", base: base, range: range, replacement: "A clearer sentence.")
        XCTAssertEqual(try proposal.applying(to: base, relativePath: "Paper.md"), base.replacingOccurrences(of: "A naïve sentence.", with: "A clearer sentence."))
        XCTAssertThrowsError(try proposal.applying(to: base + "New work", relativePath: "Paper.md"))
        XCTAssertThrowsError(try proposal.applying(to: base, relativePath: "Other.md"))
    }
    func testEmptyAndSplitSurrogateSelectionsAreRejected() {
        XCTAssertThrowsError(try ChangeProposal(relativePath: "A.md", instruction: "Edit", provider: "Test", base: "🐼", range: NSRange(location: 1, length: 1), replacement: "X"))
        XCTAssertThrowsError(try ChangeProposal(relativePath: "A.md", instruction: "Edit", provider: "Test", base: "A", range: NSRange(location: 0, length: 0), replacement: "X"))
    }
    func testDecisionArchiveSurvivesReloadAndCannotReapplyAcceptedProposal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = ChangeArchive(vault: Vault(root: root))
        var proposal = try ChangeProposal(relativePath: "A.md", instruction: "Reword", provider: "Test", base: "One", range: NSRange(location: 0, length: 3), replacement: "Two")
        try archive.store(proposal)
        XCTAssertEqual(try archive.list().first?.replacement, "Two")
        proposal.decision = "accepted"; try archive.store(proposal)
        XCTAssertEqual(try archive.list().count, 1)
        XCTAssertEqual(try archive.list().first?.decision, "accepted")
        XCTAssertThrowsError(try proposal.applying(to: "One", relativePath: "A.md"))
    }
    func testDiffRetainsUnchangedContextAndMarksInsertionsAndDeletions() {
        let lines = TextDiff.lines(before: "Heading\nold\nend", after: "Heading\nnew\nend")
        XCTAssertEqual(lines.map { $0.kind + $0.text }, [" Heading", "-old", "+new", " end"])
    }
}
