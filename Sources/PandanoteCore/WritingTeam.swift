import Foundation

public struct WritingAgent: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var instructions: String
    public var provider: AIProvider?
    public var model: String
    public var enabled: Bool
    public init(id: UUID = UUID(), name: String = "New agent", instructions: String = "", provider: AIProvider? = nil, model: String = "", enabled: Bool = true) {
        self.id = id; self.name = name; self.instructions = instructions; self.provider = provider; self.model = model; self.enabled = enabled
    }
}

public struct WritingGuidance: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var instructions: String
    public var enabled: Bool
    public init(id: UUID = UUID(), name: String = "New guidance", instructions: String = "", enabled: Bool = true) {
        self.id = id; self.name = name; self.instructions = instructions; self.enabled = enabled
    }
}

public struct WritingTeamConfiguration: Codable, Equatable, Sendable {
    public var useTeam: Bool
    public var orchestrator: WritingAgent
    public var agents: [WritingAgent]
    public var skills: [WritingGuidance]
    public var rules: [WritingGuidance]
    public init(useTeam: Bool = false,
                orchestrator: WritingAgent = WritingAgent(name: "Writing orchestrator", instructions: "Identify the author's goal, guide the writing team, and reconcile its suggestions into a coherent result. Preserve the author's voice and meaning."),
                agents: [WritingAgent] = [WritingAgent(name: "Developmental editor", instructions: "Examine the argument, structure, and flow. Identify unsupported claims and suggest focused improvements."), WritingAgent(name: "Line editor", instructions: "Improve clarity, rhythm, and word choice. Prefer precise language and preserve the author's voice.")],
                skills: [WritingGuidance] = [WritingGuidance(name: "Clear prose", instructions: "Lead with the main point. Use concrete language and active verbs. Keep each paragraph focused on one idea.", enabled: false)],
                rules: [WritingGuidance] = [WritingGuidance(name: "Preserve evidence", instructions: "Never fabricate facts, quotations, or citations. Preserve citations, equations, and technical meaning. Flag missing evidence instead of inventing it.")]) {
        self.useTeam = useTeam; self.orchestrator = orchestrator; self.agents = agents; self.skills = skills; self.rules = rules
    }

    /// Explicit mentions opt an otherwise disabled item into this request only.
    public func selectedAgents(mentioned: Set<UUID>) -> [WritingAgent] {
        agents.filter { (useTeam && $0.enabled) || mentioned.contains($0.id) }
    }
    public func guidance(skillIDs: Set<UUID> = [], ruleIDs: Set<UUID> = []) -> String {
        let selectedSkills = skills.filter { $0.enabled || skillIDs.contains($0.id) }
        let selectedRules = rules.filter { $0.enabled || ruleIDs.contains($0.id) }
        return (selectedSkills.map { "Writing skill — \($0.name):\n\($0.instructions)" } + selectedRules.map { "Writing rule — \($0.name):\n\($0.instructions)" }).joined(separator: "\n\n")
    }
}

public struct AIPassageContext: Equatable, Sendable {
    public let root: URL
    public let file: URL
    public let relativePath: String
    public let base: String
    public let range: NSRange
    public var text: String { (base as NSString).substring(with: range) }
    public init(root: URL, file: URL, relativePath: String, base: String, range: NSRange) throws {
        guard Self.isValid(range: range, in: base) else { throw WritingContextError.invalidSelection }
        self.root = root; self.file = file; self.relativePath = relativePath; self.base = base; self.range = range
    }
    public static func isValid(range: NSRange, in text: String) -> Bool {
        let source = text as NSString
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= source.length, range.length <= source.length - range.location else { return false }
        // Foundation range conversion can preserve indices inside a surrogate pair.
        // Check UTF-16 scalar boundaries before extracting a passage with NSString.
        func isBoundary(_ offset: Int) -> Bool {
            offset == 0 || offset == source.length
                || !(0xDC00...0xDFFF).contains(source.character(at: offset))
                || !(0xD800...0xDBFF).contains(source.character(at: offset - 1))
        }
        return isBoundary(range.location) && isBoundary(range.location + range.length)
    }
    public func validate(root: URL?, file: URL?, text: String) throws {
        guard self.root == root, self.file == file, base == text else { throw WritingContextError.staleSelection }
    }
}

public enum WritingContextError: LocalizedError {
    case invalidSelection, staleSelection
    public var errorDescription: String? {
        switch self {
        case .invalidSelection: return "Highlight a passage in the source editor first."
        case .staleSelection: return "The attached passage belongs to an earlier version or a different note. Highlight it again, or remove the attachment before revising."
        }
    }
}

/// A trailing @ query is a composer command; an @ inside a word remains literal.
public struct AIMentionQuery: Equatable {
    public let range: NSRange
    public let query: String
    public static func trailing(in text: String) -> AIMentionQuery? {
        guard let expression = try? NSRegularExpression(pattern: "(?:^|\\s)(@[^@\\n]*)\\z"),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let token = String(text[range])
        return AIMentionQuery(range: match.range(at: 1), query: String(token.dropFirst()))
    }
    public func removing(from text: String) -> String {
        guard let swiftRange = Range(range, in: text) else { return text }
        return text.replacingCharacters(in: swiftRange, with: "")
    }
}
