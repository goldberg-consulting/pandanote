import XCTest
import PDFKit
import PandanoteCore
@testable import Pandanote

final class BackgroundPublishingTests: XCTestCase {
    @MainActor func fixture(writer: (@Sendable (URL, URL, String, String) throws -> Void)? = nil) async throws -> (Workspace, URL, URL) {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/node") || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/node") else { throw XCTSkip("Node is needed for the test publishing helper") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("A.md")
        try "# Original\n\nFirst draft.".write(to: file, atomically: true, encoding: .utf8)
        try "# Other note".write(to: root.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)
        var box = CGRect(x: 0, y: 0, width: 400, height: 600)
        let context = CGContext(root.appendingPathComponent("A.pdf") as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let script = root.appendingPathComponent("helper.cjs")
        try #"""
        const fs = require('node:fs');
        let input = ''; process.stdin.on('data', data => input += data);
        process.stdin.on('end', () => {
          const r = JSON.parse(input);
          if (r.action !== 'compile') { console.log(JSON.stringify({success:true,html:'<p>Draft</p>'})); return; }
          fs.writeFileSync(r.root + '/captured.txt',r.text);
          setTimeout(() => {
            const failure = r.text.includes('FAIL_BUILD');
            console.log(JSON.stringify({success:!failure,message:failure?'Test build failed':'Built',log:'x'.repeat(100000) + '\nFinal diagnostic',pdfPath:failure?undefined:r.root+'/A.pdf'}));
          }, 1200);
        });
        """#.write(to: script, atomically: true, encoding: .utf8)
        let previous = UserDefaults.standard.object(forKey: "autosave")
        UserDefaults.standard.set(false, forKey: "autosave")
        addTeardownBlock { UserDefaults.standard.set(previous, forKey: "autosave") }
        let engine = EngineClient(script: script)
        let workspace: Workspace
        if let writer { workspace = Workspace(restoreVault: false, engine: engine, writeDocument: writer) }
        else { workspace = Workspace(restoreVault: false, engine: engine) }
        await workspace.openVaultAndWait(root)
        await workspace.selectAndWait(file)
        // The initial background scan can win selection of the same file.
        try await eventually { workspace.selected == file }
        return (workspace, root, file)
    }
    @MainActor func eventually(timeout: TimeInterval = 8, _ condition: @escaping @MainActor () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Background operation did not finish")
    }
    func testSlowBuildAllowsEditingAndNavigationWithoutReplacingNewerText() async throws { try await testSlowBuildAllowsEditingAndNavigationWithoutReplacingNewerTextOnMain() }
    @MainActor private func testSlowBuildAllowsEditingAndNavigationWithoutReplacingNewerTextOnMain() async throws {
        let (workspace, root, file) = try await fixture()
        workspace.mode = .source
        let snapshot = workspace.text
        workspace.perform("compile")
        XCTAssertTrue(workspace.busy)
        try await eventually { FileManager.default.fileExists(atPath: root.appendingPathComponent("captured.txt").path) }
        // These actions must execute before the helper has finished, on the UI actor.
        XCTAssertTrue(workspace.busy)
        workspace.edit(snapshot + "\nNew writing during compilation.")
        let newer = workspace.text
        await workspace.selectAndWait(root.appendingPathComponent("B.md"))
        XCTAssertTrue(workspace.busy)
        XCTAssertEqual(workspace.selected?.lastPathComponent, "B.md")
        try await eventually { !workspace.busy }
        XCTAssertEqual(workspace.text, "# Other note")
        XCTAssertEqual(workspace.mode, .source)
        XCTAssertFalse(workspace.showPDF)
        XCTAssertNil(workspace.pdfDocument)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), newer)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("captured.txt"), encoding: .utf8), snapshot)
        XCTAssertTrue(workspace.hasBuiltPDF)
        XCTAssertLessThan(workspace.log.count, 33_000)
        XCTAssertTrue(workspace.log.hasSuffix("Final diagnostic"))
        workspace.revealBuiltPDF()
        try await eventually { workspace.showPDF }
        XCTAssertEqual(workspace.selected, file)
        XCTAssertEqual(workspace.text, newer)
        XCTAssertEqual(workspace.pdfSource, snapshot)
        XCTAssertEqual(workspace.pdfDocument?.pageCount, 1)
    }
    func testFailedBuildKeepsLastGoodPDFAndReleasesBusyState() async throws { try await testFailedBuildKeepsLastGoodPDFAndReleasesBusyStateOnMain() }
    @MainActor private func testFailedBuildKeepsLastGoodPDFAndReleasesBusyStateOnMain() async throws {
        let (workspace, _, _) = try await fixture()
        workspace.perform("compile")
        try await eventually { !workspace.busy }
        workspace.revealBuiltPDF()
        try await eventually { workspace.pdfDocument != nil }
        let goodPDF = workspace.pdfDocument, source = workspace.pdfSource
        workspace.edit(workspace.text + "\nFAIL_BUILD")
        workspace.perform("compile")
        try await eventually { !workspace.busy }
        XCTAssertTrue(workspace.pdfDocument === goodPDF)
        XCTAssertEqual(workspace.pdfSource, source)
        XCTAssertEqual(workspace.buildNotice, "Test build failed")
        XCTAssertNil(workspace.buildActivity)
        XCTAssertTrue(workspace.showLog)
    }
    func testConcurrentSavesPreserveTypingDuringSlowProviderWrite() async throws { try await testConcurrentSavesPreserveTypingDuringSlowProviderWriteOnMain() }
    @MainActor private func testConcurrentSavesPreserveTypingDuringSlowProviderWriteOnMain() async throws {
        let entered = expectation(description: "Writer started off main")
        let release = DispatchSemaphore(value: 0)
        let (workspace, _, file) = try await fixture { root, file, text, expected in
            XCTAssertFalse(Thread.isMainThread)
            if text == "First queued save" {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            try Vault(root: root).save(text, to: file, expected: expected)
        }
        workspace.edit("First queued save")
        let first = Task { await workspace.save() }
        await fulfillment(of: [entered], timeout: 3)
        workspace.edit("Newer writing while disk is busy 🐼")
        let second = Task { await workspace.save() }
        release.signal()
        let firstSaved = await first.value, secondSaved = await second.value
        XCTAssertTrue(firstSaved); XCTAssertTrue(secondSaved)
        XCTAssertFalse(workspace.dirty)
        XCTAssertFalse(workspace.conflict)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Newer writing while disk is busy 🐼")
        XCTAssertEqual(workspace.text, "Newer writing while disk is busy 🐼")
    }
    func testExternalEditRefusesSaveAndStopsBuildWithoutLosingEditorText() async throws { try await testExternalEditRefusesSaveAndStopsBuildWithoutLosingEditorTextOnMain() }
    @MainActor private func testExternalEditRefusesSaveAndStopsBuildWithoutLosingEditorTextOnMain() async throws {
        let (workspace, _, file) = try await fixture()
        workspace.edit("My unsaved writing")
        try "External revision".write(to: file, atomically: true, encoding: .utf8)
        workspace.perform("compile")
        try await eventually { !workspace.busy }
        XCTAssertTrue(workspace.conflict)
        XCTAssertTrue(workspace.dirty)
        XCTAssertEqual(workspace.text, "My unsaved writing")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "External revision")
        XCTAssertEqual(workspace.buildNotice, "Save needs attention")
        XCTAssertFalse(workspace.hasBuiltPDF)
    }
}
