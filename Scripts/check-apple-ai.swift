import Foundation
import FoundationModels
if #available(macOS 26.0, *) {
    print("Apple language model: \(SystemLanguageModel.default.availability)")
    if CommandLine.arguments.contains("--respond"), case .available = SystemLanguageModel.default.availability {
        let session = LanguageModelSession(instructions: "You are a concise writing assistant.")
        let response = try await session.respond(to: "Say hello to a writer starting a new notebook, in one short sentence.")
        print("Response: \(response.content)")
    }
} else { print("Apple language model requires macOS 26.") }
