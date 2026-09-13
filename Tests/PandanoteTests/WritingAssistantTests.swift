import Foundation
import XCTest
import PandanoteCore
@testable import Pandanote

final class WritingAssistantTests: XCTestCase {
    @MainActor func test_singleModel_when_noteExcluded_expectsSelectedTextAndEnabledGuidance() async throws {
        let configuration = WritingTeamConfiguration(
            useTeam: false, agents: [],
            skills: [WritingGuidance(name: "Voice", instructions: "Keep the author's quiet voice."), WritingGuidance(name: "Inactive skill", instructions: "SKILL_NOT_SELECTED", enabled: false)],
            rules: [WritingGuidance(name: "Evidence", instructions: "Preserve every citation."), WritingGuidance(name: "Inactive rule", instructions: "RULE_NOT_SELECTED", enabled: false)]
        )
        let fixture = try makeFixture(configuration: configuration)
        var calls: [ModelCall] = []
        let assistant = makeAssistant(fixture) { configuration, system, history, prompt, revision in
            calls.append(ModelCall(configuration: configuration, system: system, history: history, prompt: prompt, revision: revision))
            return "Consider making the claim more precise."
        }
        assistant.includeNote = false
        assistant.ask(workspace: fixture.workspace, instruction: "Help clarify my selection")
        try await waitUntil { !assistant.busy }

        XCTAssertNil(assistant.error)
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.configuration.provider, .openAI)
        XCTAssertEqual(call.configuration.model, "gpt-writing-test")
        XCTAssertTrue(call.system.contains("Keep the author's quiet voice."))
        XCTAssertTrue(call.system.contains("Preserve every citation."))
        XCTAssertFalse(call.system.contains("SKILL_NOT_SELECTED"))
        XCTAssertFalse(call.system.contains("RULE_NOT_SELECTED"))
        XCTAssertTrue(call.prompt.contains(fixture.selectedText))
        XCTAssertFalse(call.prompt.contains("Private surrounding sentence."))
        XCTAssertTrue(call.history.isEmpty)
        XCTAssertFalse(call.revision)
        XCTAssertEqual(assistant.messages.last?.text, "Consider making the claim more precise.")
        XCTAssertEqual(assistant.messages.last?.complete, true)
    }

    @MainActor func test_mentions_when_agentsExplicitlyAttached_expectsConfiguredOrderAndSharedContributions() async throws {
        let first = WritingAgent(name: "Argument editor", instructions: "Check the argument.", provider: .anthropic, model: "claude-argument-test", enabled: false)
        let second = WritingAgent(name: "Style editor", instructions: "Polish the voice.", provider: .openAI, model: "gpt-style-test", enabled: false)
        let ignored = WritingAgent(name: "Unmentioned agent", instructions: "UNMENTIONED_AGENT", enabled: true)
        let skill = WritingGuidance(name: "Mentioned skill", instructions: "Follow this requested voice.", enabled: false)
        let rule = WritingGuidance(name: "Mentioned rule", instructions: "Keep the provided evidence intact.", enabled: false)
        let configuration = WritingTeamConfiguration(
            useTeam: false,
            orchestrator: WritingAgent(name: "Conductor", instructions: "Reconcile the editorial feedback.", provider: .anthropic, model: "claude-conductor-test"),
            agents: [first, second, ignored], skills: [skill], rules: [rule]
        )
        let fixture = try makeFixture(configuration: configuration)
        var calls: [ModelCall] = []
        let answers = ["PLAN_CONTRIBUTION", "ARGUMENT_CONTRIBUTION", "STYLE_CONTRIBUTION", "FINAL_ANSWER"]
        let assistant = makeAssistant(fixture) { configuration, system, history, prompt, revision in
            calls.append(ModelCall(configuration: configuration, system: system, history: history, prompt: prompt, revision: revision))
            guard answers.indices.contains(calls.count - 1) else { throw TestFailure.unexpectedModelCall }
            return answers[calls.count - 1]
        }
        assistant.includeNote = false
        let candidates = assistant.mentionCandidates(workspace: fixture.workspace)
        // Attach in the reverse order to verify that the configured sequence wins.
        for identifier in [second.id.uuidString, first.id.uuidString, "Research.md", skill.id.uuidString, rule.id.uuidString] {
            let item = try XCTUnwrap(candidates.first { $0.identifier == identifier })
            assistant.prompt = "Assess this @partial"
            assistant.attach(item)
            XCTAssertEqual(assistant.prompt, "Assess this ")
        }
        assistant.ask(workspace: fixture.workspace, instruction: "Assess this argument")
        try await waitUntil { !assistant.busy }

        XCTAssertNil(assistant.error)
        XCTAssertEqual(calls.map(\.configuration.provider), [.anthropic, .anthropic, .openAI, .anthropic])
        XCTAssertEqual(calls.map(\.configuration.model), ["claude-conductor-test", "claude-argument-test", "gpt-style-test", "claude-conductor-test"])
        let planning = try XCTUnwrap(calls.first)
        let argument = try XCTUnwrap(calls.dropFirst().first)
        let style = try XCTUnwrap(calls.dropFirst(2).first)
        let final = try XCTUnwrap(calls.dropFirst(3).first)
        XCTAssertTrue(planning.prompt.contains("Quoted source body from the attached research note."))
        XCTAssertFalse(planning.prompt.contains("UNMENTIONED_AGENT"))
        XCTAssertTrue(argument.prompt.contains("PLAN_CONTRIBUTION"))
        XCTAssertTrue(style.prompt.contains("PLAN_CONTRIBUTION"))
        XCTAssertTrue(style.prompt.contains("ARGUMENT_CONTRIBUTION"))
        XCTAssertTrue(final.prompt.contains("ARGUMENT_CONTRIBUTION"))
        XCTAssertTrue(final.prompt.contains("STYLE_CONTRIBUTION"))
        for call in calls {
            XCTAssertTrue(call.system.contains("Follow this requested voice."))
            XCTAssertTrue(call.system.contains("Keep the provided evidence intact."))
            XCTAssertFalse(call.revision)
        }
        XCTAssertEqual(assistant.messages.last?.text, "FINAL_ANSWER")
        XCTAssertEqual(assistant.messages.last?.complete, true)
    }

    @MainActor func test_revision_when_editorSelectionCollapses_expectsCapturedRangeInSavedReview() async throws {
        let fixture = try makeFixture()
        var calls: [ModelCall] = []
        let assistant = makeAssistant(fixture) { configuration, system, history, prompt, revision in
            calls.append(ModelCall(configuration: configuration, system: system, history: history, prompt: prompt, revision: revision))
            return "A more precise sentence."
        }
        assistant.includeNote = false
        let originalRange = fixture.workspace.selection
        let originalDocument = fixture.workspace.text
        assistant.captureSelection(workspace: fixture.workspace)
        fixture.workspace.selection = NSRange(location: 0, length: 0)
        assistant.ask(workspace: fixture.workspace, instruction: "Improve this passage", revision: true)
        try await waitUntil { !assistant.busy }

        XCTAssertNil(assistant.error)
        XCTAssertEqual(assistant.passage?.range, originalRange)
        XCTAssertEqual(assistant.passage?.text, fixture.selectedText)
        let call = try XCTUnwrap(calls.first)
        XCTAssertTrue(call.revision)
        XCTAssertTrue(call.prompt.contains(fixture.selectedText))
        XCTAssertFalse(call.prompt.contains("Private surrounding sentence."))
        let reviews = try ChangeArchive(vault: Vault(root: fixture.root)).list()
        XCTAssertEqual(reviews.count, 1)
        let review = try XCTUnwrap(reviews.first)
        XCTAssertEqual(review.base, originalDocument)
        XCTAssertEqual(review.location, originalRange.location)
        XCTAssertEqual(review.length, originalRange.length)
        XCTAssertEqual(review.original, fixture.selectedText)
        XCTAssertEqual(review.replacement, "A more precise sentence.")
        XCTAssertEqual(review.decision, "pending")
        XCTAssertEqual(review.relativePath, "Draft.md")
        XCTAssertEqual(try review.applying(to: originalDocument, relativePath: "Draft.md"), originalDocument.replacingOccurrences(of: fixture.selectedText, with: "A more precise sentence."))
        XCTAssertEqual(fixture.workspace.text, originalDocument)
        XCTAssertEqual(try String(contentsOf: fixture.file, encoding: .utf8), originalDocument)
        XCTAssertEqual(fixture.workspace.reviewProposal?.id, review.id)
        XCTAssertEqual(assistant.messages.last?.reviewID, review.id)
        XCTAssertEqual(assistant.messages.last?.complete, true)
    }

    @MainActor func test_revision_when_capturedDocumentChanges_expectsRejectionBeforeModelCall() async throws {
        let fixture = try makeFixture()
        var callCount = 0
        let assistant = makeAssistant(fixture) { _, _, _, _, _ in
            callCount += 1
            return "This must not be proposed."
        }
        assistant.captureSelection(workspace: fixture.workspace)
        fixture.workspace.text += "\nNew writing after highlighting."
        assistant.ask(workspace: fixture.workspace, instruction: "Revise this passage", revision: true)

        XCTAssertFalse(assistant.busy)
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(assistant.error, WritingContextError.staleSelection.localizedDescription)
        XCTAssertTrue(assistant.messages.isEmpty)
        XCTAssertNil(fixture.workspace.reviewProposal)
        XCTAssertTrue(try ChangeArchive(vault: Vault(root: fixture.root)).list().isEmpty)
    }

    @MainActor func test_revision_when_cancelled_expectsNoReviewOrCompletedAnswer() async throws {
        let fixture = try makeFixture()
        var enteredModel = false
        let assistant = makeAssistant(fixture) { _, _, _, _, _ in
            enteredModel = true
            try await Task.sleep(for: .seconds(5))
            return "An answer that should not be accepted after cancellation."
        }
        assistant.ask(workspace: fixture.workspace, instruction: "Rewrite the passage", revision: true)
        try await waitUntil { enteredModel }
        assistant.stop()
        try await waitUntil { !assistant.busy }

        XCTAssertNotNil(assistant.error)
        XCTAssertNil(assistant.stageStatus)
        XCTAssertEqual(assistant.messages.last?.complete, false)
        XCTAssertNil(assistant.messages.last?.reviewID)
        XCTAssertNil(fixture.workspace.reviewProposal)
        XCTAssertTrue(try ChangeArchive(vault: Vault(root: fixture.root)).list().isEmpty)
        XCTAssertEqual(fixture.workspace.text, try String(contentsOf: fixture.file, encoding: .utf8))
    }

    @MainActor func test_teamRevision_when_agentFails_expectsNoFinalStageOrSavedReview() async throws {
        let configuration = WritingTeamConfiguration(useTeam: true, agents: [WritingAgent(name: "First editor"), WritingAgent(name: "Second editor")])
        let fixture = try makeFixture(configuration: configuration)
        var callCount = 0
        let assistant = makeAssistant(fixture) { _, _, _, _, _ in
            callCount += 1
            if callCount == 2 { throw AIProviderError.service("The first editor is unavailable.") }
            return "The orchestrator's editorial plan."
        }
        assistant.ask(workspace: fixture.workspace, instruction: "Rewrite the passage", revision: true)
        try await waitUntil { !assistant.busy }

        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(assistant.error, "The first editor is unavailable.")
        XCTAssertNil(assistant.stageStatus)
        XCTAssertEqual(assistant.messages.last?.complete, false)
        XCTAssertNil(assistant.messages.last?.reviewID)
        XCTAssertNil(fixture.workspace.reviewProposal)
        XCTAssertTrue(try ChangeArchive(vault: Vault(root: fixture.root)).list().isEmpty)
    }

    @MainActor func test_teamConfiguration_when_saved_expectsModelsOrderAndGuidanceAfterReload() throws {
        let fixture = try makeFixture()
        let configuration = WritingTeamConfiguration(
            useTeam: true,
            orchestrator: WritingAgent(name: "Lead", instructions: "Keep my voice.", provider: .anthropic, model: "claude-lead"),
            agents: [WritingAgent(name: "Structure", provider: .openAI, model: "gpt-editor"), WritingAgent(name: "Style", enabled: false)],
            skills: [WritingGuidance(name: "My style", instructions: "Favor short sentences.")],
            rules: [WritingGuidance(name: "My rule", instructions: "Preserve quotations.")]
        )
        fixture.store.configuration = configuration
        XCTAssertEqual(WritingTeamStore(defaults: fixture.defaults).configuration, configuration)
    }

    private struct ModelCall {
        let configuration: AIModelConfiguration
        let system: String
        let history: [AIChatTurn]
        let prompt: String
        let revision: Bool
    }

    private struct Fixture {
        let workspace: Workspace
        let defaults: UserDefaults
        let store: WritingTeamStore
        let root: URL
        let file: URL
        let selectedText: String
    }

    @MainActor private func makeFixture(configuration: WritingTeamConfiguration = WritingTeamConfiguration(useTeam: false, agents: [])) throws -> Fixture {
        let suite = "Pandanote.WritingAssistantTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AIProvider.openAI.rawValue, forKey: "aiProvider")
        defaults.set("gpt-writing-test", forKey: "openAIModel")
        defaults.set("claude-writing-test", forKey: "anthropicModel")
        let store = WritingTeamStore(defaults: defaults)
        store.configuration = configuration
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pandanote-WritingTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Draft.md")
        let selectedText = "The selected sentence."
        let text = "Preface 🐼\n\n\(selectedText)\n\nPrivate surrounding sentence."
        try text.write(to: file, atomically: true, encoding: .utf8)
        let research = root.appendingPathComponent("Research.md")
        let researchText = "Quoted source body from the attached research note."
        try researchText.write(to: research, atomically: true, encoding: .utf8)
        let workspace = Workspace(restoreVault: false)
        workspace.root = root
        workspace.selected = file
        workspace.text = text
        workspace.selection = (text as NSString).range(of: selectedText)
        workspace.notes = [NoteFile(url: file, relativePath: "Draft.md", modified: Date(), text: text), NoteFile(url: research, relativePath: "Research.md", modified: Date(), text: researchText)]
        return Fixture(workspace: workspace, defaults: defaults, store: store, root: root, file: file, selectedText: selectedText)
    }

    @MainActor private func makeAssistant(_ fixture: Fixture, responder: @escaping WritingAssistant.ModelResponder) -> WritingAssistant {
        WritingAssistant(defaults: fixture.defaults, teamStore: fixture.store, apiKeyReader: { _ in "test-key-never-sent" }, responder: responder)
    }

    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard condition() else {
            XCTFail("The writing operation did not reach the expected state within three seconds.")
            throw TestFailure.timedOut
        }
    }

    private enum TestFailure: Error { case timedOut, unexpectedModelCall }
}
