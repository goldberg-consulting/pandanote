import XCTest
@testable import PandanoteCore

final class VaultTests: XCTestCase {
    func temporaryVault() throws -> Vault {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Vault(root: root)
    }
    func testDirectFolderBrowsingIncludesEmptyFoldersAndIgnoresFilesAndPackages() throws {
        let vault = try temporaryVault()
        for name in ["Empty", "Research/Nested", ".hidden", "Example.app/Contents"] {
            try FileManager.default.createDirectory(at: vault.root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        _ = try vault.create(name: "Note")
        XCTAssertEqual(try Vault.childDirectories(in: vault.root).map(\.lastPathComponent), ["Empty", "Research"])
        XCTAssertEqual(try Vault.validatedRoot(vault.root), vault.root)
        XCTAssertThrowsError(try Vault.childDirectories(in: vault.root.appendingPathComponent("missing")))
    }
    func testVaultValidationRejectsFilesPackagesMissingAndRemoteURLs() throws {
        let vault = try temporaryVault()
        let file = try vault.create(name: "Note")
        let package = vault.root.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        for url in [file, package, vault.root.appendingPathComponent("missing"), URL(string: "https://example.com")!] {
            XCTAssertThrowsError(try Vault.validatedRoot(url))
        }
    }
    func testExternalEditsCannotBeOverwrittenAndHistoryPersists() throws {
        let vault = try temporaryVault()
        let file = try vault.create(name: "Research", text: "Original")
        try vault.save("Revised", to: file, expected: "Original")
        XCTAssertEqual(vault.versions(for: file).count, 1)
        try "External edit".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try vault.save("Local edit", to: file, expected: "Revised"))
        XCTAssertEqual(try vault.read(file), "External edit")
    }
    func testNamesAndSymlinksCannotEscapeVault() throws {
        let vault = try temporaryVault(), other = try temporaryVault()
        XCTAssertThrowsError(try vault.create(name: "../outside"))
        let outside = try other.create(name: "Private", text: "Secret")
        let alias = vault.root.appendingPathComponent("Alias.md")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        XCTAssertThrowsError(try vault.read(alias))
        XCTAssertTrue(try vault.scan().isEmpty)
    }
    func testOutlineExcludesCodeAndUsesUTF16Offsets() {
        let text = "🐼\n# Opening\n```python\n# code comment\n```\n## Methods"
        let headings = MarkdownInfo.headings(text)
        XCTAssertEqual(headings.map(\.title), ["Opening", "Methods"])
        XCTAssertEqual(headings.first?.offset, 3)
    }
    func testDuplicateNotesNeverOverwrite() throws {
        let vault = try temporaryVault()
        let first = try vault.create(name: "Note", text: "One")
        let second = try vault.create(name: "Note", text: "Two")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try vault.read(first), "One")
        XCTAssertEqual(try vault.scan().count, 2)
    }
    func testPreambleCommentsAndColorsAreNotHeadingsOrTags() {
        let text = "\u{FEFF}---\r\n# Settings\r\ninkwell.code-bg: '#f5f5f5'\r\n---\r\n# Paper\r\n\r\n#research"
        XCTAssertEqual(MarkdownInfo.tags(text), ["research"])
        XCTAssertEqual(MarkdownInfo.headings(text).map(\.title), ["Paper"])
        XCTAssertEqual(MarkdownInfo.headings(text).first?.offset, (text as NSString).range(of: "# Paper").location)
    }
}
