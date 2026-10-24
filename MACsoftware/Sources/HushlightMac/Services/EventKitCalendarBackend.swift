import BridgeCore
import CryptoKit
import EventKit
import Foundation

enum CalendarAccessError: Error, LocalizedError {
    case requiresApp, permissionRequired, calendarNotEnabled, noWritableSource
    case invalidInput, notOwned, uncertainWrite, unavailable, corruptLedger

    var errorDescription: String? {
        switch self {
        case .requiresApp: "请在 Orbit 智轨 App 中使用日历。"
        case .permissionRequired: "请先在 App 中启用日历权限。"
        case .calendarNotEnabled: "请先启用专用日历。"
        case .noWritableSource: "没有可写的日历账户。"
        case .invalidInput: "日历事件参数无效。"
        case .notOwned: "只能修改由 Agent 工作台创建的专用日历事件。"
        case .uncertainWrite: "上次日历写入结果不确定，请人工核对，不能自动重试。"
        case .unavailable: "无法核对日历事件，请检查日历权限和同步状态。"
        case .corruptLedger: "日历写入记录损坏，已停止写入。"
        }
    }
}

struct CalendarEventRecord: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let sourceURL: URL?
}

/// Persists only identifiers, operation fingerprints and write state. The calendar owns event content.
private struct CalendarWriteEntry: Codable {
    enum State: String, Codable { case pending, confirmed, unknown }
    let id: String
    let operation: String
    let fingerprint: String
    var nativeID: String?
    var revision: String?
    var state: State
}

