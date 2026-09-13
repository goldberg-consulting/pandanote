import XCTest
@testable import PandanoteCore

final class WritingTeamTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/writing-vault")
    private var file: URL { root.appendingPathComponent("Draft.md") }

    func testPassageSnapshotPreservesUnicodeAndOriginalText() throws {
        let original = "🐼 Introduction\nA naïve writer uses café.\nEnd."
        let selected = "A naïve writer uses café."
        let range = (original as NSString).range(of: selected)
        let context = try AIPassageContext(root: root, file: file, relativePath: "Draft.md", base: original, range: range)

        XCTAssertEqual(context.text, selected)
        XCTAssertEqual(context.base, original)
        XCTAssertEqual(context.range, range)
        XCTAssertNoThrow(try context.validate(root: root, file: file, text: original))
    }

    func testPassageRejectsEmptyOutOfBoundsAndSplitSurrogateSelections() {
        let text = "A🐼B"
        let invalidRanges = [
            NSRange(location: 0, length: 0),
            NSRange(location: NSNotFound, length: 1),
            NSRange(location: -1, length: 1),
            NSRange(location: 1, length: -1),
            NSRange(location: 1, length: Int.max),
            NSRange(location: 5, length: 1),
            NSRange(location: 3, length: 2),
            NSRange(location: 1, length: 1),
            NSRange(location: 2, length: 1)
        ]
        for range in invalidRanges {
            XCTAssertThrowsError(try AIPassageContext(root: root, file: file, relativePath: "Draft.md", base: text, range: range), "Unexpectedly accepted \(range)") { error in
                guard case WritingContextError.invalidSelection = error else { return XCTFail("Expected invalid selection, got \(error)") }
            }
        }
        XCTAssertNoThrow(try AIPassageContext(root: root, file: file, relativePath: "Draft.md", base: text, range: NSRange(location: 1, length: 2)))
    }

    func testPassageSelectionAcceptsOnlyCompleteUnicodeScalarsAtEachBoundary() throws {
        let text = "A🐼B"
        let validRanges = Set([NSRange(location: 0, length: 1), NSRange(location: 0, length: 3), NSRange(location: 0, length: 4), NSRange(location: 1, length: 2), NSRange(location: 1, length: 3), NSRange(location: 3, length: 1)])
        for start in 0...4 {
            for end in start...4 {
                let range = NSRange(location: start, length: end - start)
                XCTAssertEqual(AIPassageContext.isValid(range: range, in: text), validRanges.contains(range), "Incorrect validity for \(range)")
                if validRanges.contains(range) {
                    let context = try AIPassageContext(root: root, file: file, relativePath: "Draft.md", base: text, range: range)
                    XCTAssertFalse(context.text.contains("\u{FFFD}"))
                    XCTAssertEqual(context.text, (text as NSString).substring(with: range))
                }
            }
        }
    }

    func testPassageCannotBeRevisedAfterDocumentOrVaultChanges() throws {
        let context = try AIPassageContext(root: root, file: file, relativePath: "Draft.md", base: "Original text", range: NSRange(location: 0, length: 8))
        let scenarios: [(URL?, URL?, String)] = [
            (root, file, "Original text with a later edit"),
            (root, root.appendingPathComponent("Other.md"), context.base),
            (URL(fileURLWithPath: "/tmp/another-vault"), file, context.base),
            (nil, file, context.base),
            (root, nil, context.base)
        ]
        for (currentRoot, currentFile, currentText) in scenarios {
            XCTAssertThrowsError(try context.validate(root: currentRoot, file: currentFile, text: currentText)) { error in
                guard case WritingContextError.staleSelection = error else { return XCTFail("Expected stale selection, got \(error)") }
            }
        }
        XCTAssertEqual(context.text, "Original")
    }

    func testMentionQueryExcludesEmailAndSupportsEmptyAndMultiwordQueries() throws {
        XCTAssertNil(AIMentionQuery.trailing(in: "Contact eli@example.com"))
        XCTAssertNil(AIMentionQuery.trailing(in: "word@editor"))
        XCTAssertNil(AIMentionQuery.trailing(in: "@@editor"))
        XCTAssertEqual(AIMentionQuery.trailing(in: "@")?.query, "")
        XCTAssertEqual(AIMentionQuery.trailing(in: "Review with @Line editor")?.query, "Line editor")
        XCTAssertEqual(AIMentionQuery.trailing(in: "Review with\t@Line")?.query, "Line")
    }

    func testMentionRemovalUsesUTF16RangeWithoutRemovingSurroundingText() throws {
        let prompt = "🐼 Use café notes\n@Éditeur 🦉"
        let query = try XCTUnwrap(AIMentionQuery.trailing(in: prompt))
        XCTAssertEqual(query.query, "Éditeur 🦉")
        XCTAssertEqual(query.range, (prompt as NSString).range(of: "@Éditeur 🦉"))
        XCTAssertEqual(query.removing(from: prompt), "🐼 Use café notes\n")
    }

    func testMentionDoesNotContinueAcrossNewlines() {
        XCTAssertNil(AIMentionQuery.trailing(in: "Use @Line\nContinue writing"))
        XCTAssertNil(AIMentionQuery.trailing(in: "Use @Line\n"))
        XCTAssertEqual(AIMentionQuery.trailing(in: "Use another line\n@Proofreader")?.query, "Proofreader")
        XCTAssertEqual(AIMentionQuery.trailing(in: "  @Clear prose ")?.query, "Clear prose ")
    }

    func testAgentSelectionPreservesConfiguredOrderAndExplicitlyIncludesDisabledAgents() {
        let first = WritingAgent(name: "First", enabled: true)
        let disabled = WritingAgent(name: "Explicit only", enabled: false)
        let last = WritingAgent(name: "Last", enabled: true)
        var configuration = WritingTeamConfiguration(useTeam: true, agents: [first, disabled, last], skills: [], rules: [])

        XCTAssertEqual(configuration.selectedAgents(mentioned: []).map(\.id), [first.id, last.id])
        XCTAssertEqual(configuration.selectedAgents(mentioned: [last.id, disabled.id, UUID()]).map(\.id), [first.id, disabled.id, last.id])

        configuration.useTeam = false
        XCTAssertTrue(configuration.selectedAgents(mentioned: []).isEmpty)
        XCTAssertEqual(configuration.selectedAgents(mentioned: [last.id, disabled.id]).map(\.id), [disabled.id, last.id])
        XCTAssertFalse(configuration.agents[1].enabled, "Explicit selection must not enable an agent for future requests")
    }

    func testGuidanceAppliesWithoutTeamAndExplicitMentionsOnlyAffectCurrentRequest() {
        let enabledSkill = WritingGuidance(name: "Clarity", instructions: "CLARITY INSTRUCTION")
        let disabledSkill = WritingGuidance(name: "Voice", instructions: "VOICE INSTRUCTION", enabled: false)
        let enabledRule = WritingGuidance(name: "Evidence", instructions: "EVIDENCE INSTRUCTION")
        let disabledRule = WritingGuidance(name: "Format", instructions: "FORMAT INSTRUCTION", enabled: false)
        let configuration = WritingTeamConfiguration(useTeam: false, agents: [], skills: [enabledSkill, disabledSkill], rules: [enabledRule, disabledRule])

        let automatic = configuration.guidance()
        XCTAssertTrue(automatic.contains(enabledSkill.instructions))
        XCTAssertTrue(automatic.contains(enabledRule.instructions))
        XCTAssertFalse(automatic.contains(disabledSkill.instructions))
        XCTAssertFalse(automatic.contains(disabledRule.instructions))

        let explicit = configuration.guidance(skillIDs: [disabledSkill.id], ruleIDs: [disabledRule.id])
        for guidance in [enabledSkill, disabledSkill, enabledRule, disabledRule] {
            XCTAssertTrue(explicit.contains(guidance.name))
            XCTAssertTrue(explicit.contains(guidance.instructions))
        }
        XCTAssertEqual(configuration.guidance(), automatic)
        XCTAssertFalse(configuration.skills[1].enabled)
        XCTAssertFalse(configuration.rules[1].enabled)
    }

    func testConfigurationRoundTripPreservesIdentityOrderAndProviderOverrides() throws {
        let configuration = WritingTeamConfiguration(
            useTeam: true,
            orchestrator: WritingAgent(name: "Lead", instructions: "Reconcile feedback", provider: .anthropic, model: "custom-lead"),
            agents: [
                WritingAgent(name: "Second alphabetically", instructions: "Structure", provider: .openAI, model: "custom-gpt", enabled: false),
                WritingAgent(name: "First alphabetically", instructions: "Style", provider: .ollama, model: "local-writer"),
                WritingAgent(name: "Inherited", instructions: "Proofread", provider: nil, model: "")
            ],
            skills: [WritingGuidance(name: "Voice", instructions: "Keep my voice", enabled: false), WritingGuidance(name: "Clarity", instructions: "Be clear")],
            rules: [WritingGuidance(name: "Citations", instructions: "Preserve references")]
        )

        let restored = try JSONDecoder().decode(WritingTeamConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(restored, configuration)
        XCTAssertEqual(restored.agents.map(\.id), configuration.agents.map(\.id))
        XCTAssertEqual(restored.orchestrator.id, configuration.orchestrator.id)
        XCTAssertEqual(restored.agents.map(\.provider), [.openAI, .ollama, nil])
        XCTAssertEqual(restored.agents.map(\.model), ["custom-gpt", "local-writer", ""])
    }
}
