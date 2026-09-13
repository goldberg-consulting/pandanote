import Foundation

/// A model service available to a writing workflow.
public enum AIProvider: String, Codable, CaseIterable, Sendable {
    case apple = "Apple Intelligence"
    case openAI = "OpenAI (GPT)"
    case anthropic = "Anthropic (Claude)"
    case ollama = "Ollama"
    case compatible = "Compatible API"

    /// Whether the provider normally sends writing to an external service.
    public var isRemote: Bool {
        switch self {
        case .openAI, .anthropic, .compatible: return true
        case .apple, .ollama: return false
        }
    }
}

/// Selects a model and, for a custom service, its base address. Contains no credentials.
public struct AIModelConfiguration: Codable, Equatable, Sendable {
    public var provider: AIProvider
    public var model: String
    public var baseURL: String

    /// Creates a model selection. Official providers ignore the custom base address.
    public init(provider: AIProvider, model: String, baseURL: String = "") {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
    }
}

/// A user or assistant message included in a model's conversation history.
public struct AIChatTurn: Codable, Equatable, Sendable {
    public var role: String
    public var text: String

    /// Creates a history message; request construction validates its role.
    public init(role: String, text: String) {
        self.role = role
        self.text = text
    }
}

/// A configuration or response failure that prevents using an incomplete model answer.
public enum AIProviderError: LocalizedError, Equatable, Sendable {
    case configuration(String)
    case service(String)
    case malformedStream
    case incompleteStream
    case stopped(String)
    case refusal

    public var errorDescription: String? {
        switch self {
        case .configuration(let message), .service(let message): return message
        case .malformedStream: return "The model returned an unreadable stream. Please try again."
        case .incompleteStream: return "The model stream ended before confirming a complete answer. Please try again."
        case .stopped(let reason): return "The model did not complete its answer (\(reason)). Try a shorter passage or another model."
        case .refusal: return "The model declined this request. No revision was proposed."
        }
    }
}