/// Every read and write is constrained to the calendar created by this backend.
/// Authorization is requested only by the explicit requestAuthorization call.
actor EventKitCalendarBackend {
    private let store: EKEventStore?
    private let defaults: UserDefaults
    private let ledgerURL: URL
    private let calendarKey = "bridge.events.calendarIdentifier"
    private static let markerPrefix = "hushlight-calendar://entry/"
    private static let sourcePrefix = "Source: "
    private var ledger: [CalendarWriteEntry] = []
    private var ledgerCorrupt = false

    init(defaultsSuiteName: String? = nil,
         ledgerURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hushlight/Bridge/calendar-writes.json"),
         store: EKEventStore? = Bundle.main.bundleIdentifier == "com.hushlight.bridge.mac" ? EKEventStore() : nil) {
        self.store = store
        self.defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.ledgerURL = ledgerURL
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            do { ledger = try JSONDecoder().decode([CalendarWriteEntry].self, from: Data(contentsOf: ledgerURL)) }
            catch { ledgerCorrupt = true }
        } else if self.defaults.string(forKey: calendarKey) != nil {
            // A saved scope without its write ledger cannot prove which events we own.
            ledgerCorrupt = true
        }
    }

    func authorizationStatus() -> EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    /// Safe for status snapshots: never requests authorization or creates a calendar.
    func scopeIdentifier() -> String? {
        guard !ledgerCorrupt, store != nil, hasFullAccess(),
              let id = defaults.string(forKey: calendarKey),
              let calendar = store?.calendar(withIdentifier: id),
              calendar.allowedEntityTypes.contains(.event), calendar.allowsContentModifications else { return nil }
        return id
    }

    func requestAuthorization() async throws -> Bool {
        guard let store else { throw CalendarAccessError.requiresApp }
        if #available(macOS 14.0, *) { return try await store.requestFullAccessToEvents() }
        return try await store.requestAccess(to: .event)
    }

    func enableDedicatedCalendar() async throws -> String {
        guard !ledgerCorrupt else { throw CalendarAccessError.corruptLedger }
        let store = try authorizedStore()
        if let id = scopeIdentifier() { return id }
        guard defaults.string(forKey: calendarKey) == nil else { throw CalendarAccessError.unavailable }
        guard let source = store.defaultCalendarForNewEvents?.source else { throw CalendarAccessError.noWritableSource }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Agent 工作台"
        calendar.source = source
        try persistLedger()
        try store.saveCalendar(calendar, commit: true)
        guard let saved = store.calendar(withIdentifier: calendar.calendarIdentifier),
              saved.allowsContentModifications else { throw CalendarAccessError.unavailable }
        defaults.set(saved.calendarIdentifier, forKey: calendarKey)
        return saved.calendarIdentifier
    }

    func list(start: Date, end: Date) throws -> [CalendarEventRecord] {
        let (store, calendar) = try context()
        try Self.validRange(start, end)
        guard !ledgerCorrupt else { throw CalendarAccessError.corruptLedger }
        let owned = Set(ledger.filter { $0.state == .confirmed && $0.operation != "cancel" }.map(\.id))
        return try queriedEvents(store: store, calendar: calendar, start: start, end: end)
            .compactMap { event in
                guard let id = Self.bridgeID(event), owned.contains(id) else { return nil }
                return try record(event, id: id)
            }
            .sorted { $0.start < $1.start }
    }

    /// Counts every event in the owned calendar, including manual entries. No other calendars are queried.
    func hasConflict(start: Date, end: Date, excluding id: String? = nil) throws -> Bool {
        let (store, calendar) = try context()
        try Self.validRange(start, end)
        return try queriedEvents(store: store, calendar: calendar, start: start, end: end)
            .contains { event in
                event.startDate < end && event.endDate > start && (id == nil || Self.bridgeID(event) != id)
            }
    }

    func create(id: String, title: String, start: Date, end: Date, sourceURL: URL? = nil) throws -> CalendarEventRecord {
        let (store, calendar) = try context()
        try Self.valid(id: id, title: title, start: start, end: end, sourceURL: sourceURL)
        let fingerprint = Self.fingerprint([id, title, String(start.timeIntervalSince1970), String(end.timeIntervalSince1970), sourceURL?.absoluteString ?? ""])
        if let entry = ledger.first(where: { $0.id == id }) {
            guard entry.operation == "create", entry.fingerprint == fingerprint, entry.state == .confirmed,
                  let nativeID = entry.nativeID else { throw CalendarAccessError.uncertainWrite }
            let saved = try ownedEvent(nativeID: nativeID, id: id, calendar: calendar, store: store)
            guard entry.revision == Self.revision(saved) else { throw CalendarAccessError.uncertainWrite }
            return try record(saved, id: id)
        }
        guard try !queriedEvents(store: store, calendar: calendar, start: start, end: end)
            .contains(where: { Self.bridgeID($0) == id }) else { throw CalendarAccessError.uncertainWrite }
        try beginWrite(id: id, operation: "create", fingerprint: fingerprint, nativeID: nil)
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = end
        event.url = URL(string: Self.markerPrefix + id)
        if let sourceURL { event.notes = Self.sourcePrefix + sourceURL.absoluteString }
        do {
            try store.save(event, span: .thisEvent, commit: true)
            let saved = try ownedEvent(nativeID: event.eventIdentifier, id: id, calendar: calendar, store: store)
            let result = try record(saved, id: id)
            guard result.title == title, result.start == start, result.end == end,
                  result.sourceURL == sourceURL else { throw CalendarAccessError.unavailable }
            try finishWrite(id: id, nativeID: saved.eventIdentifier, revision: Self.revision(saved))
            return result
        } catch {
            try? markUnknown(id: id)
            throw CalendarAccessError.uncertainWrite
        }
    }

    func update(id: String, title: String? = nil, start: Date? = nil, end: Date? = nil) throws -> CalendarEventRecord {
        let (store, calendar) = try context()
        guard let entry = ledger.first(where: { $0.id == id }), entry.state == .confirmed,
              entry.operation != "cancel", let nativeID = entry.nativeID else { throw CalendarAccessError.notOwned }
        let event = try ownedEvent(nativeID: nativeID, id: id, calendar: calendar, store: store)
        guard entry.revision == Self.revision(event) else { throw CalendarAccessError.uncertainWrite }
        let nextTitle = title ?? event.title ?? ""
        guard let nextStart = start ?? event.startDate, let nextEnd = end ?? event.endDate else {
            throw CalendarAccessError.unavailable
        }
        try Self.valid(id: id, title: nextTitle, start: nextStart, end: nextEnd, sourceURL: nil)
        let fingerprint = Self.fingerprint([id, nextTitle, String(nextStart.timeIntervalSince1970), String(nextEnd.timeIntervalSince1970)])
        if entry.operation == "update", entry.fingerprint == fingerprint {
            return try record(event, id: id)
        }
        try beginWrite(id: id, operation: "update", fingerprint: fingerprint, nativeID: nativeID)
        event.title = nextTitle
        event.startDate = nextStart
        event.endDate = nextEnd
        do {
            try store.save(event, span: .thisEvent, commit: true)
            let saved = try ownedEvent(nativeID: nativeID, id: id, calendar: calendar, store: store)
            let result = try record(saved, id: id)
            guard result.title == nextTitle, result.start == nextStart, result.end == nextEnd else { throw CalendarAccessError.unavailable }
            try finishWrite(id: id, nativeID: nativeID, revision: Self.revision(saved))
            return result
        } catch {
            try? markUnknown(id: id)
            throw CalendarAccessError.uncertainWrite
        }
    }

    func cancel(id: String) throws {
        let (store, calendar) = try context()
        if let prior = ledger.first(where: { $0.id == id }), prior.operation == "cancel", prior.state == .confirmed {
            return
        }
        guard let entry = ledger.first(where: { $0.id == id }), entry.state == .confirmed,
              let nativeID = entry.nativeID else { throw CalendarAccessError.notOwned }
        let event = try ownedEvent(nativeID: nativeID, id: id, calendar: calendar, store: store)
        guard entry.revision == Self.revision(event) else { throw CalendarAccessError.uncertainWrite }
        try beginWrite(id: id, operation: "cancel", fingerprint: Self.fingerprint([id, nativeID]), nativeID: nativeID)
        do {
            try store.remove(event, span: .thisEvent, commit: true)
            guard store.event(withIdentifier: nativeID) == nil else { throw CalendarAccessError.unavailable }
            try finishWrite(id: id, nativeID: nativeID, revision: nil)
        } catch {
            try? markUnknown(id: id)
            throw CalendarAccessError.uncertainWrite
        }
    }

    private func authorizedStore() throws -> EKEventStore {
        guard let store else { throw CalendarAccessError.requiresApp }
        guard hasFullAccess() else { throw CalendarAccessError.permissionRequired }
        return store
    }

    private func hasFullAccess() -> Bool {
        let status = authorizationStatus()
        if #available(macOS 14.0, *) { return status == .fullAccess || status == .authorized }
        return status == .authorized
    }

    private func context() throws -> (EKEventStore, EKCalendar) {
        guard !ledgerCorrupt else { throw CalendarAccessError.corruptLedger }
        let store = try authorizedStore()
        guard let id = scopeIdentifier(), let calendar = store.calendar(withIdentifier: id) else {
            throw CalendarAccessError.calendarNotEnabled
        }
        return (store, calendar)
    }

    private func queriedEvents(store: EKEventStore, calendar: EKCalendar, start: Date, end: Date) throws -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        let events = store.events(matching: predicate)
        guard events.count <= 512, scopeIdentifier() == calendar.calendarIdentifier else { throw CalendarAccessError.unavailable }
        return events
    }

    private func ownedEvent(nativeID: String?, id: String, calendar: EKCalendar, store: EKEventStore) throws -> EKEvent {
        guard let nativeID, let event = store.event(withIdentifier: nativeID),
              event.calendar.calendarIdentifier == calendar.calendarIdentifier,
              Self.bridgeID(event) == id else { throw CalendarAccessError.unavailable }
        return event
    }

    private func record(_ event: EKEvent, id: String) throws -> CalendarEventRecord {
        guard let start = event.startDate, let end = event.endDate else { throw CalendarAccessError.unavailable }
        let source = event.notes?.hasPrefix(Self.sourcePrefix) == true
            ? URL(string: String(event.notes!.dropFirst(Self.sourcePrefix.count))) : nil
        return CalendarEventRecord(id: id, title: event.title ?? "", start: start, end: end, sourceURL: source)
    }

    private static func bridgeID(_ event: EKEvent) -> String? {
        guard let raw = event.url?.absoluteString, raw.hasPrefix(markerPrefix) else { return nil }
        return String(raw.dropFirst(markerPrefix.count))
    }

    private static func validRange(_ start: Date, _ end: Date) throws {
        guard start < end, end.timeIntervalSince(start) <= 31 * 86_400 else { throw CalendarAccessError.invalidInput }
    }

    static func valid(id: String, title: String, start: Date, end: Date, sourceURL: URL?) throws {
        guard !id.isEmpty, id.count <= 128, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }),
              !title.isEmpty, title.count <= 512, start < end,
              end.timeIntervalSince(start) <= 31 * 86_400,
              sourceURL == nil || (sourceURL!.absoluteString.count <= 2048 &&
                (sourceURL?.scheme == "https" || Self.validMailEvidence(sourceURL!))) else {
            throw CalendarAccessError.invalidInput
        }
    }

    private static func validMailEvidence(_ url: URL) -> Bool {
        guard url.scheme == "workbench-source", url.host == "mail", url.user == nil,
              url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { return false }
        let parts = url.path.dropFirst().split(separator: ".")
        guard parts.count == 3, parts[0] == "mail", parts[1].count == 64,
              parts[1].allSatisfy({ $0.isHexDigit }),
              let number = UInt64(parts[2]), number > 0, String(number) == parts[2] else { return false }
        return true
    }

    private static func fingerprint(_ values: [String]) -> String {
        let data = try! JSONEncoder().encode(values)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func revision(_ event: EKEvent) -> String {
        let alarms = (event.alarms ?? []).map { alarm in
            [String(alarm.relativeOffset), String(alarm.absoluteDate?.timeIntervalSince1970 ?? 0),
             String(alarm.proximity.rawValue), alarm.structuredLocation?.title ?? ""].joined(separator: "\u{1f}")
        }.sorted().joined(separator: "\u{1e}")
        let attendees = (event.attendees ?? []).map { $0.url.absoluteString }.sorted().joined(separator: "\u{1e}")
        let recurrence = (event.recurrenceRules ?? []).map(\.description).sorted().joined(separator: "\u{1e}")
        return fingerprint([event.title ?? "", String(event.startDate?.timeIntervalSince1970 ?? 0),
                     String(event.endDate?.timeIntervalSince1970 ?? 0), event.url?.absoluteString ?? "",
                     event.notes ?? "", String(event.isAllDay), event.location ?? "", alarms,
                     attendees, recurrence, String(event.lastModifiedDate?.timeIntervalSince1970 ?? 0)])
    }

    func beginWrite(id: String, operation: String, fingerprint: String, nativeID: String?) throws {
        guard !ledgerCorrupt else { throw CalendarAccessError.corruptLedger }
        guard !ledger.contains(where: { $0.id == id && $0.state != .confirmed }) else { throw CalendarAccessError.uncertainWrite }
        ledger.removeAll { $0.id == id }
        ledger.append(.init(id: id, operation: operation, fingerprint: fingerprint,
                            nativeID: nativeID, revision: nil, state: .pending))
        try persistLedger()
    }

    func finishWrite(id: String, nativeID: String?, revision: String?) throws {
        guard let index = ledger.firstIndex(where: { $0.id == id }) else { throw CalendarAccessError.corruptLedger }
        ledger[index].nativeID = nativeID
        ledger[index].revision = revision
        ledger[index].state = .confirmed
        try persistLedger()
    }

    func markUnknown(id: String) throws {
        guard let index = ledger.firstIndex(where: { $0.id == id }) else { throw CalendarAccessError.corruptLedger }
        ledger[index].state = .unknown
        try persistLedger()
    }

    private func persistLedger() throws {
        let directory = ledgerURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try JSONEncoder().encode(ledger).write(to: ledgerURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledgerURL.path)
    }
}
