import Foundation

public struct LocalMailSummary: Codable, Equatable, Sendable {
    public let id: String
    public let subject: String
    public let sender: String
    public let receivedAt: Date
    public let isUnread: Bool
    public init(id: String, subject: String, sender: String, receivedAt: Date, isUnread: Bool) {
        self.id = id; self.subject = subject; self.sender = sender
        self.receivedAt = receivedAt; self.isUnread = isUnread
    }
}

public struct LocalMailContent: Codable, Equatable, Sendable {
    public let message: LocalMailSummary
    public let text: String
    public init(message: LocalMailSummary, text: String) { self.message = message; self.text = text }
}

public protocol MailReadingBackend: Sendable {
    var isSimulation: Bool { get }
    func scopeID() async throws -> String?
    func search(query: String, unreadOnly: Bool) async throws -> [LocalMailSummary]
    func read(id: String) async throws -> LocalMailContent
}

public actor LocalMailCoordinator: CommandAdapter {
    public nonisolated let supportedActions: Set<String> = ["mail.search", "mail.read"]
    public nonisolated let isSimulation: Bool
    private let backend: any MailReadingBackend
    public init(backend: any MailReadingBackend) { self.backend = backend; self.isSimulation = backend.isSimulation }

    func execute(_ command: BridgeCommand) async throws -> AdapterExecution {
        try ActionParameterValidator().validate(action: command.action, parameters: command.parameters, protocolVersion: "1.5")
        guard let scope = try await backend.scopeID() else { throw StableErrorCode.capabilityDisabled }
        if let expected = BridgeExecutionContext.mailScopeID, expected != scope { throw StableErrorCode.permissionRequired }
        guard case .object(let p) = command.parameters else { throw StableErrorCode.invalidSchema }
        let result: JSONValue
        switch command.action {
        case "mail.search":
            let query: String
            if case .string(let value)? = p["query"] { query = value } else { query = "" }
            let unreadOnly: Bool
            if case .bool(let value)? = p["unread_only"] { unreadOnly = value } else { unreadOnly = false }
            let messages = try await backend.search(query: query, unreadOnly: unreadOnly)
            guard messages.count <= 50, Set(messages.map(\.id)).count == messages.count,
                  messages.allSatisfy(Self.valid) else { throw StableErrorCode.resultUnverifiable }
            result = .object(["messages": try Self.json(messages)])
        case "mail.read":
            guard case .string(let id)? = p["message_id"] else { throw StableErrorCode.invalidSchema }
            let content = try await backend.read(id: id)
            guard content.message.id == id, Self.valid(content.message), content.text.count <= 24_000 else {
                throw StableErrorCode.resultUnverifiable
            }
            result = .object(["mail": try Self.json(content)])
        default: throw StableErrorCode.capabilityDisabled
        }
        guard try await backend.scopeID() == scope else { throw StableErrorCode.permissionRequired }
        return .succeeded(summary: result)
    }

    private static func valid(_ message: LocalMailSummary) -> Bool {
        !message.id.isEmpty && message.id.count <= 256 && message.subject.count <= 512 &&
        message.sender.count <= 512 && message.receivedAt.timeIntervalSince1970.isFinite
    }

    private static func json<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }
}
