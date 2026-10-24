import Foundation
import BridgeCore

protocol BridgeService: Sendable {
    func qqChatSnapshot() async throws -> QQChatSnapshot
    func searchAndPlayQQMusic(id: String, request: QQSongRequest, authorize: @escaping @Sendable () async -> Bool) async throws -> QQSongPlayResult
    func pendingQQSong() async throws -> QQSongPending?
    func acknowledgeQQSong(_ pending: QQSongPending) async throws
    func qqMusicPlayback() async throws -> QQMusicPlayback
    func performQQMusic(_ action: QQMusicPlaybackAction, authorize: @escaping @Sendable () async -> Bool) async throws -> QQMusicPlayback
    func requestQQMusicAccess() async -> Bool
    func qqMusicStatus() async throws -> QQMusicStatus
    /// Passive system authorization only; never opens a target or requests consent.
    func systemAuthorizationStates() async -> [String: String]
    func lastAutomationWeather() async -> WeatherReport?
    func automationSnapshot() async -> AutomationSnapshot?
    func automationResources() async -> [AutomationAction: String]
    func calendarConflict(start: Date, end: Date) async throws -> Bool
    func calendarScope() async -> String?
    func enableCalendar() async throws
    func listCalendar(start: Date, end: Date) async throws -> [CalendarEventRecord]
    func createCalendarEvent(id: String, title: String, start: Date, end: Date, sourceURL: URL?) async throws -> CalendarEventRecord
    func updateCalendarEvent(id: String, title: String?, start: Date?, end: Date?) async throws -> CalendarEventRecord
    func cancelCalendarEvent(id: String) async throws
    func mailBaseline() async throws -> MailIncrementalCursor
    func pollMail(after cursor: MailIncrementalCursor) async throws -> MailIncrementalPoll
    func mailSender() async throws -> String
    func workbenchState() async throws -> WorkbenchServiceState
    func workbenchTimers() async throws -> [LocalTimerRecord]
    func workbenchReminders() async throws -> [LocalReminderRecord]
    func snapshot() async throws -> BridgeSnapshot
    func setPaused(_ paused: Bool) async throws
    func readSystemVolume() async throws -> VolumeReadback
    func requestNotificationPermission() async throws
    func createTimer(id: String, fireAt: Date, label: String) async throws -> TimerActionReadback
    func updateTimer(id: String, fireAt: Date?, label: String?) async throws -> TimerActionReadback
    func cancelTimer(id: String) async throws -> TimerActionReadback
    func enableReminders() async throws
    func createReminder(id: String, title: String, dueAt: Date) async throws -> ReminderActionReadback
    func updateReminder(id: String, title: String?, dueAt: Date?) async throws -> ReminderActionReadback
    func completeReminder(id: String, completed: Bool) async throws -> ReminderActionReadback
    func enableNotes() async throws
    func listNotes(query: String) async throws -> LocalNotesCommandResult
    func readNote(id: String) async throws -> LocalNotesCommandResult
    func createNote(id: String, title: String, text: String) async throws -> LocalNotesCommandResult
    func appendNote(id: String, text: String, expectedRevision: String) async throws -> LocalNotesCommandResult
    func readWeather(cityID: String) async throws -> LocalWeatherCommandResult
    func requestLocationPermission() async throws
    func readLocation() async throws -> LocalLocationCommandResult
    func listMailScopes() async throws -> [MailScopeOption]
    func selectedMailScope() async throws -> MailScopeKey?
    func selectMailScope(_ key: MailScopeKey) async throws
    func searchMail(query: String, unreadOnly: Bool) async throws -> LocalMailCommandResult
    func readMail(id: String) async throws -> LocalMailCommandResult
    func createMailDraft(id: String, input: MailDraftInput) async throws -> LocalMailCommandResult
    func readMailDraft(id: String) async throws -> LocalMailCommandResult
    func requestMailSend(id: String, revision: String) async throws -> LocalMailCommandResult
    func mailDraftStatus(id: String) async throws -> LocalMailCommandResult
    func mailDrafts() async throws -> [MailDraftEntry]
    func confirmMailSend(id: String, preview: MailDraftContent, authorize: @escaping @Sendable () async -> Bool) async throws -> String
}

extension BridgeService {
    func qqChatSnapshot() async throws -> QQChatSnapshot { throw BridgeServiceError.notConfigured }
    func searchAndPlayQQMusic(id: String, request: QQSongRequest, authorize: @escaping @Sendable () async -> Bool) async throws -> QQSongPlayResult { throw BridgeServiceError.notConfigured }
    func pendingQQSong() async throws -> QQSongPending? { nil }
    func acknowledgeQQSong(_ pending: QQSongPending) async throws { throw BridgeServiceError.notConfigured }

