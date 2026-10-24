import Foundation
import CryptoKit

public struct MailDraftInput: Codable, Equatable, Sendable {
    public let sender: String
    public let to: [String]
    public let cc: [String]
    public let bcc: [String]
    public let subject: String
    public let text: String
    public init(sender: String, to: [String], cc: [String] = [], bcc: [String] = [], subject: String, text: String) {
        self.sender = sender; self.to = to; self.cc = cc; self.bcc = bcc; self.subject = subject; self.text = text
    }
    public func validate() throws {
        func address(_ value: String) -> Bool {
            value.count <= 254 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
            !value.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "," || $0 == ";" }) &&
            value.split(separator: "@", omittingEmptySubsequences: false).count == 2 &&
            value.split(separator: "@", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty }
        }
        guard address(sender), !to.isEmpty, to.count + cc.count + bcc.count <= 20,
              (to + cc + bcc).allSatisfy(address), subject.count <= 512,
              !subject.contains("\n"), !subject.contains("\r"), text.count <= 24_000 else {
            throw StableErrorCode.invalidSchema
        }
    }
}

public struct MailDraftContent: Codable, Equatable, Sendable {
    public let id: String
    public let scopeID: String
    public let sender: String
    public let to: [String]
    public let cc: [String]
    public let bcc: [String]
    public let subject: String
    public let text: String
    public let revision: String
    public init(id: String, scopeID: String, sender: String, to: [String], cc: [String], bcc: [String], subject: String, text: String, revision: String) {
        self.id = id; self.scopeID = scopeID; self.sender = sender; self.to = to; self.cc = cc; self.bcc = bcc
        self.subject = subject; self.text = text; self.revision = revision
    }
    public var input: MailDraftInput { .init(sender: sender, to: to, cc: cc, bcc: bcc, subject: subject, text: text) }
}

public enum MailSendNativeOutcome: String, Codable, Sendable { case submitted, unknown }

public protocol MailDraftBackend: Sendable {
    var isSimulation: Bool { get }
    func createDraft(id: String, input: MailDraftInput) async throws -> MailDraftContent
    func readDraft(id: String) async throws -> MailDraftContent
    func requestSend(id: String, revision: String) async throws
    func draftStatus(id: String) async throws -> String
}

public actor LocalMailDraftCoordinator: CommandAdapter {
    public nonisolated let supportedActions: Set<String> = ["mail.draft.create", "mail.draft.read", "mail.send.request", "mail.draft.status"]
    public nonisolated let isSimulation: Bool
    private let backend: any MailDraftBackend
    public init(backend: any MailDraftBackend) { self.backend = backend; isSimulation = backend.isSimulation }
    func execute(_ command: BridgeCommand) async throws -> AdapterExecution {
        try ActionParameterValidator().validate(action: command.action, parameters: command.parameters, protocolVersion: "1.6")
        guard case .object(let p) = command.parameters, case .string(let id)? = p["draft_id"] else { throw StableErrorCode.invalidSchema }
        func string(_ key: String) -> String { if case .string(let s)? = p[key] { return s }; return "" }
        func addresses(_ key: String) -> [String] { if case .array(let list)? = p[key] { return list.compactMap { if case .string(let s) = $0 { return s }; return nil } }; return [] }
        switch command.action {
        case "mail.draft.create":
            let input = MailDraftInput(sender: string("sender"), to: addresses("to"), cc: addresses("cc"), bcc: addresses("bcc"), subject: string("subject"), text: string("text"))
            let draft = try await backend.createDraft(id: id, input: input)
            return .succeeded(summary: .object(["draft_id": .string(id), "revision": .string(draft.revision)]))
        case "mail.draft.read":
            let draft = try await backend.readDraft(id: id)
            let encoder = JSONEncoder()
            return .succeeded(summary: .object(["draft": try JSONDecoder().decode(JSONValue.self, from: encoder.encode(draft))]))
        case "mail.send.request":
            try await backend.requestSend(id: id, revision: string("expected_revision"))
            return .succeeded(summary: .object(["draft_id": .string(id), "send_state": .string("awaiting_confirmation")]))
        case "mail.draft.status":
            return .succeeded(summary: .object(["draft_id": .string(id), "send_state": .string(try await backend.draftStatus(id: id))]))
        default: throw StableErrorCode.capabilityDisabled
        }
    }
}
