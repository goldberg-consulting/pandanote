import XCTest
import PandanoteCore
@testable import Pandanote

final class WorkspaceFileActionsTests: XCTestCase {
    @MainActor private func fixture(writer: (@Sendable (URL, URL, String, String) throws -> Void)? = nil, scanner: @escaping @Sendable (Vault) throws -> ([NoteFile], [String]) = { (try $0.scan(), try $0.directories()) }) async throws -> (Workspace, Vault, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults.standard
        let keys = ["autosave", "favorites", "pinned"]
        let old = keys.map { defaults.object(forKey: $0) }
        defaults.set(false, forKey: "autosave")
        addTeardownBlock { for (key, value) in zip(keys, old) { defaults.set(value, forKey: key) } }
        let vault = Vault(root: root)
        let a = try vault.create(name: "A", folder: "Research", text: "# A\nOriginal 🐼 passage.")
        let b = try vault.create(name: "B", text: "# B\nOther note.")
        let workspace: Workspace
        if let writer { workspace = Workspace(restoreVault: false, writeDocument: writer, scanVault: scanner) }
        else { workspace = Workspace(restoreVault: false, scanVault: scanner) }
        workspace.root = root; workspace.notes = try vault.scan()
        await workspace.selectAndWait(a)
        return (workspace, vault, a, b)
    }

