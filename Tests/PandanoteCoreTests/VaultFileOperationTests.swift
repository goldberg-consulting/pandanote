import XCTest
@testable import PandanoteCore

final class VaultFileOperationTests: XCTestCase {
    private func temporaryVault() throws -> Vault {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Vault(root: root)
    }

    func test_createFile_whenNamesCollide_preservesExtensionAndContents() throws {
        let vault = try temporaryVault()
        for fileExtension in ["md", "markdown", "txt", "tex", "bib"] {
            let first = try vault.createFile(name: "Draft.\(fileExtension)", text: "Original")
            let second = try vault.createFile(name: "Draft.\(fileExtension)", text: "Second")
            XCTAssertEqual(second.lastPathComponent, "Draft 2.\(fileExtension)")
            XCTAssertEqual(try vault.read(first), "Original")
            XCTAssertEqual(try vault.read(second), "Second")
        }
        XCTAssertThrowsError(try vault.createFile(name: "Archive.zip"))
    }

    func test_directories_whenNestedFoldersAreEmpty_includesVisibleFolders() throws {
        let vault = try temporaryVault()
        _ = try vault.createFolder(name: "Empty", folder: "Research/Methods")
        _ = try vault.createFolder(name: "Empty", folder: "Research/Methods")
        try FileManager.default.createDirectory(at: vault.root.appendingPathComponent(".hidden/Child"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vault.root.appendingPathComponent("node_modules/Child"), withIntermediateDirectories: true)
        XCTAssertEqual(try vault.directories(), ["Research", "Research/Methods", "Research/Methods/Empty", "Research/Methods/Empty 2"])
    }

    func test_duplicate_whenFileOrFolderCopied_preservesOriginalAndNestedContents() throws {
        let vault = try temporaryVault()
        let file = try vault.createFile(name: "Paper.tex", folder: "Research/Nested", text: "Paper")
        let copy = try vault.duplicate(file)
        let nextCopy = try vault.duplicate(file)
        XCTAssertEqual(copy.lastPathComponent, "Paper copy.tex")
        XCTAssertEqual(nextCopy.lastPathComponent, "Paper copy 2.tex")
        let folderCopy = try vault.duplicate(vault.root.appendingPathComponent("Research"))
        XCTAssertEqual(folderCopy.lastPathComponent, "Research copy")
        XCTAssertEqual(try vault.read(folderCopy.appendingPathComponent("Nested/Paper.tex")), "Paper")
        try vault.save("Edited copy", to: copy, expected: "Paper")
        XCTAssertEqual(try vault.read(file), "Paper")
    }

    func test_renameAndMove_whenTargetExists_refusesOverwrite() throws {
        let vault = try temporaryVault()
        let original = try vault.create(name: "First", text: "Keep first")
        let second = try vault.create(name: "Second", text: "Keep second")
        let destination = try vault.create(name: "First", folder: "Archive", text: "Keep archived")
        XCTAssertThrowsError(try vault.rename(original, to: "Second.md"))
        XCTAssertThrowsError(try vault.move(original, toFolder: "Archive"))
        XCTAssertEqual(try vault.read(original), "Keep first")
        XCTAssertEqual(try vault.read(second), "Keep second")
        XCTAssertEqual(try vault.read(destination), "Keep archived")
    }

    func test_renameAndMove_whenFolderContainsNotes_preservesContentsAndHistory() throws {
        let vault = try temporaryVault()
        let original = try vault.create(name: "Draft", folder: "Research/Nested", text: "Original")
        try vault.save("Revised", to: original, expected: "Original")
        let folder = try vault.rename(vault.root.appendingPathComponent("Research"), to: "Writing")
        XCTAssertEqual(folder.lastPathComponent, "Writing")
        _ = try vault.createFolder(name: "Archive")
        let moved = try vault.move(folder, toFolder: "Archive")
        let file = moved.appendingPathComponent("Nested/Draft.md")
        XCTAssertEqual(try vault.read(file), "Revised")
        let history = try XCTUnwrap(vault.versions(for: file).first)
        XCTAssertEqual(try String(contentsOf: history, encoding: .utf8), "Original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    func test_rename_whenDestinationHasOlderHistory_preservesBothHistories() throws {
        let vault = try temporaryVault()
        let first = try vault.create(name: "First", text: "First original")
        try vault.save("First revised", to: first, expected: "First original")
        let second = try vault.create(name: "Second", text: "Second original")
        try vault.save("Second revised", to: second, expected: "Second original")
        _ = try vault.rename(second, to: "Third.md")
        let moved = try vault.rename(first, to: "Second.md")
        let versions = try vault.versions(for: moved).map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertEqual(Set(versions), ["First original", "Second original"])
    }

    func test_rename_whenOnlyCapitalizationChanges_preservesFileAndHistory() throws {
        let vault = try temporaryVault()
        let original = try vault.create(name: "draft", text: "Original")
        try vault.save("Revised", to: original, expected: "Original")
        let renamed = try vault.rename(original, to: "Draft.md")
        XCTAssertEqual(renamed.lastPathComponent, "Draft.md")
        XCTAssertEqual(try vault.read(renamed), "Revised")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.root.path).filter { !$0.hasPrefix(".") }, ["Draft.md"])
        let version = try XCTUnwrap(vault.versions(for: renamed).first)
        XCTAssertEqual(try String(contentsOf: version, encoding: .utf8), "Original")
    }