    func qqMusicPlayback() async throws -> QQMusicPlayback { throw BridgeServiceError.notConfigured }
    func performQQMusic(_ action: QQMusicPlaybackAction, authorize: @escaping @Sendable () async -> Bool) async throws -> QQMusicPlayback { throw BridgeServiceError.notConfigured }
    func requestQQMusicAccess() async -> Bool { false }
    func qqMusicStatus() async throws -> QQMusicStatus { throw BridgeServiceError.notConfigured }
    func systemAuthorizationStates() async -> [String: String] { [:] }
    func calendarConflict(start: Date, end: Date) async throws -> Bool { throw BridgeServiceError.notConfigured }
    func lastAutomationWeather() async -> WeatherReport? { nil }
    func automationSnapshot() async -> AutomationSnapshot? { nil }
    func automationResources() async -> [AutomationAction: String] { [:] }
    func calendarScope() async -> String? { nil }
    func enableCalendar() async throws { throw BridgeServiceError.notConfigured }
    func listCalendar(start: Date, end: Date) async throws -> [CalendarEventRecord] { throw BridgeServiceError.notConfigured }
    func createCalendarEvent(id: String, title: String, start: Date, end: Date, sourceURL: URL?) async throws -> CalendarEventRecord { throw BridgeServiceError.notConfigured }
    func updateCalendarEvent(id: String, title: String?, start: Date?, end: Date?) async throws -> CalendarEventRecord { throw BridgeServiceError.notConfigured }
    func cancelCalendarEvent(id: String) async throws { throw BridgeServiceError.notConfigured }
    func mailBaseline() async throws -> MailIncrementalCursor { throw BridgeServiceError.notConfigured }
    func pollMail(after cursor: MailIncrementalCursor) async throws -> MailIncrementalPoll { throw BridgeServiceError.notConfigured }
    func mailSender() async throws -> String { throw BridgeServiceError.notConfigured }

    func workbenchState() async throws -> WorkbenchServiceState {
        let value = try await snapshot()
        return WorkbenchServiceState(status: value.status.rawValue, supportedActions: [], isSimulation: false, recentActions: value.recentActions)
    }
    func workbenchTimers() async throws -> [LocalTimerRecord] { try await snapshot().timers }
    func workbenchReminders() async throws -> [LocalReminderRecord] { try await snapshot().reminders }
    func requestNotificationPermission() async throws { throw BridgeServiceError.notConfigured }
    func createTimer(id: String, fireAt: Date, label: String) async throws -> TimerActionReadback { throw BridgeServiceError.notConfigured }
    func updateTimer(id: String, fireAt: Date?, label: String?) async throws -> TimerActionReadback { throw BridgeServiceError.notConfigured }
    func cancelTimer(id: String) async throws -> TimerActionReadback { throw BridgeServiceError.notConfigured }
    func enableReminders() async throws { throw BridgeServiceError.notConfigured }
    func createReminder(id: String, title: String, dueAt: Date) async throws -> ReminderActionReadback { throw BridgeServiceError.notConfigured }
    func updateReminder(id: String, title: String?, dueAt: Date?) async throws -> ReminderActionReadback { throw BridgeServiceError.notConfigured }
    func completeReminder(id: String, completed: Bool) async throws -> ReminderActionReadback { throw BridgeServiceError.notConfigured }
    func enableNotes() async throws { throw BridgeServiceError.notConfigured }
    func listNotes(query: String) async throws -> LocalNotesCommandResult { throw BridgeServiceError.notConfigured }
    func readNote(id: String) async throws -> LocalNotesCommandResult { throw BridgeServiceError.notConfigured }
    func createNote(id: String, title: String, text: String) async throws -> LocalNotesCommandResult { throw BridgeServiceError.notConfigured }
    func appendNote(id: String, text: String, expectedRevision: String) async throws -> LocalNotesCommandResult { throw BridgeServiceError.notConfigured }
    func readWeather(cityID: String) async throws -> LocalWeatherCommandResult { throw BridgeServiceError.notConfigured }
    func requestLocationPermission() async throws { throw BridgeServiceError.notConfigured }
    func readLocation() async throws -> LocalLocationCommandResult { throw BridgeServiceError.notConfigured }
    func listMailScopes() async throws -> [MailScopeOption] { throw BridgeServiceError.notConfigured }
    func selectedMailScope() async throws -> MailScopeKey? { throw BridgeServiceError.notConfigured }
    func selectMailScope(_ key: MailScopeKey) async throws { throw BridgeServiceError.notConfigured }
    func searchMail(query: String, unreadOnly: Bool) async throws -> LocalMailCommandResult { throw BridgeServiceError.notConfigured }
    func readMail(id: String) async throws -> LocalMailCommandResult { throw BridgeServiceError.notConfigured }
    func createMailDraft(id: String, input: MailDraftInput) async throws -> LocalMailCommandResult { throw BridgeServiceError.notConfigured }
    func readMailDraft(id: String) async throws -> LocalMailCommandResult { throw BridgeServiceError.notConfigured }
    func requestMailSend(id: String, revision: String) async throws -> LocalMailCommandResult { throw BridgeServiceError.notConfigured }
    func mailDraftStatus(id: String) async throws -> LocalMailCommandResult { throw BridgeServiceError.notConfigured }
    func mailDrafts() async throws -> [MailDraftEntry] { [] }
    func confirmMailSend(id: String, preview: MailDraftContent, authorize: @escaping @Sendable () async -> Bool) async throws -> String { throw BridgeServiceError.notConfigured }
}

struct WorkbenchServiceState: Sendable {
    let status: String
    let supportedActions: [String]
    let isSimulation: Bool
    var recentActions: [ActionRecord] = []
    var locationAuthorization: LocationAuthorization? = nil
    var mailScopeID: String? = nil
    var calendarScopeID: String? = nil
}

enum BridgeServiceError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Bridge 服务尚未配置"
        }
    }
}
