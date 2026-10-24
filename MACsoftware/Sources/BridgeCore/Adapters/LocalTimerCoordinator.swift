import Foundation

public struct LocalTimerRecord: Codable, Equatable, Sendable {
    public let id: String
    public let fireAt: Date
    public let label: String

    public init(id: String, fireAt: Date, label: String) {
        self.id = id
        self.fireAt = fireAt
        self.label = label
    }
}

public enum TimerNotificationAuthorization: Sendable {
    case notDetermined
    case authorized
    case denied
}

public protocol TimerNotificationScheduling: Sendable {
    var isSimulation: Bool { get }
    func authorizationStatus() async -> TimerNotificationAuthorization
    /// Replaces the pending notification with the stable timer ID.
    func schedule(_ timer: LocalTimerRecord) async throws
    func cancel(timerID: String) async throws
}

public extension TimerNotificationScheduling {
    var isSimulation: Bool { false }
}

public enum LocalTimerStorageError: Error, Equatable, Sendable {
    case invalidLocation
    case corruptState
    case reconciliationRequired
}

/// Desired state is persisted before a scheduler call. An interrupted call is reconciled on restore.
public actor LocalTimerCoordinator: CommandAdapter {
    public nonisolated let supportedActions: Set<String> = ["timer.create", "timer.update", "timer.cancel"]
    public nonisolated let isSimulation: Bool
    private static let capacity = 128
    private let storageURL: URL
    private let scheduler: any TimerNotificationScheduling
    private let now: @Sendable () -> Date
    private var state: StoredState
    private var needsRestore = true
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(storageURL: URL, scheduler: any TimerNotificationScheduling,
                now: @escaping @Sendable () -> Date = Date.init) throws {
        guard storageURL.isFileURL, storageURL.pathExtension == "json",
              storageURL.deletingLastPathComponent().lastPathComponent == "Bridge" else {
            throw LocalTimerStorageError.invalidLocation
        }
        self.storageURL = storageURL
        self.scheduler = scheduler
        self.isSimulation = scheduler.isSimulation
        self.now = now
        if FileManager.default.fileExists(atPath: storageURL.path) {
            let data = try Data(contentsOf: storageURL)
            guard let decoded = try? JSONDecoder().decode(StoredState.self, from: data),
                  decoded.version == 1, decoded.timers.count <= Self.capacity,
                  Set(decoded.timers.map(\.id)).count == decoded.timers.count,
                  Set(decoded.pending.map(\.id)).count == decoded.pending.count,
                  decoded.pending.count <= Self.capacity,
                  decoded.timers.allSatisfy(Self.validRecord),
                  decoded.pending.allSatisfy({ pending in
                      let exists = decoded.timers.contains { $0.id == pending.id }
                      return pending.kind == .schedule ? exists : !exists
                  }) else {
                throw LocalTimerStorageError.corruptState
            }
            state = decoded
        } else {
            state = StoredState()
        }
    }

    public func restore() async throws {
        await acquire()
        defer { release() }
        try await reconcile()
    }

    public func timers() async throws -> [LocalTimerRecord] {
        await acquire()
        defer { release() }
        try pruneExpired()
        if needsRestore, await scheduler.authorizationStatus() == .authorized {
            do { try await reconcile() }
            catch StableErrorCode.permissionRequired { /* Grant changed while reconciling; keep desired state visible. */ }
        }
        return state.timers.filter { $0.fireAt > now() }.sorted { $0.fireAt < $1.fireAt }
    }

    func execute(_ command: BridgeCommand) async throws -> AdapterExecution {
        await acquire()
        defer { release() }
        try ActionParameterValidator().validate(action: command.action, parameters: command.parameters)
        guard case .object(let params) = command.parameters,
              case .string(let id)? = params["timer_id"] else { throw StableErrorCode.invalidSchema }
        if command.action == "timer.cancel",
           !state.timers.contains(where: { $0.id == id }),
           !state.pending.contains(where: { $0.id == id }) {
            return .succeeded()
        }
        do {
            if needsRestore, command.action != "timer.cancel" { try await reconcile() }
        } catch let error as StableErrorCode {
            throw error
        } catch LocalTimerStorageError.reconciliationRequired {
            return .init(status: .unknown, stableError: .resultUnverifiable, summary: .emptyObject)
        } catch {
            return .init(status: .failed, stableError: .internalError, summary: .emptyObject)
        }
        do { try pruneExpired() } catch {
            return .init(status: .failed, stableError: .internalError, summary: .emptyObject)
        }
        if command.action != "timer.cancel" {
            guard await scheduler.authorizationStatus() == .authorized else {
                throw StableErrorCode.permissionRequired
            }
        }
        let current = state.timers.first { $0.id == id }
        let next: LocalTimerRecord?
        switch command.action {
        case "timer.create":
            guard current == nil else { throw StableErrorCode.invalidSchema }
            guard state.timers.count < Self.capacity else { throw StableErrorCode.capabilityDisabled }
            guard case .string(let fireAtString)? = params["fire_at"],
                  case .string(let label)? = params["label"],
                  let fireAt = Self.parseDate(fireAtString), fireAt > now() else {
                throw StableErrorCode.invalidSchema
            }
            next = LocalTimerRecord(id: id, fireAt: Self.roundUpToSecond(fireAt), label: label)
        case "timer.update":
            guard let current, current.fireAt > now() else { throw StableErrorCode.invalidSchema }
            let fireAt: Date
            if case .string(let raw)? = params["fire_at"] {
                guard let date = Self.parseDate(raw), date > now() else { throw StableErrorCode.invalidSchema }
                fireAt = date
            } else { fireAt = current.fireAt }
            let label: String
            if case .string(let value)? = params["label"] { label = value } else { label = current.label }
            next = LocalTimerRecord(id: id, fireAt: Self.roundUpToSecond(fireAt), label: label)
        case "timer.cancel":
            guard current != nil || state.pending.contains(where: { $0.id == id }) else { return .succeeded() }
            next = nil
        default:
            throw StableErrorCode.capabilityDisabled
        }
        var desired = state
        desired.timers.removeAll { $0.id == id }
        if let next { desired.timers.append(next) }
        desired.pending.removeAll { $0.id == id }
        desired.pending.append(Pending(id: id, kind: next == nil ? .cancel : .schedule))
        do { try persist(desired); state = desired } catch {
            return .init(status: .failed, stableError: .internalError, summary: .emptyObject)
        }
        do {
            if let next {
                guard next.fireAt > now() else { throw LocalTimerStorageError.reconciliationRequired }
                try await scheduler.schedule(next)
            } else {
                try await scheduler.cancel(timerID: id)
            }
        } catch {
            needsRestore = true
            return .init(status: .unknown, stableError: .resultUnverifiable, summary: .emptyObject)
        }
        desired.pending.removeAll { $0.id == id }
        do { try persist(desired); state = desired } catch {
            needsRestore = true
            return .init(status: .unknown, stableError: .resultUnverifiable, summary: .emptyObject)
        }
        return .succeeded()
    }

    private func reconcile() async throws {
        // Do not touch notifications while permission is absent. Keep durable desired state for later retry.
        guard await scheduler.authorizationStatus() == .authorized else {
            throw StableErrorCode.permissionRequired
        }
        try pruneExpired()
        var next = state
        // Earlier versions stored fractional seconds while UNCalendarNotificationTrigger used whole seconds.
        // Once that lower second has begun, delivery may already have happened: never replay it.
        let current = now().timeIntervalSince1970
        for item in state.timers {
            let raw = item.fireAt.timeIntervalSince1970
            guard raw != floor(raw) else { continue }
            if floor(raw) <= current {
                next.timers.removeAll { $0.id == item.id }
                next.pending.removeAll { $0.id == item.id && $0.kind == .schedule }
            } else if let index = next.timers.firstIndex(where: { $0.id == item.id }) {
                next.timers[index] = LocalTimerRecord(id: item.id, fireAt: Self.roundUpToSecond(item.fireAt), label: item.label)
            }
        }
        if next != state { try persist(next); state = next }
        // Stable scheduler IDs make this safe even if the previous process stopped after scheduling.
        for item in state.timers {
            guard item.fireAt > now() else { continue }
            do { try await scheduler.schedule(item) } catch {
                needsRestore = true
                throw LocalTimerStorageError.reconciliationRequired
            }
        }
        for pending in state.pending where pending.kind == .cancel {
            do { try await scheduler.cancel(timerID: pending.id) } catch {
                needsRestore = true
                throw LocalTimerStorageError.reconciliationRequired
            }
        }
        if !state.pending.isEmpty {
            next = state
            next.pending = []
            try persist(next)
            state = next
        }
        needsRestore = false
    }

    private func persist(_ next: StoredState) throws {
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        try data.write(to: storageURL, options: .atomic)
    }

    private func pruneExpired() throws {
        let expired = Set(state.timers.filter { $0.fireAt <= now() }.map(\.id))
        guard !expired.isEmpty else { return }
        var next = state
        next.timers.removeAll { expired.contains($0.id) }
        next.pending.removeAll { expired.contains($0.id) && $0.kind == .schedule }
        try persist(next)
        state = next
    }

    private static func roundUpToSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: ceil(date.timeIntervalSince1970))
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func validRecord(_ record: LocalTimerRecord) -> Bool {
        !record.id.isEmpty && record.id.count <= 128 &&
        record.id.unicodeScalars.allSatisfy { scalar in
            (65...90).contains(scalar.value) || (97...122).contains(scalar.value) ||
            (48...57).contains(scalar.value) || [46, 95, 58, 45].contains(scalar.value)
        } && !record.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && record.label.count <= 256 &&
        record.fireAt.timeIntervalSince1970.isFinite
    }
}

private struct StoredState: Codable, Equatable {
    var version = 1
    var timers: [LocalTimerRecord] = []
    var pending: [Pending] = []
}

private struct Pending: Codable, Equatable {
    enum Kind: String, Codable { case schedule, cancel }
    let id: String
    let kind: Kind
}
