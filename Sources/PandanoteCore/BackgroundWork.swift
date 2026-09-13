import Foundation

/// Blocking file/provider and process work must never occupy the main actor or
/// exhaust Swift's cooperative executor. Each operation owns its local objects.
public enum BackgroundWork {
    private static let queue = DispatchQueue(label: "com.goldbergconsulting.pandanote.work", qos: .utility, attributes: .concurrent)

    public static func run<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}

public struct PublicationResult: Sendable {
    public let success: Bool
    public let message: String
    public let log: String
    public let logURL: URL?
    public let pdfURL: URL?
    public let text: String?
    public let variableBlocks: [CodeVariableBlock]

    public init(data: Data) throws {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineFailure.failed("Inkwell returned an unreadable response.")
        }
        success = result["success"] as? Bool == true
        message = result["message"] as? String ?? (success ? "Complete" : "Inkwell could not finish. See the build output.")
        var fullLogURL = (result["logPath"] as? String).map { URL(fileURLWithPath: $0) }
        pdfURL = (result["pdfPath"] as? String).map { URL(fileURLWithPath: $0) }
        text = result["text"] as? String
        variableBlocks = try CodeVariableBlock.decodeResponse(data)
        let output: String
        if let value = result["log"] as? String { output = value }
        else if let runs = result["results"] as? [[String: Any]] {
            let sections = runs.enumerated().map { index, run -> String in
                let block = run["block"] as? [String: Any] ?? [:]
                let name = block["id"] as? String ?? block["label"] as? String ?? "Block \(index + 1)"
                let language = (block["lang"] as? String ?? "Code").capitalized
                let outcome = (run["exitCode"] as? Int ?? 1) == 0 ? (run["cached"] as? Bool == true ? "saved result" : "complete") : "failed"
                let stdout = run["stdout"] as? String ?? ""
                let stderr = run["stderr"] as? String ?? ""
                let warning = run["warning"] as? String ?? ""
                let content = [stdout, stderr, warning].filter { !$0.isEmpty }.joined(separator: "\n")
                return "\(name) · \(language) · \(outcome)\n" + (content.isEmpty ? "No printed output. Captured Python values are in Variables." : content)
            }
            output = ([message] + sections).joined(separator: "\n\n")
        }
        else { output = String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self) }
        // Keep TeX's full log on disk; laying out megabytes of output in SwiftUI
        // can otherwise freeze the editor even after the subprocess has finished.
        if output.count > 32_000 {
            if fullLogURL == nil {
                let target = FileManager.default.temporaryDirectory.appendingPathComponent("pandanote-output-\(UUID().uuidString).log")
                try output.write(to: target, atomically: true, encoding: .utf8)
                fullLogURL = target
            }
            log = "Earlier output omitted. Open the full log for details.\n\n" + String(output.suffix(32_000))
        } else { log = output }
        logURL = fullLogURL
    }
}
