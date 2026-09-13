import Foundation
import XCTest
@testable import PandanoteCore

final class AIProviderTests: XCTestCase {
    func test_openAIRequest_when_configured_expectsOfficialEndpointAndBearerAuthentication() throws {
        let request = try AIRequestBuilder.request(
            configuration: AIModelConfiguration(provider: .openAI, model: " gpt-test ", baseURL: "https://other.example"),
            system: "Preserve my voice.",
            history: [AIChatTurn(role: "user", text: "Earlier question"), AIChatTurn(role: "assistant", text: "Earlier answer")],
            prompt: "Rewrite 🐼", apiKey: "secret"
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        let body = try payload(request)
        XCTAssertEqual(body["model"] as? String, "gpt-test")
        XCTAssertEqual(body["stream"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user", "assistant", "user"])
        XCTAssertEqual(messages.last?["content"], "Rewrite 🐼")
        XCTAssertNil(body["apiKey"])
    }

    func test_claudeRequest_when_configured_expectsMessagesProtocolAndTopLevelSystem() throws {
        let request = try AIRequestBuilder.request(
            configuration: AIModelConfiguration(provider: .anthropic, model: "claude-test", baseURL: "http://localhost:9999"),
            system: "Write clearly.", history: [AIChatTurn(role: "user", text: "Previous")],
            prompt: "Edit this", apiKey: "claude-secret"
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "claude-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try payload(request)
        XCTAssertEqual(body["system"] as? String, "Write clearly.")
        XCTAssertEqual(body["max_tokens"] as? Int, 8192)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["user", "user"])
    }

    func test_customRequests_when_localOrHTTPS_expectsCorrectRoutesAndCredentials() throws {
        for address in ["http://localhost:11434", "http://127.0.0.1:11434/", "http://[::1]:11434/"] {
            let request = try makeRequest(provider: .ollama, baseURL: address)
            XCTAssertEqual(request.url?.path, "/api/chat")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/x-ndjson")
        }
        let request = try makeRequest(provider: .compatible, baseURL: "https://models.example/gateway/v1/")
        XCTAssertEqual(request.url?.absoluteString, "https://models.example/gateway/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let noKeyRequest = try makeRequest(provider: .compatible, baseURL: "http://localhost:8000/v1", apiKey: "")
        XCTAssertNil(noKeyRequest.value(forHTTPHeaderField: "Authorization"))
    }

    func test_request_when_addressOrCredentialsInvalid_expectsRejection() {
        for address in ["", "models.example/v1", "http://models.example/v1", "http://localhost.evil.example/v1", "file:///v1", "https://user:secret@models.example/v1", "https://models.example/v1?key=secret", "https://models.example/v1#fragment"] {
            XCTAssertThrowsError(try makeRequest(provider: .compatible, baseURL: address), address)
        }
        for provider in [AIProvider.openAI, .anthropic] {
            XCTAssertThrowsError(try makeRequest(provider: provider, apiKey: ""))
        }
        XCTAssertThrowsError(try makeRequest(provider: .openAI, apiKey: "secret\nInjected: header"))
        XCTAssertThrowsError(try AIRequestBuilder.request(configuration: AIModelConfiguration(provider: .openAI, model: " "), system: "", history: [], prompt: "", apiKey: "secret"))
        XCTAssertThrowsError(try AIRequestBuilder.request(configuration: AIModelConfiguration(provider: .openAI, model: "gpt-test"), system: "", history: [AIChatTurn(role: "system", text: "Untrusted")], prompt: "", apiKey: "secret"))
        XCTAssertThrowsError(try makeRequest(provider: .apple))
    }

    func test_openAIStream_when_complete_expectsTextAndSuccessfulFinish() throws {
        for provider in [AIProvider.openAI, .compatible] {
            var parser = AIStreamParser(provider: provider)
            XCTAssertEqual(try parser.consume(line: ": keepalive"), "")
            XCTAssertEqual(try parser.consume(line: "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":null}]}"), "")
            XCTAssertEqual(try parser.consume(line: "data:{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello 🐼\"},\"finish_reason\":null}]}"), "Hello 🐼")
            XCTAssertEqual(try parser.consume(line: "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}"), "")
            XCTAssertEqual(try parser.consume(line: "data: {\"choices\":[],\"usage\":{\"total_tokens\":12}}"), "")
            _ = try parser.consume(line: "data: [DONE]")
            XCTAssertNoThrow(try parser.finish())
        }
    }

    func test_openAIStream_when_missingStopOrTerminal_expectsIncompleteFailure() throws {
        var onlyDone = AIStreamParser(provider: .openAI)
        _ = try onlyDone.consume(line: "data: [DONE]")
        XCTAssertThrowsError(try onlyDone.finish()) { XCTAssertEqual($0 as? AIProviderError, .incompleteStream) }
        var onlyStop = AIStreamParser(provider: .openAI)
        _ = try onlyStop.consume(line: "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}")
        XCTAssertThrowsError(try onlyStop.finish())
    }

    func test_openAIStream_when_truncatedOrToolCall_expectsFailureDespiteDone() throws {
        for reason in ["length", "tool_calls", "function_call", "unknown"] {
            var parser = AIStreamParser(provider: .openAI)
            _ = try parser.consume(line: "data: {\"choices\":[{\"delta\":{\"content\":\"Partial\"},\"finish_reason\":\"\(reason)\"}]}")
            XCTAssertThrowsError(try parser.consume(line: "data: [DONE]"))
            XCTAssertThrowsError(try parser.finish()) { XCTAssertEqual($0 as? AIProviderError, .stopped(reason)) }
        }
    }

    func test_stream_when_refused_expectsRefusalFailure() throws {
        var openAI = AIStreamParser(provider: .openAI)
        XCTAssertThrowsError(try openAI.consume(line: "data: {\"choices\":[{\"delta\":{\"refusal\":\"Cannot help\"},\"finish_reason\":null}]}"))
        XCTAssertThrowsError(try openAI.finish()) { XCTAssertEqual($0 as? AIProviderError, .refusal) }
        var filtered = AIStreamParser(provider: .openAI)
        _ = try filtered.consume(line: "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"content_filter\"}]}")
        XCTAssertThrowsError(try filtered.finish()) { XCTAssertEqual($0 as? AIProviderError, .refusal) }
        var claude = AIStreamParser(provider: .anthropic)
        _ = try claude.consume(line: "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\"}}")
        XCTAssertThrowsError(try claude.finish()) { XCTAssertEqual($0 as? AIProviderError, .refusal) }
    }

    func test_claudeStream_when_complete_expectsOnlyTextAndSuccessfulFinish() throws {
        var parser = AIStreamParser(provider: .anthropic)
        XCTAssertEqual(try parser.consume(line: "event: content_block_start"), "")
        XCTAssertEqual(try parser.consume(line: "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"Hello\"}}"), "Hello")
        XCTAssertEqual(try parser.consume(line: "data: {\"type\":\"ping\"}"), "")
        XCTAssertEqual(try parser.consume(line: "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"Hidden\"}}"), "")
        XCTAssertEqual(try parser.consume(line: "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" world\"}}"), " world")
        _ = try parser.consume(line: "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}")
        _ = try parser.consume(line: "data: {\"type\":\"message_stop\"}")
        XCTAssertNoThrow(try parser.finish())
    }

    func test_claudeStream_when_truncatedOrInterrupted_expectsFailure() throws {
        for reason in ["max_tokens", "tool_use", "pause_turn"] {
            var parser = AIStreamParser(provider: .anthropic)
            _ = try parser.consume(line: "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(reason)\"}}")
            XCTAssertThrowsError(try parser.finish()) { XCTAssertEqual($0 as? AIProviderError, .stopped(reason)) }
        }
        var missingTerminal = AIStreamParser(provider: .anthropic)
        _ = try missingTerminal.consume(line: "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}")
        XCTAssertThrowsError(try missingTerminal.finish())
        var missingReason = AIStreamParser(provider: .anthropic)
        _ = try missingReason.consume(line: "data: {\"type\":\"message_stop\"}")
        XCTAssertThrowsError(try missingReason.finish())
    }

    func test_ollamaStream_when_done_expectsTextAndVerifiedStop() throws {
        var parser = AIStreamParser(provider: .ollama)
        XCTAssertEqual(try parser.consume(line: "{\"message\":{\"content\":\"Local answer\"},\"done\":false}"), "Local answer")
        _ = try parser.consume(line: "{\"message\":{\"content\":\"\"},\"done\":true,\"done_reason\":\"stop\"}")
        XCTAssertNoThrow(try parser.finish())
        var truncated = AIStreamParser(provider: .ollama)
        _ = try truncated.consume(line: "{\"done\":true,\"done_reason\":\"length\"}")
        XCTAssertThrowsError(try truncated.finish()) { XCTAssertEqual($0 as? AIProviderError, .stopped("length")) }
        var missingReason = AIStreamParser(provider: .ollama)
        _ = try missingReason.consume(line: "{\"done\":true}")
        XCTAssertThrowsError(try missingReason.finish())
    }

    func test_stream_when_errorOrMalformedData_expectsPersistentFailure() {
        for provider in [AIProvider.openAI, .anthropic, .ollama, .compatible] {
            let prefix = provider == .ollama ? "" : "data: "
            var serviceError = AIStreamParser(provider: provider)
            XCTAssertThrowsError(try serviceError.consume(line: prefix + "{\"error\":{\"message\":\"Unavailable\"}}"))
            XCTAssertThrowsError(try serviceError.finish()) { XCTAssertEqual($0 as? AIProviderError, .service("Unavailable")) }
            var malformed = AIStreamParser(provider: provider)
            XCTAssertThrowsError(try malformed.consume(line: prefix + "{\"truncated\":"))
            XCTAssertThrowsError(try malformed.finish()) { XCTAssertEqual($0 as? AIProviderError, .malformedStream) }
        }
    }

    private func makeRequest(provider: AIProvider, baseURL: String = "", apiKey: String = "secret") throws -> URLRequest {
        try AIRequestBuilder.request(configuration: AIModelConfiguration(provider: provider, model: "test-model", baseURL: baseURL), system: "System", history: [], prompt: "Request", apiKey: apiKey)
    }

    private func payload(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
