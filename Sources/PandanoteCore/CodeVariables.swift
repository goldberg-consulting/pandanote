import Foundation

public struct CodeVariable: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let type: String
    public let preview: String
    public let reusable: Bool
    public let reference: String
    public let pythonReference: String

    public func formattedReference(_ format: CodeVariableFormat) -> String? {
        guard ["int", "float"].contains(type), reference.hasPrefix("{"),
              !reference.hasPrefix("{{"), reference.hasSuffix("}"), reference.contains(".") else { return nil }
        return String(reference.dropLast()) + ":" + format.rawValue + "}"
    }
}

public enum CodeVariableFormat: String, CaseIterable, Identifiable, Sendable {
    case whole = ".0f", decimal = ".2f", grouped = ",.2f", percentage = ".1%", scientific = ".2e", significant = ".3g"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .whole: "Whole number"
        case .decimal: "Two decimal places"
        case .grouped: "Thousands separators · two decimals"
        case .percentage: "Percentage · one decimal"
        case .scientific: "Scientific · two decimals"
        case .significant: "Three significant digits"
        }
    }
}

public struct CodeVariableBlock: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let index: Int
    public let startLine: Int
    public let language: String
    public let runID: String?
    public let fingerprint: String?
    public let status: String
    public let variables: [CodeVariable]
    public let message: String?

    public static func decodeResponse(_ data: Data) throws -> [CodeVariableBlock] {
        struct Response: Decodable { let variableBlocks: [CodeVariableBlock]? }
        return try JSONDecoder().decode(Response.self, from: data).variableBlocks ?? []
    }
}
