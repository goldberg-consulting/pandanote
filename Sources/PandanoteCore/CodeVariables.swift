import Foundation

public struct CodeVariable: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let type: String
    public let preview: String
    public let reusable: Bool
    public let reference: String
    public let pythonReference: String
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
