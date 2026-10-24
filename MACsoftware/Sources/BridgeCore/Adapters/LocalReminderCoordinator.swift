import Foundation

public struct LocalReminderRecord: Equatable, Sendable {
    public let id: String
    public let title: String
    public let dueAt: Date
    public let isCompleted: Bool

    public init(id: String, title: String, dueAt: Date, isCompleted: Bool) {
        self.id = id
        self.title = title
        self.dueAt = dueAt
        self.isCompleted = isCompleted
    }
}

public enum ReminderAuthorization: Sendable {
    case notDetermined
    case authorized
    case denied
}

/// The backend owns the dedicated EventKit list, stable ID mapping, and all EventKit access.
/// `list` must throw until the dedicated list is enabled and must never return other lists.
public protocol ReminderBackend: Sendable {
    var isSimulation: Bool { get }
    func authorizationStatus() async -> ReminderAuthorization
    func requestAuthorization() async throws -> Bool
    func enableDedicatedList() async throws
    func list() async throws -> [LocalReminderRecord]
    func create(id: String, title: String, dueAt: Date) async throws -> LocalReminderRecord
    func update(id: String, title: String?, dueAt: Date?) async throws -> LocalReminderRecord
    func setCompleted(id: String, completed: Bool) async throws -> LocalReminderRecord
    func cancel(id: String) async throws
}

public extension ReminderBackend {
    var isSimulation: Bool { false }
}

/// Serializes commands across suspension points and checks readback from the dedicated list.
public actor LocalReminderCoordinator: CommandAdapter {
    public nonisolated let supportedActions: Set<String> = [
        "reminder.create", "reminder.update", "reminder.cancel", "reminder.complete"
    ]
    public nonisolated let isSimulation: Bool
    private let backend: any ReminderBackend
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(backend: any ReminderBackend) {
        self.backend = backend
        self.isSimulation = backend.isSimulation
    }

    public func reminders() async throws -> [LocalReminderRecord] {
        await acquire()
        defer { release() }
        guard await backend.authorizationStatus() == .authorized else {
            throw StableErrorCode.permissionRequired
        }
        return try await backend.list()
    }

    func execute(_ command: BridgeCommand) async throws -> AdapterExecution {
        await acquire()
        defer { release() }
        try ActionParameterValidator().validate(
            action: command.action, parameters: command.parameters,
            protocolVersion: command.action == "reminder.complete" ? "1.1" : "1.0"
        )
        guard case .object(let params) = command.parameters,
              case .string(let id)? = params["reminder_id"] else {
            throw StableErrorCode.invalidSchema
        }
        guard await backend.authorizationStatus() == .authorized else {
            throw StableErrorCode.permissionRequired
        }
        let before = try await backend.list()
        let previous = before.first { $0.id == id }
        if command.action == "reminder.cancel", previous == nil { return .succeeded(summary: Self.summary(id)) }
        switch command.action {
        case "reminder.create":
            guard previous == nil,
                  case .string(let title)? = params["title"],
                  case .string(let rawDueAt)? = params["due_at"],
                  let dueAt = Self.parseDate(rawDueAt), dueAt > Date() else {
                throw StableErrorCode.invalidSchema
            }
            do { _ = try await backend.create(id: id, title: title, dueAt: dueAt) }
            catch let error as StableErrorCode { throw error }
            catch { throw StableErrorCode.resultUnverifiable }
        case "reminder.update":
            guard previous != nil else { throw StableErrorCode.invalidSchema }
            let title: String?
            if case .string(let value)? = params["title"] { title = value } else { title = nil }
            let dueAt: Date?
            if case .string(let value)? = params["due_at"] { dueAt = Self.parseDate(value) } else { dueAt = nil }
            do { _ = try await backend.update(id: id, title: title, dueAt: dueAt) }
            catch let error as StableErrorCode { throw error }
            catch { throw StableErrorCode.resultUnverifiable }
        case "reminder.complete":
            guard previous != nil, case .bool(let completed)? = params["is_completed"] else {
                throw StableErrorCode.invalidSchema
            }
            do { _ = try await backend.setCompleted(id: id, completed: completed) }
            catch let error as StableErrorCode { throw error }
            catch { throw StableErrorCode.resultUnverifiable }
        case "reminder.cancel":
            do { try await backend.cancel(id: id) }
            catch let error as StableErrorCode { throw error }
            catch { throw StableErrorCode.resultUnverifiable }
        default:
            throw StableErrorCode.capabilityDisabled
        }
        let after: [LocalReminderRecord]
        do { after = try await backend.list() }
        catch { throw StableErrorCode.resultUnverifiable }
        let observed = after.first { $0.id == id }
        switch command.action {
        case "reminder.create":
            guard let observed, case .string(let title)? = params["title"],
                  case .string(let rawDueAt)? = params["due_at"],
                  let dueAt = Self.parseDate(rawDueAt), observed.title == title,
                  abs(observed.dueAt.timeIntervalSince(dueAt)) < 1,
                  !observed.isCompleted else { throw StableErrorCode.resultUnverifiable }
        case "reminder.update":
            guard let observed else { throw StableErrorCode.resultUnverifiable }
            if case .string(let title)? = params["title"], observed.title != title {
                throw StableErrorCode.resultUnverifiable
            }
            if case .string(let rawDueAt)? = params["due_at"],
               let dueAt = Self.parseDate(rawDueAt),
               abs(observed.dueAt.timeIntervalSince(dueAt)) >= 1 {
                throw StableErrorCode.resultUnverifiable
            }
        case "reminder.complete":
            guard let observed, case .bool(let completed)? = params["is_completed"],
                  observed.isCompleted == completed else { throw StableErrorCode.resultUnverifiable }
        case "reminder.cancel":
            guard observed == nil else { throw StableErrorCode.resultUnverifiable }
        default: break
        }
        return .succeeded(summary: Self.summary(id))
    }

    private static func summary(_ id: String) -> JSONValue {
        .object(["reminder_id": .string(id)])
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
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