    func test_move_whenDestinationIsSelfDescendantOrMissing_refusesOperation() throws {
        let vault = try temporaryVault()
        let folder = try vault.createFolder(name: "Research")
        _ = try vault.createFolder(name: "Nested", folder: "Research")
        XCTAssertThrowsError(try vault.move(folder, toFolder: "Research/Nested"))
        XCTAssertThrowsError(try vault.move(folder, toFolder: "Missing"))
        XCTAssertEqual(try vault.move(folder, toFolder: ""), folder)
        XCTAssertEqual(try vault.directories(), ["Research", "Research/Nested"])
    }

    func test_fileOperations_whenNamesAreInvalid_rejectsPathAndControlCharacters() throws {
        let vault = try temporaryVault()
        let source = try vault.create(name: "Original")
        for name in ["", "  ", ".hidden", "../Outside", "With/Slash", "With:Colon", "With\nNewline", "With\u{0}Null"] {
            XCTAssertThrowsError(try vault.createFolder(name: name))
            XCTAssertThrowsError(try vault.rename(source, to: name))
        }
        XCTAssertThrowsError(try vault.move(source, toFolder: ".."))
        XCTAssertThrowsError(try vault.rename(source, to: "Missing extension"))
        XCTAssertThrowsError(try vault.rename(source, to: "Unsupported.zip"))
        XCTAssertThrowsError(try vault.createFolder(name: "Outside", folder: ".."))
        XCTAssertThrowsError(try vault.rename(vault.root, to: "Other"))
        XCTAssertThrowsError(try vault.trash(vault.root))
    }

    func test_fileOperations_whenSymlinksLeadOutsideVault_refusesAccess() throws {
        let vault = try temporaryVault()
        let other = try temporaryVault()
        let privateFile = try other.create(name: "Private", text: "External")
        let alias = vault.root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: other.root)
        XCTAssertThrowsError(try vault.createFile(name: "New.md", folder: "Alias"))
        XCTAssertThrowsError(try vault.createFolder(name: "New", folder: "Alias"))
        XCTAssertThrowsError(try vault.duplicate(alias))
        XCTAssertThrowsError(try vault.rename(alias, to: "Renamed"))
        XCTAssertThrowsError(try vault.trash(alias))
        XCTAssertTrue(try vault.directories().isEmpty)
        XCTAssertEqual(try other.read(privateFile), "External")
    }

    func test_createAndRename_whenDanglingSymlinkOccupiesName_doesNotReplaceLink() throws {
        let vault = try temporaryVault()
        let missing = vault.root.appendingPathComponent("Missing.md")
        let alias = vault.root.appendingPathComponent("Note.md")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: missing)
        let created = try vault.create(name: "Note", text: "New note")
        XCTAssertEqual(created.lastPathComponent, "Note 2.md")
        XCTAssertThrowsError(try vault.rename(created, to: "Note.md"))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), missing.path)
    }
}
