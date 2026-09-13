import XCTest
import PandanoteCore
@testable import Pandanote

final class FindReplaceTests: XCTestCase {
    @MainActor private func fixture(writer: (@Sendable (URL, URL, String, String) throws -> Void)? = nil) async throws -> (Workspace, Vault, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let oldAutosave = UserDefaults.standard.object(forKey: "autosave")
        UserDefaults.standard.set(false, forKey: "autosave")
        addTeardownBlock { UserDefaults.standard.set(oldAutosave, forKey: "autosave") }
        let vault = Vault(root: root)
        let a = try vault.create(name: "A", text: "cat Cat scatter\ncat 🐼")
        let b = try vault.create(name: "B", folder: "Research", text: "cat 10\ncat 20")
        let workspace: Workspace
        if let writer { workspace = Workspace(restoreVault: false, writeDocument: writer) }
        else { workspace = Workspace(restoreVault: false) }
        workspace.root = vault.root; workspace.notes = try vault.scan()
        await workspace.selectAndWait(a)
        workspace.openFind(replace: true)
        return (workspace, vault, a, b)
    }
    @MainActor private func eventually(_ condition: @escaping @MainActor () -> Bool) async throws {
        let end = Date().addingTimeInterval(4)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    @MainActor func testLiveUnsavedSearchCaseWholeWordAndSelectionScope() async throws {
        let (workspace, _, _, _) = try await fixture()
        let search = workspace.findReplace
        workspace.edit("🐼 cat CAT scatter\ncat")
        search.query = "cat"
        await search.searchNow()
        XCTAssertEqual(search.totalMatchCount, 4)
        search.wholeWord = true; await search.searchNow()
        XCTAssertEqual(search.totalMatchCount, 3)
        search.caseSensitive = true; await search.searchNow()
        XCTAssertEqual(search.totalMatchCount, 2)
        workspace.selection = (workspace.text as NSString).range(of: "🐼 cat")
        search.scope = .selection; await search.searchNow()
        XCTAssertEqual(search.totalMatchCount, 1)
        XCTAssertEqual(search.resultGroups.first?.matches.first?.range.location, 3)
        workspace.edit(workspace.text + " changed")
        await search.searchNow()
        XCTAssertEqual(search.totalMatchCount, 0)
        XCTAssertNotNil(search.errorMessage)
    }
    @MainActor func testVaultGlobsAndUnsavedActiveBufferAreRespected() async throws {
        let (workspace, _, _, b) = try await fixture()
        workspace.edit("cat cat cat cat")
        let search = workspace.findReplace
        search.scope = .vault; search.query = "cat"; search.wholeWord = true
        await search.searchNow()
        XCTAssertEqual(search.totalMatchCount, 6)
        search.includeGlobs = "Research/**"; await search.searchNow()
        XCTAssertEqual(search.totalMatchCount, 2)
        XCTAssertEqual(search.resultGroups.first?.file, b)
        search.excludeGlobs = "**/B.md"; await search.searchNow()
        XCTAssertEqual(search.totalMatchCount, 0)
    }
    @MainActor func testRegexPreviewCheckedFilesApplyAndUndo() async throws {
        let (workspace, vault, a, b) = try await fixture()
        let search = workspace.findReplace
        search.scope = .vault; search.query = "(cat)"; search.usesRegex = true; search.wholeWord = true
        search.replacement = "$1s"
        await search.searchNow()
        await search.previewReplaceAllAndWait()
        let preview = try XCTUnwrap(search.preview)
        XCTAssertEqual(preview.fileCount, 2)
        search.togglePreviewFile(b.path)
        await search.applyPreviewAndWait()
        XCTAssertNil(search.errorMessage)
        XCTAssertEqual(try vault.read(a), "cats Cats scatter\ncats 🐼")
        XCTAssertEqual(try vault.read(b), "cat 10\ncat 20")
        XCTAssertEqual(workspace.text, try vault.read(a))
        XCTAssertEqual(workspace.pendingReplacement?.label, "Find and replace")
        XCTAssertTrue(search.canUndoReplacement)
        XCTAssertNotNil(search.backupURL)
        await search.undoLastReplacementAndWait()
        XCTAssertEqual(try vault.read(a), "cat Cat scatter\ncat 🐼")
        XCTAssertFalse(search.canUndoReplacement)
    }
    @MainActor func testStaleExternalPreviewStopsEntireBatchWithoutTouchingFirstFile() async throws {
        let (workspace, vault, a, b) = try await fixture()
        let search = workspace.findReplace
        search.scope = .vault; search.query = "cat"; search.wholeWord = true; search.replacement = "dog"
        await search.searchNow(); await search.previewReplaceAllAndWait()
        try "External change".write(to: b, atomically: true, encoding: .utf8)
        await search.applyPreviewAndWait()
        XCTAssertNotNil(search.errorMessage)
        XCTAssertEqual(try vault.read(a), "cat Cat scatter\ncat 🐼")
        XCTAssertEqual(try vault.read(b), "External change")
        XCTAssertFalse(workspace.fileOperationInProgress)
    }
    @MainActor func testSingleReplaceFailureSurvivesSearchRefresh() async throws {
        let (workspace, _, a, _) = try await fixture()
        let search = workspace.findReplace
        search.query = "cat"; search.replacement = "dog"
        await search.searchNow()
        try "External change".write(to: a, atomically: true, encoding: .utf8)
        await search.replaceCurrentAndWait()
        XCTAssertNotNil(search.errorMessage)
        XCTAssertEqual(workspace.text, "cat Cat scatter\ncat 🐼")
    }
    @MainActor func testSelectionReplacementAdjustsCapturedRangeAndLeavesOutsideText() async throws {
        let (workspace, vault, a, _) = try await fixture()
        let search = workspace.findReplace
        workspace.selection = NSRange(location: 0, length: 7)
        search.scope = .selection; search.query = "cat"; search.replacement = "kitten"
        await search.searchNow(); await search.previewReplaceAllAndWait(); await search.applyPreviewAndWait()
        XCTAssertEqual(try vault.read(a), "kitten kitten scatter\ncat 🐼")
        search.query = "kitten"; await search.searchNow()
        XCTAssertNil(search.errorMessage)
        XCTAssertEqual(search.totalMatchCount, 2)
        await search.undoLastReplacementAndWait()
        XCTAssertEqual(try vault.read(a), "cat Cat scatter\ncat 🐼")
    }
    @MainActor func testQueryAndSelectionChangesInvalidatePreview() async throws {
        let (workspace, _, _, _) = try await fixture()
        let search = workspace.findReplace
        search.query = "cat"; search.replacement = "dog"
        await search.searchNow(); await search.previewReplaceAllAndWait()
        XCTAssertNotNil(search.preview)
        workspace.selection = NSRange(location: 0, length: 3)
        search.scope = .selection
        XCTAssertNil(search.preview)
        await search.searchNow(); await search.previewReplaceAllAndWait()
        XCTAssertNotNil(search.preview)
        search.replacement = "kitten"
        XCTAssertNil(search.preview)
        search.query = "["; search.usesRegex = true
        await search.searchNow()
        XCTAssertNotNil(search.errorMessage)
        XCTAssertEqual(search.totalMatchCount, 0)
    }
    @MainActor func testUndoRecapturesSelectionWhenEarlierChangesShiftIt() async throws {
        let (workspace, vault, a, _) = try await fixture()
        let search = workspace.findReplace
        search.query = "cat"; search.wholeWord = true; search.replacement = "longer kitten"
        await search.searchNow(); await search.previewReplaceAllAndWait(); await search.applyPreviewAndWait()
        workspace.selection = (workspace.text as NSString).range(of: "scatter")
        search.scope = .selection; search.query = "scatter"
        await search.searchNow()
        XCTAssertEqual(search.totalMatchCount, 1)
        await search.undoLastReplacementAndWait()
        XCTAssertEqual(try vault.read(a), "cat Cat scatter\ncat 🐼")
        XCTAssertEqual(search.totalMatchCount, 0)
        XCTAssertTrue(search.errorMessage?.contains("Use Current Selection") == true)
        workspace.selection = (workspace.text as NSString).range(of: "scatter")
        search.captureSelection(); await search.searchNow()
        XCTAssertEqual(search.totalMatchCount, 1)
        XCTAssertNil(search.errorMessage)
    }
    @MainActor func testTruncatedSearchCannotPreviewReplaceAll() async throws {
        let (workspace, _, _, _) = try await fixture()
        workspace.edit(String(repeating: "a ", count: 10_001))
        let search = workspace.findReplace
        search.query = "a"; search.replacement = "b"
        await search.searchNow()
        XCTAssertTrue(search.isTruncated)
        XCTAssertEqual(search.totalMatchCount, 10_000)
        await search.previewReplaceAllAndWait()
        XCTAssertNil(search.preview)
    }
    @MainActor func testCorrectingOversizedReplacementAllowsAnotherPreview() async throws {
        let (workspace, _, _, _) = try await fixture()
        workspace.edit("cat")
        let search = workspace.findReplace
        search.query = "cat"; search.replacement = String(repeating: "x", count: 8_000_001)
        await search.searchNow(); await search.previewReplaceAllAndWait()
        XCTAssertNotNil(search.errorMessage)
        XCTAssertNil(search.preview)
        search.replacement = "kitten"
        XCTAssertNil(search.errorMessage)
        await search.previewReplaceAllAndWait()
        XCTAssertEqual(search.preview?.files.first?.after, "kitten")
    }
    @MainActor func testResultNavigationUsesExactUTF16RangeAndWraps() async throws {
        let (workspace, _, _, b) = try await fixture()
        let search = workspace.findReplace
        search.scope = .vault; search.query = "cat"; search.wholeWord = true
        await search.searchNow()
        let group = try XCTUnwrap(search.resultGroups.first(where: { $0.file == b }))
        let match = group.matches.last!
        search.selectMatch(id: match.id)
        try await eventually { workspace.selected == b && workspace.selection == match.range }
        XCTAssertEqual(search.navigation?.source, "cat 10\ncat 20")
        search.nextMatch()
        try await eventually { search.activeMatchID == search.resultGroups.first?.matches.first?.id }
        XCTAssertEqual(workspace.selection, NSRange(location: 0, length: 3))
        search.close()
        XCTAssertTrue(search.currentMatches(for: b, source: group.source).isEmpty)
    }
    @MainActor func testClosingFindCancelsPendingNavigation() async throws {
        let entered = expectation(description: "Navigation save began")
        let release = DispatchSemaphore(value: 0)
        let (workspace, _, a, b) = try await fixture { root, file, text, expected in
            if text == "cat unsaved" { entered.fulfill(); _ = release.wait(timeout: .now() + 3) }
            try Vault(root: root).save(text, to: file, expected: expected)
        }
        workspace.edit("cat unsaved")
        let search = workspace.findReplace
        search.scope = .vault; search.query = "cat"
        await search.searchNow()
        let match = try XCTUnwrap(search.resultGroups.first(where: { $0.file == b })?.matches.first)
        search.selectMatch(id: match.id)
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(workspace.selected, a)
        search.close(); release.signal()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(search.navigation)
        XCTAssertFalse(workspace.showFindReplace)
        XCTAssertNotEqual(workspace.selection, match.range)
    }
}
