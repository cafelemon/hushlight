import BridgeCore
import Foundation
import EventKit
@preconcurrency import ApplicationServices

protocol PausePreferenceStore: Sendable {
    func loadPaused() -> Bool
    func savePaused(_ paused: Bool)
}

/// UserDefaults supports concurrent access; the reference never escapes this wrapper.
final class UserDefaultsPausePreferenceStore: PausePreferenceStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "bridge.local.paused"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadPaused() -> Bool { defaults.bool(forKey: key) }
    func savePaused(_ paused: Bool) { defaults.set(paused, forKey: key) }
}

actor LocalBridgeService: BridgeService {
    private let qqChatBackend: any QQChatReading
    private var musicWriteInProgress = false
    private var songTask: Task<QQSongPlaybackCoordinator, Error>?
    private let injectedSongSearch: (any QQSongSearchPlaying)?
    private let songStorageURL: URL
    private var musicSearchActions: [ActionRecord] = []
    private let injectedMusicPlayback: (any QQMusicPlaybackProviding)?
    private var lastWeather: WeatherReport?
    func lastAutomationWeather() async -> WeatherReport? { lastWeather }
    private var automationEngine: AutomationEngine?
    func attachAutomation(_ engine: AutomationEngine) { automationEngine = engine }
    func automationSnapshot() async -> AutomationSnapshot? { await automationEngine?.snapshot() }
    private let calendarBackend = EventKitCalendarBackend()
    private let preferences: any PausePreferenceStore
    private let notificationAccess: any NotificationAccess
    private let reminderBackend: any ReminderBackend
    private let locationBackend: any LocationBackend
    private let mailScopeBackend: AppleMailScopeBackend
    private let mailDraftWorkflow: MailDraftWorkflow
    private let timerTask: Task<LocalTimerCoordinator, Error>
    private let notesTask: Task<any NotesBackend, Error>
    private let runtimeTask: Task<BridgeLocalRuntime, Error>
    private var pauseTransition: Task<Void, Error>?
    private var pauseVersion = 0

    init(
        preferences: any PausePreferenceStore = UserDefaultsPausePreferenceStore(),
        notificationAccess: any NotificationAccess = UserNotificationScheduler(),
        timerStorageURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hushlight/Bridge/timers.json"),
        reminderBackend: any ReminderBackend = EventKitReminderBackend(),
        notesBackend: (any NotesBackend)? = nil,
        notesStorageURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hushlight/Bridge/notes.json"),
        weatherBackend: any WeatherBackend = METWeatherBackend(),
        locationBackend: any LocationBackend = CoreLocationBackend(),
        mailScopeBackend: AppleMailScopeBackend = AppleMailScopeBackend(),
        mailDraftDriver: any MailDraftNativeDriving = AppleMailDraftBackend(),
        mailDraftStorageURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Hushlight/Bridge/mail-drafts.json"),
        qqChatBackend: any QQChatReading = NativeQQChatReadBackend(),
        qqMusicPlaybackBackend: (any QQMusicPlaybackProviding)? = nil,
        qqSongSearchBackend: (any QQSongSearchPlaying)? = nil,
        qqSongStorageURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Hushlight/Bridge/qq-song-playback"),
        runtimeFactory: (@Sendable (Bool, LocalTimerCoordinator?, LocalReminderCoordinator, LocalNotesCoordinator?, LocalWeatherCoordinator, LocalLocationCoordinator) async throws -> BridgeLocalRuntime)? = nil
    ) {
        self.qqChatBackend = qqChatBackend
        self.preferences = preferences
        self.injectedMusicPlayback = qqMusicPlaybackBackend
        self.injectedSongSearch = qqSongSearchBackend
        self.songStorageURL = qqSongStorageURL
        self.notificationAccess = notificationAccess
        self.reminderBackend = reminderBackend
        self.locationBackend = locationBackend
        self.mailScopeBackend = mailScopeBackend
        let paused = preferences.loadPaused()
        let drafts = MailDraftWorkflow(scope: mailScopeBackend, driver: mailDraftDriver, storageURL: mailDraftStorageURL, paused: paused)
        mailDraftWorkflow = drafts
        timerTask = Task {
            try LocalTimerCoordinator(storageURL: timerStorageURL, scheduler: notificationAccess)
        }
        notesTask = Task {
            if let notesBackend { return notesBackend }
            return try AppleNotesBackend(storageURL: notesStorageURL)
        }
        let notesTask = self.notesTask
        let timerTask = self.timerTask
        runtimeTask = Task {
            let coordinator = try? await timerTask.value
            let notesBackend = try? await notesTask.value
            let reminder = LocalReminderCoordinator(backend: reminderBackend)
            let notes = notesBackend.map { LocalNotesCoordinator(backend: $0) }
            let weather = LocalWeatherCoordinator(backend: weatherBackend)
            let location = LocalLocationCoordinator(backend: locationBackend)
            let runtime: BridgeLocalRuntime
            if let runtimeFactory {
                runtime = try await runtimeFactory(paused, coordinator, reminder, notes, weather, location)
            } else {
                runtime = try await BridgeLocalRuntime(paused: paused, timerCoordinator: coordinator,
                    reminderCoordinator: reminder, notesCoordinator: notes, weatherCoordinator: weather,
                    locationCoordinator: location, mailCoordinator: LocalMailCoordinator(backend: mailScopeBackend),
                    mailDraftCoordinator: LocalMailDraftCoordinator(backend: drafts))
            }
            // Only restore after the runtime accepted its notification backend/mode.
            try? await runtime.restoreTimers()
            return runtime
        }
    }

    init(
        preferences: any PausePreferenceStore,
        runtimeFactory: @escaping @Sendable (Bool) async throws -> BridgeLocalRuntime
    ) {
        self.init(preferences: preferences, runtimeFactory: { paused, _, _, _, _, _ in
            try await runtimeFactory(paused)
        })
    }

    init(
        preferences: any PausePreferenceStore = UserDefaultsPausePreferenceStore(),
        notificationAccess: any NotificationAccess = UserNotificationScheduler(),
        timerStorageURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hushlight/Bridge/timers.json"),
        runtimeFactory: @escaping @Sendable (Bool, LocalTimerCoordinator?) async throws -> BridgeLocalRuntime
    ) {
        self.init(preferences: preferences, notificationAccess: notificationAccess,
                  timerStorageURL: timerStorageURL, runtimeFactory: { paused, timer, _, _, _, _ in
            try await runtimeFactory(paused, timer)
        })
    }

    init(
        preferences: any PausePreferenceStore = UserDefaultsPausePreferenceStore(),
        notificationAccess: any NotificationAccess = UserNotificationScheduler(),
        timerStorageURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hushlight/Bridge/timers.json"),
        reminderBackend: any ReminderBackend = EventKitReminderBackend(),
        runtimeFactory: @escaping @Sendable (Bool, LocalTimerCoordinator?, LocalReminderCoordinator) async throws -> BridgeLocalRuntime
    ) {
        self.init(preferences: preferences, notificationAccess: notificationAccess, timerStorageURL: timerStorageURL,
                  reminderBackend: reminderBackend, runtimeFactory: { paused, timer, reminder, _, _, _ in
            try await runtimeFactory(paused, timer, reminder)
        })
    }

    init(
        preferences: any PausePreferenceStore = UserDefaultsPausePreferenceStore(),
        notificationAccess: any NotificationAccess = UserNotificationScheduler(),
        timerStorageURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hushlight/Bridge/timers.json"),
        reminderBackend: any ReminderBackend = EventKitReminderBackend(),
        notesBackend: (any NotesBackend)? = nil,
        notesStorageURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hushlight/Bridge/notes.json"),
        runtimeFactory: @escaping @Sendable (Bool, LocalTimerCoordinator?, LocalReminderCoordinator, LocalNotesCoordinator?) async throws -> BridgeLocalRuntime
    ) {
        self.init(preferences: preferences, notificationAccess: notificationAccess, timerStorageURL: timerStorageURL,
                  reminderBackend: reminderBackend, notesBackend: notesBackend, notesStorageURL: notesStorageURL,
                  runtimeFactory: { paused, timer, reminder, notes, _, _ in
            try await runtimeFactory(paused, timer, reminder, notes)
        })
    }

    init(
        preferences: any PausePreferenceStore = UserDefaultsPausePreferenceStore(),
        notificationAccess: any NotificationAccess = UserNotificationScheduler(),
        timerStorageURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hushlight/Bridge/timers.json"),
        reminderBackend: any ReminderBackend = EventKitReminderBackend(),
        notesBackend: (any NotesBackend)? = nil,
        notesStorageURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hushlight/Bridge/notes.json"),
        weatherBackend: any WeatherBackend = METWeatherBackend(),
        runtimeFactory: @escaping @Sendable (Bool, LocalTimerCoordinator?, LocalReminderCoordinator, LocalNotesCoordinator?, LocalWeatherCoordinator) async throws -> BridgeLocalRuntime
    ) {
        self.init(preferences: preferences, notificationAccess: notificationAccess, timerStorageURL: timerStorageURL,
                  reminderBackend: reminderBackend, notesBackend: notesBackend, notesStorageURL: notesStorageURL,
                  weatherBackend: weatherBackend, runtimeFactory: { paused, timer, reminder, notes, weather, _ in
            try await runtimeFactory(paused, timer, reminder, notes, weather)
        })
    }

    func automationResources() async -> [AutomationAction: String] {
        var resources: [AutomationAction: String] = [:]
        if let backend = try? await notesTask.value as? AppleNotesBackend,
           let scope = await backend.scopeIdentifier() { resources[.appendDailyNote] = scope }
        if let backend = reminderBackend as? EventKitReminderBackend,
           let scope = await backend.scopeIdentifier() { resources[.createReminder] = scope }
        if let scope = await calendarBackend.scopeIdentifier() { resources[.createCalendar] = scope }
        if AppleEventPermission.status(bundleID: "com.apple.mail") == .granted,
           let scope = try? await mailScopeBackend.scopeID() { resources[.createDraft] = scope }
        return resources
    }

    func calendarConflict(start: Date, end: Date) async throws -> Bool {
        try await requireActive()
        return try await calendarBackend.hasConflict(start: start, end: end)
    }
    func calendarScope() async -> String? { await calendarBackend.scopeIdentifier() }
    func enableCalendar() async throws {
        try await requireActive()
        guard try await calendarBackend.requestAuthorization() else { throw CalendarAccessError.permissionRequired }
        try await requireActive()
        _ = try await calendarBackend.enableDedicatedCalendar()
    }
    func listCalendar(start: Date, end: Date) async throws -> [CalendarEventRecord] {
        try await requireActive()
        return try await calendarBackend.list(start: start, end: end)
    }
    func createCalendarEvent(id: String, title: String, start: Date, end: Date, sourceURL: URL?) async throws -> CalendarEventRecord {
        try await requireActive()
        guard try await !calendarBackend.hasConflict(start: start, end: end, excluding: id) else { throw CalendarAccessError.invalidInput }
        try await requireActive()
        return try await calendarBackend.create(id: id, title: title, start: start, end: end, sourceURL: sourceURL)
    }
    func updateCalendarEvent(id: String, title: String?, start: Date?, end: Date?) async throws -> CalendarEventRecord {
        try await requireActive()
        return try await calendarBackend.update(id: id, title: title, start: start, end: end)
    }
    func cancelCalendarEvent(id: String) async throws {
        try await requireActive()
        try await calendarBackend.cancel(id: id)
    }
    func mailBaseline() async throws -> MailIncrementalCursor {
        try await requireActive()
        return try await mailScopeBackend.makeIncrementalBaseline()
    }
    func pollMail(after cursor: MailIncrementalCursor) async throws -> MailIncrementalPoll {
        try await requireActive()
        return try await mailScopeBackend.pollIncremental(after: cursor)
    }
    func mailSender() async throws -> String {
        try await requireActive()
        guard let selected = try await mailScopeBackend.selectedScope(),
              let option = try await mailScopeBackend.availableScopes().first(where: { $0.key == selected }),
              let sender = option.accountAddresses.first else { throw MailScopeError.invalidScope }
        return sender
    }
    private func requireActive() async throws {
        try await waitForLatestPause()
        guard !(await (try runtimeTask.value).snapshot()).isPaused else { throw StableErrorCode.bridgePaused }
    }

    func requestQQMusicAccess() async -> Bool {
        guard Bundle.main.bundleIdentifier == "com.hushlight.bridge.mac" else { return false }
        return AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    func qqChatSnapshot() async throws -> QQChatSnapshot {
        try await requireActive()
        let version = pauseVersion
        let result = try await qqChatBackend.snapshot()
        try await requireActive()
        guard version == pauseVersion else { throw StableErrorCode.bridgePaused }
        return result
    }

    func qqMusicPlayback() async throws -> QQMusicPlayback {
        try await requireActive()
        let backend = await musicPlaybackBackend()
        return try await backend.read()
    }

    func performQQMusic(_ action: QQMusicPlaybackAction, authorize: @escaping @Sendable () async -> Bool) async throws -> QQMusicPlayback {
        try await requireActive()
        // UI and all Agent connections share one control slot; distinct commands cannot interleave AX presses.
        guard !musicWriteInProgress else { throw StableErrorCode.capabilityDisabled }
        musicWriteInProgress = true
        defer { musicWriteInProgress = false }
        let backend = await musicPlaybackBackend()
        return try await backend.perform(action) { [weak self] in
            guard let self, await authorize() else { return false }
            return (try? await self.requireActive()) != nil
        }
    }

    func searchAndPlayQQMusic(id: String, request: QQSongRequest, authorize: @escaping @Sendable () async -> Bool) async throws -> QQSongPlayResult {
        try await requireActive()
        guard !musicWriteInProgress else { throw StableErrorCode.capabilityDisabled }
        musicWriteInProgress = true
        defer { musicWriteInProgress = false }
        let coordinator = try await songCoordinator()
        let caller = BridgeExecutionContext.callerID
        let result = await coordinator.play(id: id, caller: caller, request: request) { [weak self] in
            guard let self, await authorize() else { return false }
            return (try? await self.requireActive()) != nil
        }
        if !result.replayed {
            musicSearchActions.append(.init(id: UUID(uuidString: id) ?? UUID(), name: "music.qq.searchPlay",
                outcome: ActionOutcome(rawValue: result.status) ?? .unknown, occurredAt: Date(),
                callerID: caller, correlationID: id, stableError: result.error))
            musicSearchActions = Array(musicSearchActions.suffix(50))
        }
        return result
    }
    func pendingQQSong() async throws -> QQSongPending? { try await songCoordinator().pending() }
    func acknowledgeQQSong(_ pending: QQSongPending) async throws {
        try await requireActive()
        try await songCoordinator().acknowledge(pending)
    }
    private func songCoordinator() async throws -> QQSongPlaybackCoordinator {
        if let songTask { return try await songTask.value }
        let injected = injectedSongSearch, directory = songStorageURL
        let task = Task {
            let backend: any QQSongSearchPlaying
            if let injected { backend = injected }
            else { backend = await NativeQQSongSearchBackend() }
            return try QQSongPlaybackCoordinator(directory: directory, backend: backend)
        }
        songTask = task
        return try await task.value
    }

    private func musicPlaybackBackend() async -> any QQMusicPlaybackProviding {
        if let injectedMusicPlayback { return injectedMusicPlayback }
        return await QQMusicPlaybackBackend()
    }

    func qqMusicStatus() async throws -> QQMusicStatus {
        try await requireActive()
        return try await QQMusicStatusBackend().status()
    }

    func systemAuthorizationStates() async -> [String: String] {
        guard Bundle.main.bundleIdentifier == "com.hushlight.bridge.mac" else { return [:] }
        var result: [String: String] = ["accessibility": AXIsProcessTrusted() ? "authorized" : "notAuthorized"]
        switch await notificationAccess.authorizationStatus() {
        case .authorized: result["notifications"] = "authorized"
        case .denied: result["notifications"] = "denied"
        case .notDetermined: result["notifications"] = "notDetermined"
        }
        switch await reminderBackend.authorizationStatus() {
        case .authorized: result["reminders"] = "authorized"
        case .denied: result["reminders"] = "denied"
        case .notDetermined: result["reminders"] = "notDetermined"
        }
        let calendarStatus = await calendarBackend.authorizationStatus()
        if #available(macOS 14.0, *), calendarStatus == .writeOnly {
            result["calendar"] = "writeOnly"
        } else {
            switch calendarStatus {
            case .notDetermined: result["calendar"] = "notDetermined"
            case .restricted: result["calendar"] = "restricted"
            case .denied: result["calendar"] = "denied"
            case .authorized: result["calendar"] = "authorized"
            default:
                if #available(macOS 14.0, *), calendarStatus == .fullAccess { result["calendar"] = "authorized" }
                else { result["calendar"] = "unknown" }
            }
        }
        for (key, bundleID) in [("notes", "com.apple.Notes"), ("mail", "com.apple.mail")] {
            switch AppleEventPermission.status(bundleID: bundleID) {
            case .granted: result[key] = "authorized"
            case .needsConsent: result[key] = "notDetermined"
            case .denied: result[key] = "denied"
            case .unavailable: result[key] = "unknown" // A stopped target is not evidence of denial.
            }
        }
        return result
    }

    func workbenchState() async throws -> WorkbenchServiceState {
        try await waitForLatestPause()
        let state = await (try runtimeTask.value).snapshot()
        let locationAuthorization: LocationAuthorization?
        if state.supportedActions.contains("location.get") {
            locationAuthorization = await locationBackend.authorizationStatus()
        } else {
            locationAuthorization = nil
        }
        return WorkbenchServiceState(status: state.isPaused ? "paused" : "localReady",
                                     supportedActions: state.supportedActions + ["calendar.list", "calendar.create", "calendar.update", "calendar.cancel", "automation.status", "automation.runs", "music.qq.status", "music.qq.playback", "music.qq.play", "music.qq.pause", "music.qq.next", "music.qq.previous", "music.qq.searchPlay"], isSimulation: state.isSimulation,
                                     recentActions: state.recentActions.map {
                                         ActionRecord(id: UUID(uuidString: $0.requestID) ?? UUID(), name: $0.action,
                                                      outcome: ActionOutcome(rawValue: $0.status) ?? .unknown, occurredAt: $0.completedAt,
                                                      callerID: $0.callerID, correlationID: $0.correlationID, stableError: $0.stableError)
                                     } + musicSearchActions, locationAuthorization: locationAuthorization,
                                     mailScopeID: state.supportedActions.contains("mail.search") ? (try? await mailScopeBackend.scopeID()) : nil,
                                     calendarScopeID: await calendarBackend.scopeIdentifier())
    }

    func workbenchTimers() async throws -> [LocalTimerRecord] {
        try await waitForLatestPause()
        return try await (try runtimeTask.value).timerSnapshot()
    }

    func workbenchReminders() async throws -> [LocalReminderRecord] {
        try await waitForLatestPause()
        return try await (try runtimeTask.value).reminderSnapshot()
    }

    func snapshot() async throws -> BridgeSnapshot {
        try await waitForLatestPause()
        let runtime = try await runtimeTask.value
        let state = await runtime.snapshot()
        let authorization = await notificationAccess.authorizationStatus()
        let timerState: ([LocalTimerRecord], String?)
        do {
            _ = try await timerTask.value
            let savedTimers = try await runtime.timerSnapshot()
            timerState = (savedTimers, authorization == .authorized ? nil :
                "通知未授权；当前仅显示已保存的计时器，通知调度无法核对。请在开发版 App 授权通知。")
        } catch {
            timerState = ([], Self.timerErrorMessage(error))
        }
        let reminderAuthorization = await reminderBackend.authorizationStatus()
        let reminders: [LocalReminderRecord]
        let reminderError: String?
        var reminderReady = false
        do {
            reminders = try await runtime.reminderSnapshot()
            reminderError = nil
            reminderReady = true
        } catch {
            reminders = []
            reminderError = reminderAuthorization == .notDetermined ? nil : Self.reminderErrorMessage(error)
        }
        var notesEnabled = false
        if state.supportedActions.contains("note.read"), let backend = try? await notesTask.value {
            notesEnabled = await backend.isEnabled()
        }
        let locationAuthorization: LocationAuthorization
        if state.supportedActions.contains("location.get") {
            locationAuthorization = await locationBackend.authorizationStatus()
        } else { locationAuthorization = .unavailable }
        let calendarReady = await calendarBackend.scopeIdentifier() != nil
        let notePermission = AppleEventPermission.status(bundleID: "com.apple.Notes")
        let mailPermission = AppleEventPermission.status(bundleID: "com.apple.mail")
        return BridgeSnapshot(
            status: state.isPaused ? .paused : .localReady,
            permissions: PermissionKind.allCases.map { kind in
                let value: PermissionState
                switch kind {
                case .notifications: value = Self.permissionState(authorization)
                case .reminders: value = Self.reminderPermissionState(reminderAuthorization)
                case .notes: value = Self.appleEventState(notePermission)
                case .mail: value = Self.appleEventState(mailPermission)
                case .calendar: value = calendarReady ? .granted : .notChecked
                case .location:
                    value = locationAuthorization == .authorized ? .granted : locationAuthorization == .denied ? .denied : .notChecked
                case .automation, .accessibility: value = .notChecked
                }
                return PermissionStatus(kind: kind, state: value)
            },
            recentActions: state.recentActions.map {
                ActionRecord(
                    id: UUID(uuidString: $0.requestID) ?? UUID(),
                    name: (state.isSimulation ? "模拟 · " : "") + ($0.action == "system.volume.get" ? "读取系统音量" : $0.action),
                    outcome: ActionOutcome(rawValue: $0.status) ?? .unknown,
                    occurredAt: $0.completedAt,
                    callerID: $0.callerID, correlationID: $0.correlationID, stableError: $0.stableError
                )
            } + musicSearchActions,
            timers: timerState.0,
            timerError: timerState.1,
            reminders: reminders, reminderError: reminderError, reminderReady: reminderReady, notesEnabled: notesEnabled, locationAuthorization: locationAuthorization
        )
    }

    func requestNotificationPermission() async throws {
        let runtime = try await runtimeTask.value
        let capabilities = await runtime.snapshot()
        guard capabilities.supportedActions.contains("timer.create") else {
            throw BridgeServiceError.notConfigured
        }
        guard try await notificationAccess.requestAuthorization() else {
            throw UserNotificationSchedulerError.permissionRequired
        }
        try await runtime.restoreTimers()
    }

    func createTimer(id: String, fireAt: Date, label: String) async throws -> TimerActionReadback {
        _ = try await timerTask.value
        try await waitForLatestPause()
        let runtime = try await runtimeTask.value
        return Self.timerReadback(await runtime.createTimer(id: id, fireAt: fireAt, label: label))
    }

    func updateTimer(id: String, fireAt: Date?, label: String?) async throws -> TimerActionReadback {
        _ = try await timerTask.value
        try await waitForLatestPause()
        let runtime = try await runtimeTask.value
        return Self.timerReadback(await runtime.updateTimer(id: id, fireAt: fireAt, label: label))
    }

    func cancelTimer(id: String) async throws -> TimerActionReadback {
        _ = try await timerTask.value
        try await waitForLatestPause()
        let runtime = try await runtimeTask.value
        return Self.timerReadback(await runtime.cancelTimer(id: id))
    }

    func enableReminders() async throws {
        try await waitForLatestPause()
        let runtime = try await runtimeTask.value
        let state = await runtime.snapshot()
        guard !state.isPaused else { throw StableErrorCode.bridgePaused }
        guard state.supportedActions.contains("reminder.complete") else { throw BridgeServiceError.notConfigured }
        guard try await reminderBackend.requestAuthorization() else { throw StableErrorCode.permissionRequired }
        // Permission dialogs suspend; honor a pause selected while the dialog was open.
        try await waitForLatestPause()
        guard !(await runtime.snapshot()).isPaused else { throw StableErrorCode.bridgePaused }
        try await reminderBackend.enableDedicatedList()
    }

    func createReminder(id: String, title: String, dueAt: Date) async throws -> ReminderActionReadback {
        try await waitForLatestPause()
        return Self.reminderReadback(await (try runtimeTask.value).createReminder(id: id, title: title, dueAt: dueAt))
    }

    func updateReminder(id: String, title: String?, dueAt: Date?) async throws -> ReminderActionReadback {
        try await waitForLatestPause()
        return Self.reminderReadback(await (try runtimeTask.value).updateReminder(id: id, title: title, dueAt: dueAt))
    }

    func completeReminder(id: String, completed: Bool) async throws -> ReminderActionReadback {
        try await waitForLatestPause()
        return Self.reminderReadback(await (try runtimeTask.value).completeReminder(id: id, completed: completed))
    }

    private static func reminderReadback(_ result: LocalReminderCommandResult) -> ReminderActionReadback {
        ReminderActionReadback(outcome: ActionOutcome(rawValue: result.status) ?? .unknown,
                               stableError: result.stableError, completedAt: result.completedAt)
    }

    private static func appleEventState(_ status: AppleEventPermission.Status) -> PermissionState {
        switch status {
        case .granted: .granted
        case .needsConsent: .notRequested
        case .denied: .denied
        case .unavailable: .notChecked
        }
    }
    private static func reminderPermissionState(_ state: ReminderAuthorization) -> PermissionState {
        switch state {
        case .authorized: .granted
        case .notDetermined: .notRequested
        case .denied: .denied
        }
    }

    private static func reminderErrorMessage(_ error: Error) -> String {
        if error as? StableErrorCode == .permissionRequired { return "需要提醒事项权限，请在系统设置中允许。" }
        return (error as? ReminderAccessError)?.errorDescription ?? "提醒事项尚未就绪，请启用专用列表或刷新重试。"
    }

    func enableNotes() async throws {
        try await waitForLatestPause()
        let runtime = try await runtimeTask.value
        let state = await runtime.snapshot()
        guard !state.isPaused else { throw StableErrorCode.bridgePaused }
        let backend = try await notesTask.value
        guard state.supportedActions.contains("note.read") else { throw BridgeServiceError.notConfigured }
        try await backend.enable()
    }

    func listNotes(query: String) async throws -> LocalNotesCommandResult {
        try await waitForLatestPause()
        let runtime = try await runtimeTask.value
        return await runtime.listNotes(query: query)
    }

    func readNote(id: String) async throws -> LocalNotesCommandResult {
        try await waitForLatestPause()
        let runtime = try await runtimeTask.value
        return await runtime.readNote(id: id)
    }

    func createNote(id: String, title: String, text: String) async throws -> LocalNotesCommandResult {
        try await waitForLatestPause()
        let runtime = try await runtimeTask.value
        return await runtime.createNote(id: id, title: title, text: text)
    }

    func appendNote(id: String, text: String, expectedRevision: String) async throws -> LocalNotesCommandResult {
        try await waitForLatestPause()
        let runtime = try await runtimeTask.value
        return await runtime.appendNote(id: id, text: text, expectedRevision: expectedRevision)
    }

    func readWeather(cityID: String) async throws -> LocalWeatherCommandResult {
        try await waitForLatestPause()
        let runtime = try await runtimeTask.value
        let result = await runtime.readWeather(cityID: cityID)
        if result.status == "succeeded" { lastWeather = result.report }
        return result
    }

    func requestLocationPermission() async throws {
        try await waitForLatestPause()
        let runtime = try await runtimeTask.value
        let state = await runtime.snapshot()
        guard !state.isPaused else { throw StableErrorCode.bridgePaused }
        guard state.supportedActions.contains("location.get") else { throw BridgeServiceError.notConfigured }
        let authorization = try await locationBackend.requestAuthorization()
        guard authorization == .authorized else { throw StableErrorCode.permissionRequired }
    }

    func readLocation() async throws -> LocalLocationCommandResult {
        try await waitForLatestPause()
        let runtime = try await runtimeTask.value
        return await runtime.readLocation()
    }

    func listMailScopes() async throws -> [MailScopeOption] {
        try await waitForLatestPause()
        let state = await (try runtimeTask.value).snapshot()
        guard !state.isPaused else { throw StableErrorCode.bridgePaused }
        return try await mailScopeBackend.availableScopes()
    }

    func selectedMailScope() async throws -> MailScopeKey? {
        try await mailScopeBackend.selectedScope()
    }

    func selectMailScope(_ key: MailScopeKey) async throws {
        try await waitForLatestPause()
        let state = await (try runtimeTask.value).snapshot()
        guard !state.isPaused else { throw StableErrorCode.bridgePaused }
        try await mailScopeBackend.choose(key)
    }

    func searchMail(query: String, unreadOnly: Bool) async throws -> LocalMailCommandResult {
        try await waitForLatestPause()
        return await (try runtimeTask.value).searchMail(query: query, unreadOnly: unreadOnly)
    }

    func readMail(id: String) async throws -> LocalMailCommandResult {
        try await waitForLatestPause()
        return await (try runtimeTask.value).readMail(id: id)
    }
    func createMailDraft(id: String, input: MailDraftInput) async throws -> LocalMailCommandResult {
        try await waitForLatestPause()
        return await (try runtimeTask.value).createMailDraft(id: id, input: input)
    }
    func readMailDraft(id: String) async throws -> LocalMailCommandResult {
        try await waitForLatestPause()
        return await (try runtimeTask.value).readMailDraft(id: id)
    }
    func requestMailSend(id: String, revision: String) async throws -> LocalMailCommandResult {
        try await waitForLatestPause()
        return await (try runtimeTask.value).requestMailSend(id: id, revision: revision)
    }
    func mailDraftStatus(id: String) async throws -> LocalMailCommandResult {
        try await waitForLatestPause()
        return await (try runtimeTask.value).mailDraftStatus(id: id)
    }
    func mailDrafts() async throws -> [MailDraftEntry] { try await mailDraftWorkflow.list() }
    func confirmMailSend(id: String, preview: MailDraftContent, authorize: @escaping @Sendable () async -> Bool) async throws -> String {
        try await waitForLatestPause()
        return try await mailDraftWorkflow.confirmSend(id: id, preview: preview, authorize: authorize)
    }

    func setPaused(_ paused: Bool) async throws {
        let previous = pauseTransition
        let task = runtimeTask
        let preferences = preferences
        let drafts = mailDraftWorkflow
        let automation = automationEngine
        let transition = Task {
            if let previous { try await previous.value }
            let runtime = try await task.value
            await automation?.setPaused(paused)
            await drafts.setPaused(paused)
            await runtime.setPaused(paused)
            preferences.savePaused(paused)
        }
        pauseTransition = transition
        pauseVersion += 1
        try await transition.value
    }

    func readSystemVolume() async throws -> VolumeReadback {
        try await waitForLatestPause()
        let runtime = try await runtimeTask.value
        let result = await runtime.readSystemVolume()
        return VolumeReadback(
            outcome: ActionOutcome(rawValue: result.status) ?? .unknown,
            stableError: result.stableError,
            value: result.value,
            muted: result.muted,
            readAt: result.completedAt,
            isSimulation: result.isSimulation
        )
    }

    private func waitForLatestPause() async throws {
        while let transition = pauseTransition {
            let version = pauseVersion
            try await transition.value
            if version == pauseVersion { return }
        }
    }

    private static func timerReadback(_ result: LocalTimerCommandResult) -> TimerActionReadback {
        TimerActionReadback(
            outcome: ActionOutcome(rawValue: result.status) ?? .unknown,
            stableError: result.stableError,
            completedAt: result.completedAt
        )
    }

    private static func permissionState(_ authorization: TimerNotificationAuthorization) -> PermissionState {
        switch authorization {
        case .notDetermined: .notRequested
        case .authorized: .granted
        case .denied: .denied
        }
    }

    private static func timerErrorMessage(_ error: Error) -> String {
        switch error {
        case LocalTimerStorageError.corruptState:
            "计时器存储文件已损坏；原文件已保留，请检查后再恢复。"
        case LocalTimerStorageError.invalidLocation:
            "计时器存储路径无效。"
        case LocalTimerStorageError.reconciliationRequired:
            "计时器通知未能与系统核对，请重试恢复。"
        default:
            "计时器暂不可用：\(error.localizedDescription)"
        }
    }
}