    func testRightClickedInactiveNoteIsRenamedWithoutChangingActiveDocument() async throws {
        try await inactiveRename()
    }
    @MainActor private func inactiveRename() async throws {
        let (workspace, vault, a, b) = try await fixture()
        workspace.edit("Unsaved 🐼 writing")
        await workspace.renameAndWait(b, to: "Renamed.txt")
        XCTAssertNil(workspace.error)
        XCTAssertEqual(workspace.selected, a)
        XCTAssertEqual(workspace.text, "Unsaved 🐼 writing")
        XCTAssertEqual(try vault.read(a), workspace.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
        XCTAssertEqual(try vault.read(vault.root.appendingPathComponent("Renamed.txt")), "# B\nOther note.")
    }

    func testFolderRenameAndMoveRemapTabsBookmarksAndSelectedFilter() async throws {
        try await folderMove()
    }
    @MainActor private func folderMove() async throws {
        let (workspace, vault, a, b) = try await fixture()
        workspace.tabs = [a, b]; workspace.favorites = [a.path]; workspace.pinned = [a.path]
        workspace.filter = "folder:Research"; workspace.edit("New content")
        await workspace.renameAndWait(a.deletingLastPathComponent(), to: "Archive")
        let renamed = vault.root.appendingPathComponent("Archive/A.md")
        XCTAssertEqual(workspace.selected, renamed)
        XCTAssertEqual(workspace.tabs, [renamed, b])
        XCTAssertEqual(workspace.favorites, [renamed.path])
        XCTAssertEqual(workspace.pinned, [renamed.path])
        XCTAssertEqual(workspace.filter, "folder:Archive")
        XCTAssertEqual(try vault.read(renamed), "New content")
        XCTAssertFalse(vault.versions(for: renamed).isEmpty)
        let destination = try vault.createFolder(name: "Projects")
        await workspace.moveAndWait(renamed.deletingLastPathComponent(), to: destination)
        let moved = destination.appendingPathComponent("Archive/A.md")
        XCTAssertEqual(workspace.selected, moved)
        XCTAssertEqual(workspace.tabs, [moved, b])
        XCTAssertEqual(workspace.filter, "folder:Projects/Archive")
        XCTAssertEqual(workspace.favorites, [moved.path])
        XCTAssertEqual(try vault.read(moved), "New content")
    }

    func testCreationShowsEmptyFoldersAndUsesRequestedParent() async throws { try await creation() }
    @MainActor private func creation() async throws {
        let (workspace, vault, _, _) = try await fixture()
        await workspace.createFolderAndWait(name: "Empty", in: vault.root.appendingPathComponent("Research"))
        XCTAssertTrue(workspace.folders.contains("Research/Empty"))
        XCTAssertEqual(workspace.filter, "folder:Research/Empty")
        await workspace.createFileAndWait(name: "references.bib", in: vault.root.appendingPathComponent("Research/Empty"))
        XCTAssertEqual(workspace.selected?.path, vault.root.appendingPathComponent("Research/Empty/references.bib").path)
        XCTAssertTrue(workspace.notes.contains { $0.relativePath == "Research/Empty/references.bib" })
    }

    func testDuplicateIncludesPendingEditsAndDoesNotOverwriteExistingCopy() async throws { try await duplicate() }
    @MainActor private func duplicate() async throws {
        let (workspace, vault, a, _) = try await fixture()
        _ = try vault.create(name: "A copy", folder: "Research", text: "Keep this")
        workspace.edit("Latest draft")
        await workspace.duplicateAndWait(a)
        XCTAssertEqual(workspace.selected?.lastPathComponent, "A copy 2.md")
        XCTAssertEqual(workspace.text, "Latest draft")
        XCTAssertEqual(try vault.read(a), "Latest draft")
        XCTAssertEqual(try vault.read(a.deletingLastPathComponent().appendingPathComponent("A copy.md")), "Keep this")
    }

    func testConflictingRenameAndExternalEditLeaveBothFilesUntouched() async throws { try await conflicts() }
    @MainActor private func conflicts() async throws {
        let (workspace, vault, a, b) = try await fixture()
        let existing = try vault.create(name: "Taken", folder: "Research", text: "Keep this")
        await workspace.renameAndWait(a, to: "Taken.md")
        XCTAssertNotNil(workspace.error)
        XCTAssertEqual(workspace.selected, a)
        XCTAssertEqual(try vault.read(existing), "Keep this")
        workspace.error = nil
        workspace.edit("Unsaved")
        try "External edit".write(to: a, atomically: true, encoding: .utf8)
        await workspace.renameAndWait(b, to: "Should not exist.md")
        XCTAssertNotNil(workspace.error)
        XCTAssertTrue(workspace.dirty)
        XCTAssertEqual(workspace.text, "Unsaved")
        XCTAssertEqual(try vault.read(a), "External edit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        XCTAssertFalse(workspace.fileOperationInProgress)
    }

    func testCloseAllPersistsEditsAndRefreshDoesNotReopenNote() async throws { try await closeAll() }
    @MainActor private func closeAll() async throws {
        let (workspace, vault, a, b) = try await fixture()
        workspace.tabs = [a, b]; workspace.edit("Saved before close")
        await workspace.closeTabsAndWait(workspace.tabs)
        workspace.refresh()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(workspace.tabs.isEmpty)
        XCTAssertNil(workspace.selected)
        XCTAssertTrue(workspace.text.isEmpty)
        XCTAssertTrue(workspace.previewHTML.isEmpty)
        XCTAssertEqual(try vault.read(a), "Saved before close")
    }

    func testExtractionPreservesUnicodeAndUsesUnambiguousLink() async throws { try await extraction() }
    @MainActor private func extraction() async throws {
        let (workspace, vault, a, _) = try await fixture()
        _ = try vault.create(name: "Extracted", text: "Same title elsewhere")
        let source = workspace.text
        let range = (source as NSString).range(of: "🐼 passage")
        await workspace.extractSelectionAndWait(name: "Extracted", source: source, range: range, file: a)
        let extracted = vault.root.appendingPathComponent("Research/Extracted.md")
        XCTAssertNil(workspace.error)
        XCTAssertEqual(try vault.read(extracted), "🐼 passage")
        XCTAssertEqual(workspace.text, "# A\nOriginal [[Research/Extracted.md|Extracted]].")
        XCTAssertEqual(workspace.pendingReplacement?.before, source)
        XCTAssertEqual(workspace.pendingReplacement?.label, "Extract selection to note")
        XCTAssertEqual(try vault.read(a), workspace.text)
        workspace.openWikiLink("Research/Extracted.md")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(workspace.selected, extracted)
    }

    func testSlowRescanDoesNotKeepEditorOrNavigationLocked() async throws { try await slowRescan() }
    @MainActor private func slowRescan() async throws {
        let entered = expectation(description: "Post-move scan began")
        entered.assertForOverFulfill = false
        let release = DispatchSemaphore(value: 0)
        let (workspace, vault, a, b) = try await fixture(scanner: { vault in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 2)
            return (try vault.scan(), try vault.directories())
        })
        let operation = Task { await workspace.renameAndWait(a, to: "Renamed.md") }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertFalse(workspace.fileOperationInProgress)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.root.appendingPathComponent("Research/Renamed.md").path))
        await workspace.selectAndWait(b)
        workspace.edit("Typing during a folder scan")
        XCTAssertEqual(workspace.selected, b)
        XCTAssertEqual(workspace.text, "Typing during a folder scan")
        release.signal()
        await operation.value
        XCTAssertEqual(workspace.selected, b)
        XCTAssertTrue(workspace.dirty)
    }

    func testNavigationCannotRacePendingFileOperationSave() async throws { try await operationNavigation() }
    func testExtractionEscapesWikiDelimiterFilenames() async throws { try await delimiterExtraction() }
    @MainActor private func delimiterExtraction() async throws {
        let (workspace, vault, a, _) = try await fixture()
        let source = workspace.text, range = (workspace.text as NSString).range(of: "🐼 passage")
        await workspace.extractSelectionAndWait(name: "A|B]", source: source, range: range, file: a)
        let created = vault.root.appendingPathComponent("Research/A|B].md")
        XCTAssertNil(workspace.error)
        XCTAssertEqual(try vault.read(created), "🐼 passage")
        XCTAssertTrue(workspace.text.contains("[A|B\\]](pandanote-note:Research%2FA%7CB%5D%2Emd)"))
        workspace.openWikiLink("Research/A|B].md")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(workspace.selected, created)
    }
    @MainActor private func operationNavigation() async throws {
        let entered = expectation(description: "Save began")
        let release = DispatchSemaphore(value: 0)
        let (workspace, vault, a, b) = try await fixture { root, file, text, expected in
            if text == "Slow save" {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            try Vault(root: root).save(text, to: file, expected: expected)
        }
        workspace.edit("Slow save")
        let operation = Task { await workspace.renameAndWait(a, to: "New.md") }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(workspace.fileOperationInProgress)
        await workspace.selectAndWait(b)
        XCTAssertEqual(workspace.selected, a)
        release.signal()
        await operation.value
        let moved = vault.root.appendingPathComponent("Research/New.md")
        XCTAssertEqual(workspace.selected, moved)
        XCTAssertEqual(try vault.read(moved), "Slow save")
        XCTAssertFalse(workspace.fileOperationInProgress)
    }
}