/// Builds streaming requests without performing network work or storing credentials.
public enum AIRequestBuilder {
    /// Builds a provider-native request. Send it with a session that refuses redirects.
    public static func request(
        configuration: AIModelConfiguration,
        system: String,
        history: [AIChatTurn],
        prompt: String,
        apiKey: String
    ) throws -> URLRequest {
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw AIProviderError.configuration("Enter a model name in AI settings.")
        }
        guard history.allSatisfy({ ["user", "assistant"].contains($0.role) }) else {
            throw AIProviderError.configuration("Conversation history must contain only user and assistant messages.")
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.contains(where: { $0.isNewline }) else {
            throw AIProviderError.configuration("The API key contains an unexpected line break.")
        }
        if [.openAI, .anthropic].contains(configuration.provider), key.isEmpty {
            throw AIProviderError.configuration("Save an API key for \(configuration.provider.rawValue) in AI settings.")
        }

        let url: URL
        switch configuration.provider {
        case .apple:
            throw AIProviderError.configuration("Apple Intelligence runs on your Mac and does not use an HTTP endpoint.")
        case .openAI:
            url = try endpoint(base: "https://api.openai.com/v1", route: "chat/completions")
        case .anthropic:
            url = try endpoint(base: "https://api.anthropic.com/v1", route: "messages")
        case .ollama:
            url = try endpoint(base: configuration.baseURL, route: "api/chat")
        case .compatible:
            url = try endpoint(base: configuration.baseURL, route: "chat/completions")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.provider == .ollama ? "application/x-ndjson" : "text/event-stream", forHTTPHeaderField: "Accept")
        let messages = history.map { ["role": $0.role, "content": $0.text] } + [["role": "user", "content": prompt]]
        var payload: [String: Any] = ["model": model, "stream": true]
        if configuration.provider == .anthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            payload["max_tokens"] = 8192
            payload["system"] = system
            payload["messages"] = messages
        } else {
            if configuration.provider != .ollama, !key.isEmpty {
                request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            }
            payload["messages"] = [["role": "system", "content": system]] + messages
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private static func endpoint(base: String, route: String) throws -> URL {
        let address = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else {
            throw AIProviderError.configuration("Enter an HTTPS base URL, or use HTTP with localhost for a local model. Do not include credentials, a query, or a fragment in the URL.")
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + (components.path.isEmpty ? "" : components.path + "/") + route
        guard let url = components.url else {
            throw AIProviderError.configuration("The model server address is invalid.")
        }
        return url
    }
}

/// Extracts writing from provider streams and requires an explicit, successful completion.
public struct AIStreamParser: Sendable {
    private let provider: AIProvider
    private var terminalReceived = false
    private var stopReason: String?
    private var failure: AIProviderError?

    /// Creates a parser for one response from the selected provider.
    public init(provider: AIProvider) {
        self.provider = provider
    }

    /// Consumes one UTF-8 stream line and returns only newly generated answer text.
    public mutating func consume(line: String) throws -> String {
        if let failure { throw failure }
        let payload: String
        if provider == .ollama {
            payload = line.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            // SSE comments and event metadata carry no answer text.
            guard line.hasPrefix("data:") else { return "" }
            payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !payload.isEmpty else { return "" }
        if payload == "[DONE]", provider == .openAI || provider == .compatible {
            terminalReceived = true
            return ""
        }
        do {
            guard let value = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
                throw AIProviderError.malformedStream
            }
            if let error = value["error"], !(error is NSNull) {
                let message = (error as? [String: Any])?["message"] as? String
                    ?? error as? String
                    ?? "The model service reported an error. Please try again."
                throw AIProviderError.service(message)
            }
            guard !terminalReceived else { throw AIProviderError.malformedStream }
            switch provider {
            case .openAI, .compatible: return try consumeChatCompletion(value)
            case .anthropic: return try consumeClaude(value)
            case .ollama: return consumeOllama(value)
            case .apple: throw AIProviderError.configuration("Apple Intelligence does not use a network stream.")
            }
        } catch {
            let providerError = error as? AIProviderError ?? .malformedStream
            failure = providerError
            throw providerError
        }
    }

    /// Confirms the response ended normally; truncated, refused, or interrupted writing is rejected.
    public func finish() throws {
        if let failure { throw failure }
        guard terminalReceived, stopReason != nil else { throw AIProviderError.incompleteStream }
    }

    private mutating func consumeChatCompletion(_ value: [String: Any]) throws -> String {
        guard let choices = value["choices"] as? [[String: Any]],
              let choice = choices.first(where: { ($0["index"] as? Int ?? 0) == 0 }) else { return "" }
        let delta = choice["delta"] as? [String: Any] ?? [:]
        if let refusal = delta["refusal"] as? String, !refusal.isEmpty { throw AIProviderError.refusal }
        if let reason = choice["finish_reason"] as? String {
            recordStop(reason, allowed: ["stop"])
        }
        return delta["content"] as? String ?? ""
    }

    private mutating func consumeClaude(_ value: [String: Any]) throws -> String {
        switch value["type"] as? String {
        case "content_block_start":
            let block = value["content_block"] as? [String: Any]
            if block?["type"] as? String == "refusal" { throw AIProviderError.refusal }
            return block?["type"] as? String == "text" ? block?["text"] as? String ?? "" : ""
        case "content_block_delta":
            let delta = value["delta"] as? [String: Any]
            if delta?["type"] as? String == "refusal_delta" { throw AIProviderError.refusal }
            return delta?["type"] as? String == "text_delta" ? delta?["text"] as? String ?? "" : ""
        case "message_delta":
            if let reason = (value["delta"] as? [String: Any])?["stop_reason"] as? String {
                recordStop(reason, allowed: ["end_turn", "stop_sequence"])
            }
            return ""
        case "message_stop":
            terminalReceived = true
            return ""
        default:
            // Ignore pings, thinking, usage, and future event types.
            return ""
        }
    }

    private mutating func consumeOllama(_ value: [String: Any]) -> String {
        if value["done"] as? Bool == true {
            terminalReceived = true
            if let reason = value["done_reason"] as? String { recordStop(reason, allowed: ["stop"]) }
        }
        return (value["message"] as? [String: Any])?["content"] as? String ?? ""
    }

    private mutating func recordStop(_ reason: String, allowed: Set<String>) {
        stopReason = reason
        if !allowed.contains(reason) {
            failure = ["refusal", "content_filter"].contains(reason) ? .refusal : .stopped(reason)
        }
    }
}
