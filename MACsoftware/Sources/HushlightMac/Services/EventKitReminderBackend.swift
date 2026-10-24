import BridgeCore
import EventKit
import Foundation

enum ReminderAccessError: LocalizedError {
    case requiresApp, listNotEnabled, noWritableSource, unavailable
    var errorDescription: String? {
        switch self {
        case .requiresApp: "请在开发版 App 中使用提醒事项。"
        case .listNotEnabled: "请先启用提醒事项并创建专用提醒列表。"
        case .noWritableSource: "没有可用于提醒事项的默认账户，请先在系统提醒事项中配置。"
        case .unavailable: "无法核对提醒事项，请检查权限、列表和同步状态。"
        }
    }
}

/// Never fetches outside the explicitly enabled calendar. Only marked Bridge items are exposed.
actor EventKitReminderBackend: ReminderBackend {
    nonisolated let isSimulation = false
    private let store: EKEventStore?
    private let defaults: UserDefaults
    private let listKey = "bridge.reminders.calendarIdentifier"
    private static let markerPrefix = "hushlight-reminder://entry/"

    init() {
        store = Bundle.main.bundleIdentifier == "com.hushlight.bridge.mac" ? EKEventStore() : nil
        defaults = .standard
    }

    func authorizationStatus() async -> ReminderAuthorization {
        guard store != nil else { return .notDetermined }
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        default: return .denied
        }
    }

    /// Resolves only the saved list; never creates or adopts a replacement.
    func scopeIdentifier() async -> String? {
        guard let (_, calendar) = try? await context() else { return nil }
        return calendar.calendarIdentifier
    }

    func requestAuthorization() async throws -> Bool {
        guard let store else { throw ReminderAccessError.requiresApp }
        switch await authorizationStatus() {
        case .authorized: return true
        case .denied: return false
        case .notDetermined: break
        }
        if #available(macOS 14.0, *) {
            return try await store.requestFullAccessToReminders()
        } else {
            return try await store.requestAccess(to: .reminder)
        }
    }

    func enableDedicatedList() async throws {
        let store = try await authorizedStore()
        if let identifier = defaults.string(forKey: listKey) {
            guard let existing = store.calendar(withIdentifier: identifier) else {
                throw ReminderAccessError.listNotEnabled
            }
            guard existing.allowedEntityTypes.contains(.reminder), existing.allowsContentModifications else {
                throw ReminderAccessError.unavailable
            }
            return
        }
        // No fuzzy matching by name: another calendar with the same name is never silently adopted.
        guard let source = store.defaultCalendarForNewReminders()?.source else {
            throw ReminderAccessError.noWritableSource
        }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = "Agent 工作台"
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        guard let saved = store.calendar(withIdentifier: calendar.calendarIdentifier),
              saved.allowsContentModifications else { throw ReminderAccessError.unavailable }
        defaults.set(saved.calendarIdentifier, forKey: listKey)
    }

    func list() async throws -> [LocalReminderRecord] {
        let (store, calendar) = try await context()
        let entries = try await lookups(in: calendar, store: store)
        let ids = entries.compactMap(\.bridgeID)
        guard Set(ids).count == ids.count else { throw ReminderAccessError.unavailable }
        return try entries.compactMap { info in
            guard let id = info.bridgeID else { return nil }
            return try record(try item(info: info, calendarID: calendar.calendarIdentifier, store: store), id: id)
        }.sorted { $0.dueAt < $1.dueAt }
    }

    func create(id: String, title: String, dueAt: Date) async throws -> LocalReminderRecord {
        let (store, calendar) = try await context()
        let entries = try await lookups(in: calendar, store: store)
        let existing = entries.filter { $0.bridgeID == id }
        guard existing.count <= 1 else { throw ReminderAccessError.unavailable }
        if let info = existing.first {
            let prior = try record(try item(info: info, calendarID: calendar.calendarIdentifier, store: store), id: id)
            guard prior.title == title, abs(prior.dueAt.timeIntervalSince(dueAt)) < 1 else {
                throw ReminderAccessError.unavailable
            }
            return prior
        }
        guard entries.count < 256 else { throw ReminderAccessError.unavailable }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = title
        reminder.url = URL(string: Self.markerPrefix + id)
        reminder.dueDateComponents = Self.components(dueAt)
        reminder.alarms = [EKAlarm(absoluteDate: dueAt)]
        try store.save(reminder, commit: true)
        guard let saved = store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder else {
            throw ReminderAccessError.unavailable
        }
        let result = try record(saved, id: id)
        guard saved.calendar.calendarIdentifier == calendar.calendarIdentifier,
              saved.url?.absoluteString == Self.markerPrefix + id,
              result.title == title, abs(result.dueAt.timeIntervalSince(dueAt)) < 1 else {
            throw ReminderAccessError.unavailable
        }
        return result
    }

    func update(id: String, title: String?, dueAt: Date?) async throws -> LocalReminderRecord {
        let (store, calendar) = try await context()
        let reminder = try await uniqueItem(id: id, calendar: calendar, store: store)
        if let title { reminder.title = title }
        if let dueAt {
            reminder.dueDateComponents = Self.components(dueAt)
            reminder.alarms = [EKAlarm(absoluteDate: dueAt)]
        }
        try store.save(reminder, commit: true)
        let result = try record(try reloaded(reminder, calendar: calendar, store: store), id: id)
        guard title == nil || result.title == title,
              dueAt == nil || abs(result.dueAt.timeIntervalSince(dueAt!)) < 1 else {
            throw ReminderAccessError.unavailable
        }
        return result
    }

    func setCompleted(id: String, completed: Bool) async throws -> LocalReminderRecord {
        let (store, calendar) = try await context()
        let reminder = try await uniqueItem(id: id, calendar: calendar, store: store)
        reminder.isCompleted = completed
        try store.save(reminder, commit: true)
        let result = try record(try reloaded(reminder, calendar: calendar, store: store), id: id)
        guard result.isCompleted == completed else { throw ReminderAccessError.unavailable }
        return result
    }

    func cancel(id: String) async throws {
        let (store, calendar) = try await context()
        let matches = try await lookups(in: calendar, store: store).filter { $0.bridgeID == id }
        guard matches.count <= 1 else { throw ReminderAccessError.unavailable }
        guard let info = matches.first else { return }
        let reminder = try item(info: info, calendarID: calendar.calendarIdentifier, store: store)
        try store.remove(reminder, commit: true)
        let remaining = try await lookups(in: calendar, store: store)
        guard !remaining.contains(where: { $0.bridgeID == id }) else { throw ReminderAccessError.unavailable }
    }

    private func authorizedStore() async throws -> EKEventStore {
        guard let store else { throw ReminderAccessError.requiresApp }
        guard await authorizationStatus() == .authorized else { throw ReminderAccessError.unavailable }
        return store
    }

    private func context() async throws -> (EKEventStore, EKCalendar) {
        let store = try await authorizedStore()
        guard let id = defaults.string(forKey: listKey), let calendar = store.calendar(withIdentifier: id),
              calendar.allowedEntityTypes.contains(.reminder), calendar.allowsContentModifications else {
            throw ReminderAccessError.listNotEnabled
        }
        return (store, calendar)
    }

    private struct Lookup: Sendable {
        let nativeID: String
        let bridgeID: String?
    }

    private func lookups(in calendar: EKCalendar, store: EKEventStore) async throws -> [Lookup] {
        let predicate = store.predicateForReminders(in: [calendar])
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<[Lookup]?, Never>) in
            store.fetchReminders(matching: predicate) { items in
                continuation.resume(returning: items.map { reminders in
                    reminders.map { reminder in
                        let raw = reminder.url?.absoluteString ?? ""
                        let marker = raw.hasPrefix(Self.markerPrefix) ? String(raw.dropFirst(Self.markerPrefix.count)) : nil
                        return Lookup(nativeID: reminder.calendarItemIdentifier, bridgeID: marker)
                    }
                })
            }
        }
        guard let result, result.count <= 256,
              defaults.string(forKey: listKey) == calendar.calendarIdentifier,
              await authorizationStatus() == .authorized else { throw ReminderAccessError.unavailable }
        return result
    }

    private func item(info: Lookup, calendarID: String, store: EKEventStore) throws -> EKReminder {
        guard let reminder = store.calendarItem(withIdentifier: info.nativeID) as? EKReminder,
              reminder.calendar.calendarIdentifier == calendarID,
              let id = info.bridgeID, reminder.url?.absoluteString == Self.markerPrefix + id else {
            throw ReminderAccessError.unavailable
        }
        return reminder
    }

    private func uniqueItem(id: String, calendar: EKCalendar, store: EKEventStore) async throws -> EKReminder {
        let matches = try await lookups(in: calendar, store: store).filter { $0.bridgeID == id }
        guard matches.count == 1, let info = matches.first else { throw ReminderAccessError.unavailable }
        return try item(info: info, calendarID: calendar.calendarIdentifier, store: store)
    }

    private func reloaded(_ reminder: EKReminder, calendar: EKCalendar, store: EKEventStore) throws -> EKReminder {
        guard let saved = store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder,
              saved.calendar.calendarIdentifier == calendar.calendarIdentifier,
              saved.url == reminder.url else { throw ReminderAccessError.unavailable }
        return saved
    }

    private func record(_ reminder: EKReminder, id: String) throws -> LocalReminderRecord {
        guard let components = reminder.dueDateComponents,
              let date = components.calendar?.date(from: components) ?? Calendar.current.date(from: components) else {
            throw ReminderAccessError.unavailable
        }
        return LocalReminderRecord(id: id, title: reminder.title ?? "", dueAt: date, isCompleted: reminder.isCompleted)
    }

    private static func components(_ date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var result = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        result.calendar = calendar
        result.timeZone = calendar.timeZone
        return result
    }
}
