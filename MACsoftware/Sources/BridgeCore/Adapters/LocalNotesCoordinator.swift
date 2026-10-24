import Foundation

public struct LocalNoteSummary: Equatable, Sendable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

public struct LocalNoteContent: Equatable, Sendable {
    public let id: String
    public let title: String
    /// Complete plain text, including the title.
    public let text: String
    /// Lowercase SHA-256 of the underlying HTML.
    public let revision: String
    public let canAppend: Bool
    public init(id: String, title: String, text: String, revision: String, canAppend: Bool) {
        self.id = id; self.title = title; self.text = text
        self.revision = revision; self.canAppend = canAppend
    }
}

public enum LocalNotesText {
    public static func canonical(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        while value.hasSuffix("\n") { value.removeLast() }
        return value
    }
}

/// The backend owns the dedicated Bridge Notes folder, stable IDs, and HTML checks.
public protocol NotesBackend: Sendable {
    var isSimulation: Bool { get }
    func isEnabled() async -> Bool
    func enable() async throws
    func list(query: String) async throws -> [LocalNoteSummary]
    func read(id: String) async throws -> LocalNoteContent
    func create(id: String, title: String, text: String) async throws -> LocalNoteContent
    func append(id: String, text: String, expectedRevision: String) async throws -> LocalNoteContent
}

public extension NotesBackend {
    var isSimulation: Bool { false }
}

public actor LocalNotesCoordinator: CommandAdapter {
    public nonisolated let supportedActions: Set<String> = ["note.list", "note.read", "note.create", "note.append"]
    public nonisolated let isSimulation: Bool
    private let backend: any NotesBackend
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(backend: any NotesBackend) {
        self.backend = backend
        self.isSimulation = backend.isSimulation
    }

    public func enable() async throws { try await backend.enable() }
    public func isEnabled() async -> Bool { await backend.isEnabled() }

    func execute(_ command: BridgeCommand) async throws -> AdapterExecution {
        await acquire()
        defer { release() }
        try ActionParameterValidator().validate(action: command.action, parameters: command.parameters, protocolVersion: "1.2")
        guard case .object(let params) = command.parameters else { throw StableErrorCode.invalidSchema }
        guard await backend.isEnabled() else { throw StableErrorCode.capabilityDisabled }

        switch command.action {
        case "note.list":
            let query: String
            if case .string(let value)? = params["query"] { query = value } else { query = "" }
            let notes = try await backend.list(query: query)
            return .succeeded(summary: .object(["notes": .array(notes.map(Self.summary))]))
        case "note.read":
            guard case .string(let id)? = params["note_id"] else { throw StableErrorCode.invalidSchema }
            let note = try await backend.read(id: id)
            guard note.id == id else { throw StableErrorCode.resultUnverifiable }
            return .succeeded(summary: .object(["note": Self.content(note)]))
        case "note.create":
            guard case .string(let id)? = params["note_id"],
                  case .string(let title)? = params["title"],
                  case .string(let text)? = params["text"] else { throw StableErrorCode.invalidSchema }
            do { _ = try await backend.create(id: id, title: title, text: text) }
            catch let error as StableErrorCode { throw error }
            catch { throw StableErrorCode.resultUnverifiable }
            let observed: LocalNoteContent
            do { observed = try await backend.read(id: id) }
            catch { throw StableErrorCode.resultUnverifiable }
            guard observed.id == id, observed.title == title,
                  LocalNotesText.canonical(observed.text) == LocalNotesText.canonical(title + "\n" + text) else {
                throw StableErrorCode.resultUnverifiable
            }
            return .succeeded(summary: .object(["note": Self.content(observed),
                                                "notes": .array([Self.summary(.init(id: observed.id, title: observed.title))])]))
        case "note.append":
            guard case .string(let id)? = params["note_id"],
                  case .string(let text)? = params["text"],
                  case .string(let revision)? = params["expected_revision"] else { throw StableErrorCode.invalidSchema }
            let before = try await backend.read(id: id)
            guard before.id == id, before.canAppend, before.revision == revision else {
                throw StableErrorCode.invalidSchema
            }
            do { _ = try await backend.append(id: id, text: text, expectedRevision: revision) }
            catch let error as StableErrorCode { throw error }
            catch { throw StableErrorCode.resultUnverifiable }
            let observed: LocalNoteContent
            do { observed = try await backend.read(id: id) }
            catch { throw StableErrorCode.resultUnverifiable }
            guard observed.id == id, observed.title == before.title,
                  LocalNotesText.canonical(observed.text) == LocalNotesText.canonical(before.text + "\n" + text) else {
                throw StableErrorCode.resultUnverifiable
            }
            return .succeeded(summary: .object(["note": Self.content(observed),
                                                "notes": .array([Self.summary(.init(id: observed.id, title: observed.title))])]))
        default: throw StableErrorCode.capabilityDisabled
        }
    }

    private static func summary(_ note: LocalNoteSummary) -> JSONValue {
        .object(["id": .string(note.id), "title": .string(note.title)])
    }

    private static func content(_ note: LocalNoteContent) -> JSONValue {
        .object(["id": .string(note.id), "title": .string(note.title), "text": .string(note.text),
                 "revision": .string(note.revision), "can_append": .bool(note.canAppend)])
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
}
