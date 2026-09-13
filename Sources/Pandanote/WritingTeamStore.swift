import SwiftUI
import PandanoteCore

@MainActor final class WritingTeamStore: ObservableObject {
    static let shared = WritingTeamStore()
    @Published var configuration: WritingTeamConfiguration {
        didSet { if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: "writingTeamConfiguration") } }
    }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = defaults.data(forKey: "writingTeamConfiguration").flatMap { try? JSONDecoder().decode(WritingTeamConfiguration.self, from: $0) } ?? WritingTeamConfiguration()
    }
}

enum AIProviderSettings {
    static func selected(defaults: UserDefaults = .standard) -> AIProvider {
        AIProvider(rawValue: defaults.string(forKey: "aiProvider") ?? "") ?? .apple
    }
    static func configuration(for provider: AIProvider, modelOverride: String = "", defaults: UserDefaults = .standard) -> AIModelConfiguration {
        let modelKey: String
        let base: String
        switch provider {
        case .apple: modelKey = ""; base = ""
        case .openAI: modelKey = "openAIModel"; base = "https://api.openai.com/v1"
        case .anthropic: modelKey = "anthropicModel"; base = "https://api.anthropic.com/v1"
        case .ollama: modelKey = "ollamaModel"; base = defaults.string(forKey: "ollamaURL") ?? "http://localhost:11434"
        case .compatible: modelKey = "aiModel"; base = defaults.string(forKey: "aiBaseURL") ?? ""
        }
        let override = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return AIModelConfiguration(provider: provider, model: override.isEmpty ? (defaults.string(forKey: modelKey) ?? "") : override, baseURL: base)
    }
}
