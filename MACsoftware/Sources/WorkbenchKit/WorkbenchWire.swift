import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

public struct WorkbenchRequest: Codable, Sendable {
    public let version: Int
    public let requestID: String
    public let operation: String
    public let action: String?
    public let parameters: JSONValue
    public let credential: String

    public init(version: Int = 1, requestID: String, operation: String, action: String? = nil,
                parameters: JSONValue = .object([:]), credential: String) {
        self.version = version; self.requestID = requestID; self.operation = operation
        self.action = action; self.parameters = parameters; self.credential = credential
    }
}

public struct WorkbenchResponse: Codable, Sendable {
    public let version: Int
    public let requestID: String
    public let status: String
    public let error: String?
    public let result: JSONValue

    public init(requestID: String, status: String, error: String? = nil, result: JSONValue = .object([:])) {
        self.version = 1; self.requestID = requestID; self.status = status
        self.error = error; self.result = result
    }
}

public enum WorkbenchPaths {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hushlight/Workbench", isDirectory: true)
    }
    public static var defaultSocketPath: String { defaultDirectory.appendingPathComponent("workbench.sock").path }
}
