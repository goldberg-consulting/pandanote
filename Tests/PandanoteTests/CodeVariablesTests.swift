import XCTest
import PandanoteCore
@testable import Pandanote

final class CodeVariablesTests: XCTestCase {
    func testRunLogShowsPrintedOutputAndErrorsWithoutInternalMetadata() throws {
        let data = try JSONSerialization.data(withJSONObject: ["success": false, "message": "Two blocks processed", "results": [
            ["block": ["id": "arithmetic", "lang": "python"], "exitCode": 0, "stdout": "0.13043478260869565\n", "fingerprint": "INTERNAL_HASH"],
            ["block": ["id": "next", "lang": "python"], "exitCode": 1, "stderr": "NameError: missing_value", "artifacts": ["metadata": "INTERNAL_PATH"]]
        ]])
        let result = try PublicationResult(data: data)
        XCTAssertTrue(result.log.contains("arithmetic · Python · complete"))
        XCTAssertTrue(result.log.contains("0.13043478260869565"))
        XCTAssertTrue(result.log.contains("next · Python · failed"))
        XCTAssertTrue(result.log.contains("NameError: missing_value"))
        XCTAssertFalse(result.log.contains("INTERNAL_"))
    }
    @MainActor private func fixture() async throws -> (Workspace, Vault, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let old = UserDefaults.standard.object(forKey: "autosave")
        UserDefaults.standard.set(false, forKey: "autosave")
        addTeardownBlock { UserDefaults.standard.set(old, forKey: "autosave") }
        let vault = Vault(root: root)
        let file = try vault.create(name: "Arithmetic", text: "# Values\n\n```{python id=\"analysis\"}\na = 3.0\n```")
        _ = try vault.create(name: "Other", text: "# Other note")
        let script = root.appendingPathComponent("test-engine.cjs")
        try #"""
        const fs = require('node:fs');
        let input = ''; process.stdin.on('data', c => input += c);
        process.stdin.on('end', () => {
          const r = JSON.parse(input);
          if (!['run','preview'].includes(r.action)) { console.log('{"success":true}'); return; }
          const prepared = r.action === 'run' ? r.text.replace('```python', '```{python id="analysis"}') : r.text;
          const current = prepared.includes('id="analysis"');
          const variableBlocks = prepared.includes('a =') ? [{ id:'analysis',index:0,startLine:3,language:'python',
            runID:'test-run',fingerprint:'test-fingerprint',status:current?'current':'not-run',variables:current?[
              {id:'pv_123',name:'a',type:'float',preview:'3.0',reusable:true,reference:'{{pv_123}}',pythonReference:"pandanote['analysis']['a']"}]:[] }] : [];
          if (r.action === 'run') fs.writeFileSync(r.root + '/run-started', 'yes');
          setTimeout(() => console.log(JSON.stringify({success:!r.text.includes('FAIL_CODE'),message:r.text.includes('FAIL_CODE')?'One block failed':'Run complete',
            html:'<p>Values</p>',text:r.action==='run'?prepared:undefined,variableBlocks})), r.text.includes('DELAY') ? 900 : 0);
        });
        """#.write(to: script, atomically: true, encoding: .utf8)
        let workspace = Workspace(restoreVault: false, engine: EngineClient(script: script))
        workspace.root = vault.root; workspace.notes = try vault.scan()
        await workspace.selectAndWait(file)
        return (workspace, vault, file)
    }
    @MainActor private func eventually(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(15)) }
        XCTAssertTrue(condition())
    }
    @MainActor func testInspectAndInsertOnlyCurrentDocumentValues() async throws {
        let (workspace, _, _) = try await fixture()
        try await eventually { workspace.variablesMatchDocument && !workspace.variableBlocks.isEmpty }
        let block = try XCTUnwrap(workspace.variableBlocks.first)
        let variable = try XCTUnwrap(block.variables.first)
        XCTAssertEqual(variable.preview, "3.0")
        workspace.insertVariable(variable, from: block)
        XCTAssertEqual(workspace.editorInsertion, "{{pv_123}}")
        workspace.editorInsertion = nil
        workspace.edit(workspace.text + "\nNew writing")
        XCTAssertFalse(workspace.variablesMatchDocument)
        workspace.insertVariable(variable, from: block)
        XCTAssertNil(workspace.editorInsertion)
        workspace.showVariables()
        XCTAssertEqual(workspace.inspector, .variables)
        XCTAssertTrue(workspace.showInspector)
    }
    @MainActor func testCodeBlockNavigationUsesUTF16LineOffsets() async throws {
        let (workspace, _, _) = try await fixture()
        workspace.edit(workspace.text.replacingOccurrences(of: "# Values", with: "# 🐼 Values"))
        try await eventually { workspace.variablesMatchDocument }
        let block = try XCTUnwrap(workspace.variableBlocks.first)
        workspace.mode = .reading
        workspace.jumpToCodeBlock(block)
        XCTAssertEqual(workspace.jump, ("# 🐼 Values\n\n" as NSString).length)
        XCTAssertEqual(workspace.mode, .source)
    }
    @MainActor func testSwitchingNotesDiscardsPreviousVariableResponse() async throws {
        let (workspace, vault, _) = try await fixture()
        workspace.edit(workspace.text + "\nDELAY")
        try await Task.sleep(for: .milliseconds(600))
        await workspace.selectAndWait(vault.root.appendingPathComponent("Other.md"))
        XCTAssertTrue(workspace.variableBlocks.isEmpty)
        try await eventually { workspace.variablesMatchDocument }
        XCTAssertTrue(workspace.variableBlocks.isEmpty)
        XCTAssertEqual(workspace.text, "# Other note")
    }
    @MainActor func testPartialRunFailureStillSavesBlockIdentityAndDisplaysSuccessfulValues() async throws {
        let (workspace, vault, file) = try await fixture()
        workspace.edit("# Values\n\n```python\na = 3.0\n```\n\nFAIL_CODE")
        workspace.perform("run", confirmCodeExecution: false)
        try await eventually { !workspace.busy }
        XCTAssertTrue(try vault.read(file).contains("id=\"analysis\""))
        XCTAssertEqual(workspace.buildNotice, "One block failed")
        XCTAssertEqual(workspace.inspector, .variables)
        try await eventually { workspace.variablesMatchDocument }
        XCTAssertEqual(workspace.variableBlocks.first?.variables.first?.preview, "3.0")
    }
    @MainActor func testTypingDuringRunDoesNotReplaceNewerTextWithBlockIDs() async throws {
        let (workspace, vault, file) = try await fixture()
        workspace.edit("# Values\n\n```python\na = 3.0\n```\n\nDELAY")
        workspace.perform("run", confirmCodeExecution: false)
        try await eventually { FileManager.default.fileExists(atPath: vault.root.appendingPathComponent("run-started").path) }
        workspace.edit(workspace.text + "\nKeep my new paragraph")
        let newer = workspace.text
        try await eventually { !workspace.busy }
        XCTAssertEqual(workspace.text, newer)
        XCTAssertFalse(workspace.text.contains("id=\"analysis\""))
        _ = await workspace.save()
        XCTAssertEqual(try vault.read(file), newer)
    }
}
