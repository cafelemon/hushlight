import Foundation
import BridgeCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var selectedPage: WorkbenchPage = .overview
    @Published private(set) var status: BridgeStatus = .notConfigured
    @Published private(set) var permissions: [PermissionStatus] = PermissionKind.allCases.map {
        PermissionStatus(kind: $0, state: .notRequested)
    }
    @Published private(set) var recentActions: [ActionRecord] = []
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var qqChatReadback: QQChatSnapshot?
    @Published private(set) var qqChatError: String?
    private var qqChatGeneration = UUID()
    @Published private(set) var qqMusicPlaybackReadback: QQMusicPlayback?
    @Published private(set) var qqMusicAccessMessage: String?
    @Published var songTitle = ""
    @Published var songArtist = ""
    @Published var songVersion: QQSongVersion = .original
    @Published private(set) var songPlayResult: QQSongPlayResult?
    @Published private(set) var songPending: QQSongPending?
    private var activeSongRequestID: String?
    @Published private(set) var qqMusicReadback: QQMusicStatus?
    @Published private(set) var qqMusicError: String?
    @Published private(set) var volumeError: String?
    @Published private(set) var volumeReadback: VolumeReadback?
    @Published private(set) var busyActivities: Set<CapabilityActivity> = []
    @Published private(set) var timers: [LocalTimerRecord] = []
    @Published private(set) var timerError: String?
    @Published private(set) var timerActionResult: TimerActionReadback?
    @Published private(set) var reminders: [LocalReminderRecord] = []
    @Published private(set) var reminderError: String?
    @Published private(set) var reminderReady = false
    @Published private(set) var reminderActionResult: ReminderActionReadback?
    @Published private(set) var notes: [LocalNoteSummary] = []
    @Published private(set) var selectedNote: LocalNoteContent?
    @Published private(set) var notesEnabled = false
    @Published private(set) var notesResult: LocalNotesCommandResult?
    @Published private(set) var notesError: String?
    @Published private(set) var weatherResult: LocalWeatherCommandResult?
    @Published private(set) var weatherError: String?
    @Published private(set) var locationAuthorization: LocationAuthorization = .notChecked
    @Published private(set) var locationResult: LocalLocationCommandResult?
    @Published private(set) var locationError: String?
    @Published private(set) var mailScopeOptions: [MailScopeOption] = []
    @Published private(set) var selectedMailScope: MailScopeKey?
    @Published private(set) var mailScopeVerified = false
    @Published private(set) var mailScopeError: String?
    @Published private(set) var mailMessages: [LocalMailSummary] = []
    @Published private(set) var selectedMail: LocalMailContent?
    @Published private(set) var mailReadError: String?
    @Published private(set) var mailHasSearched = false
    @Published private(set) var mailIsSimulation = false
    @Published private(set) var mailDraftEntries: [MailDraftEntry] = []
    @Published private(set) var mailDraftError: String?
    @Published private(set) var mailSendMessage: String?
    @Published private(set) var mailSendPreview: MailDraftContent?
    private var creatingDraftID: String?

    private let bridgeService: any BridgeService
    private var weatherRequestID = UUID()
    private var locationRequestID = UUID()
    private var mailRequestID = UUID()

    init(bridgeService: any BridgeService) {
        self.bridgeService = bridgeService
    }

    var isPaused: Bool {
        status == .paused
    }

    func selectPage(_ page: WorkbenchPage) {
        if selectedPage == .qqChat && page != .qqChat {
            clearQQChatPreview()
        }
        selectedPage = page
    }

    // Kept for callers that need an aggregate progress indicator.
    var isBusy: Bool { !busyActivities.isEmpty }

    func isBusy(_ activity: CapabilityActivity) -> Bool {
        busyActivities.contains(activity)
    }

    private func canStart(_ activity: CapabilityActivity) -> Bool {
        !isBusy(activity) && (activity == .pause || !isBusy(.pause))
    }

    func refresh() async {
        guard canStart(.refresh) else { return }
        busyActivities.insert(.refresh)
        defer { busyActivities.remove(.refresh) }
        do {
            apply(try await bridgeService.snapshot())
            lastErrorMessage = nil
        } catch {
            status = .unavailable
            lastErrorMessage = error.localizedDescription
            invalidateLocationSnapshot()
        }
    }

    func togglePause() async {
        guard canStart(.pause) else { return }
        busyActivities.insert(.pause)
        defer { busyActivities.remove(.pause) }
        let shouldPause = !isPaused
        if shouldPause { clearQQChatPreview() }

        do {
            try await bridgeService.setPaused(shouldPause)
            volumeReadback = nil
            apply(try await bridgeService.snapshot())
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            invalidateLocationSnapshot()
        }
    }

    func clearQQChatPreview() {
        qqChatGeneration = UUID()
        qqChatReadback = nil
        qqChatError = nil
    }

    func readQQChatPreview() async {
        guard canStart(.qqChat), !isPaused else { return }
        busyActivities.insert(.qqChat)
        defer { busyActivities.remove(.qqChat) }
        let generation = UUID()
        qqChatGeneration = generation
        qqChatReadback = nil
        qqChatError = nil
        do {
            let result = try await bridgeService.qqChatSnapshot()
            guard generation == qqChatGeneration, !isPaused, !isBusy(.pause) else { return }
            qqChatReadback = result
        } catch {
            guard generation == qqChatGeneration, !isPaused, !isBusy(.pause) else { return }
            // Native errors are fixed descriptions; never interpolate message content.
            qqChatError = (error as? QQChatReadError)?.localizedDescription ?? "无法读取QQ会话，请检查QQ窗口和辅助功能权限。"
        }
    }

    func requestQQMusicAccess() async {
        guard canStart(.music), !isPaused else { return }
        busyActivities.insert(.music)
        defer { busyActivities.remove(.music) }
        let granted = await bridgeService.requestQQMusicAccess()
        qqMusicAccessMessage = granted ? "辅助功能已授权，可检查播放栏。" : "请在系统设置允许当前 Orbit 智轨 Dev 的辅助功能权限，然后重新检查。"
    }

    func readQQMusicPlayback() async {
        guard canStart(.music), !isPaused else { return }
        busyActivities.insert(.music)
        defer { busyActivities.remove(.music) }
        qqMusicError = nil
        do { qqMusicPlaybackReadback = try await bridgeService.qqMusicPlayback() }
        catch { qqMusicPlaybackReadback = nil; qqMusicError = error.localizedDescription }
    }

    func performQQMusic(_ action: QQMusicPlaybackAction) async {
        guard canStart(.music), !isPaused else { return }
        busyActivities.insert(.music)
        defer { busyActivities.remove(.music) }
        qqMusicError = nil
        do { qqMusicPlaybackReadback = try await bridgeService.performQQMusic(action, authorize: { true }) }
        catch { qqMusicPlaybackReadback = nil; qqMusicError = error.localizedDescription }
    }

    func refreshQQSongPending() async {
        do { songPending = try await bridgeService.pendingQQSong() }
        catch { qqMusicError = "无法读取播放执行记录，请检查工作台存储。" }
    }
    func searchAndPlayQQSong(_ request: QQSongRequest) async {
        guard canStart(.music), !isPaused, songPending == nil else { return }
        busyActivities.insert(.music)
        let id = UUID().uuidString
        activeSongRequestID = id
        defer { busyActivities.remove(.music); activeSongRequestID = nil }
        qqMusicError = nil; songPlayResult = nil
        do {
            let result = try await bridgeService.searchAndPlayQQMusic(id: id, request: request, authorize: { [weak self] in
                guard let self else { return false }
                return await self.songRequestAuthorized(id)
            })
            songPlayResult = result
            if let playback = result.playback { qqMusicPlaybackReadback = playback }
        } catch { qqMusicError = "搜索播放未完成，请检查QQ、辅助功能和屏幕录制权限。" }
        await refreshQQSongPending()
        await refresh()
    }
    private func songRequestAuthorized(_ id: String) -> Bool { !isPaused && activeSongRequestID == id }
    func acknowledgeQQSong() async {
        guard canStart(.music), !isPaused, let pending = songPending else { return }
        busyActivities.insert(.music)
        defer { busyActivities.remove(.music) }
        do { try await bridgeService.acknowledgeQQSong(pending); await refreshQQSongPending() }
        catch { qqMusicError = "未能解除播放记录阻塞；不会重新播放旧请求。" }
    }

    func readQQMusicStatus() async {
        guard canStart(.music), !isPaused else { return }
        busyActivities.insert(.music)
        defer { busyActivities.remove(.music) }
        qqMusicError = nil
        do { qqMusicReadback = try await bridgeService.qqMusicStatus() }
        catch { qqMusicReadback = nil; qqMusicError = error.localizedDescription }
    }

    func readSystemVolume() async {
        guard canStart(.volume), !isPaused else { return }
        busyActivities.insert(.volume)
        volumeReadback = nil
        volumeError = nil
        defer { busyActivities.remove(.volume) }
        do {
            let result = try await bridgeService.readSystemVolume()
            volumeReadback = result
            volumeError = result.errorMessage
            lastErrorMessage = result.errorMessage
            apply(try await bridgeService.snapshot())
        } catch {
            status = .unavailable
            volumeError = error.localizedDescription
            lastErrorMessage = error.localizedDescription
        }
    }

    func clearWeather() {
        weatherRequestID = UUID()
        weatherResult = nil
        weatherError = nil
    }

    func loadMailScope() async {
        do {
            let key = try await bridgeService.selectedMailScope()
            if key != selectedMailScope {
                clearMailResults()
                mailScopeVerified = false
            }
            selectedMailScope = key
        } catch {
            mailScopeError = error.localizedDescription
        }
    }

    func discoverMailScopes() async {
        guard canStart(.mail), !isPaused else { return }
        busyActivities.insert(.mail)
        defer { busyActivities.remove(.mail) }
        mailScopeOptions = []
        mailScopeVerified = false
        mailScopeError = nil
        do {
            let options = try await bridgeService.listMailScopes()
            mailScopeOptions = options
            mailScopeVerified = selectedMailScope.map { key in options.contains { $0.key == key } } ?? false
        } catch {
            mailScopeError = error.localizedDescription
        }
    }

    func selectMailScope(_ key: MailScopeKey) async {
        guard canStart(.mail), !isPaused else { return }
        busyActivities.insert(.mail)
        defer { busyActivities.remove(.mail) }
        mailScopeError = nil
        clearMailResults()
        do {
            try await bridgeService.selectMailScope(key)
            selectedMailScope = key
            mailScopeVerified = true
        } catch {
            mailScopeVerified = false
            mailScopeError = error.localizedDescription
        }
    }

    func clearMailResults() {
        mailRequestID = UUID()
        mailMessages = []
        selectedMail = nil
        mailReadError = nil
        mailHasSearched = false
        mailIsSimulation = false
    }

    func searchMail(query: String, unreadOnly: Bool) async {
        guard canStart(.mail), !isPaused, let scope = selectedMailScope else { return }
        clearMailResults()
        let token = mailRequestID
        busyActivities.insert(.mail)
        defer { busyActivities.remove(.mail) }
        do {
            let result = try await bridgeService.searchMail(query: query, unreadOnly: unreadOnly)
            guard token == mailRequestID, selectedMailScope == scope else { return }
            if result.status == "succeeded" {
                mailMessages = result.messages
                mailHasSearched = true
                mailIsSimulation = result.isSimulation
                mailScopeVerified = true
            } else { mailReadError = Self.mailFailure(result.stableError) }
            apply(try await bridgeService.snapshot())
        } catch {
            guard token == mailRequestID else { return }
            clearMailResults()
            mailReadError = "邮件搜索失败：\(error.localizedDescription)"
        }
    }

    func readMail(id: String) async {
        guard canStart(.mail), !isPaused, let scope = selectedMailScope else { return }
        selectedMail = nil
        mailReadError = nil
        mailRequestID = UUID()
        let token = mailRequestID
        busyActivities.insert(.mail)
        defer { busyActivities.remove(.mail) }
        do {
            let result = try await bridgeService.readMail(id: id)
            guard token == mailRequestID, selectedMailScope == scope else { return }
            if result.status == "succeeded", let mail = result.mail, mail.message.id == id {
                selectedMail = mail
                mailIsSimulation = result.isSimulation
                mailScopeVerified = true
            } else { mailReadError = Self.mailFailure(result.stableError) }
            apply(try await bridgeService.snapshot())
        } catch {
            guard token == mailRequestID else { return }
            selectedMail = nil
            mailReadError = "邮件读取失败：\(error.localizedDescription)"
        }
    }

    private static func mailFailure(_ error: String?) -> String {
        switch error {
        case "permission_required": "邮件授权或邮箱范围已变化，请检查 Apple Mail 页面与 Agent 授权。"
        case "capability_disabled": "邮箱未连接或超出本版范围（最多 1000 封、50 条结果、正文 24000 字符），请缩小查询或检查所选邮箱。"
        case "invalid_schema": "邮件标识或查询参数无效，请重新搜索。"
        case "bridge_paused": "本地能力已暂停。"
        default: "无法核实邮件结果（\(error ?? "未知错误")），请检查 Mail 后重试。"
        }
    }

    func refreshMailDrafts() async {
        do { mailDraftEntries = try await bridgeService.mailDrafts() }
        catch { mailDraftError = "无法读取草稿执行记录：\(error.localizedDescription)" }
    }

    func createMailDraft(input: MailDraftInput) async {
        guard canStart(.mail), !isPaused else { return }
        busyActivities.insert(.mail)
        defer { busyActivities.remove(.mail) }
        mailDraftError = nil; mailSendMessage = nil
        let id = creatingDraftID ?? UUID().uuidString.lowercased()
        creatingDraftID = id
        do {
            let result = try await bridgeService.createMailDraft(id: id, input: input)
            if result.status == "succeeded" {
                creatingDraftID = nil
                mailSendMessage = "草稿已创建并回读，尚未发送。"
            } else {
                mailDraftError = "草稿未完成（\(result.stableError ?? result.status)）。结果未知时请先在 Mail 核对；不会自动重建。"
            }
            await refreshMailDrafts()
            apply(try await bridgeService.snapshot())
        } catch { mailDraftError = "草稿操作未完成，请先核对系统 Mail：\(error.localizedDescription)" }
    }

    func prepareMailSend(id: String) async {
        guard canStart(.mail), !isPaused else { return }
        busyActivities.insert(.mail)
        defer { busyActivities.remove(.mail) }
        mailSendPreview = nil; mailDraftError = nil; mailSendMessage = nil
        do {
            let result = try await bridgeService.readMailDraft(id: id)
            guard result.status == "succeeded", let draft = result.draft else {
                mailDraftError = "无法核实草稿（\(result.stableError ?? result.status)），未发送。"; return
            }
            let pending = try await bridgeService.requestMailSend(id: id, revision: draft.revision)
            guard pending.status == "succeeded", pending.sendState == "awaiting_confirmation" else {
                mailDraftError = "无法建立发送确认（\(pending.stableError ?? pending.status)），未发送。"; return
            }
            mailSendPreview = draft
            await refreshMailDrafts()
        } catch { mailDraftError = "草稿核对失败，未发送：\(error.localizedDescription)" }
    }

    func dismissMailSendPreview() { mailSendPreview = nil }

    func confirmMailSend(host: WorkbenchHost?) async {
        guard canStart(.mail), !isPaused, let preview = mailSendPreview, let host else { return }
        mailSendPreview = nil
        busyActivities.insert(.mail)
        defer { busyActivities.remove(.mail) }
        do {
            let state = try await host.confirmMailSend(id: preview.id, preview: preview)
            mailSendMessage = state == "submitted" ? "Mail 已接受发送请求；这不代表对方已收到。" : "发送结果未知，请先在 Mail 核对，不能重复发送。"
        } catch {
            mailDraftError = "发送未能核实（\(String(describing: error))）。请先检查 Mail 与草稿记录，不能自动重发。"
        }
        await refreshMailDrafts()
    }

    // Only clears the coordinate shown in this session; it does not change system authorization.
    func clearLocation() {
        locationRequestID = UUID()
        locationResult = nil
        locationError = nil
    }

    // A foreground notification may arrive while another capability is busy.
    // Query status without taking the action lock; snapshot never starts location acquisition.
    func refreshLocationAuthorization() async {
        do {
            let snapshot = try await bridgeService.snapshot()
            locationAuthorization = snapshot.locationAuthorization
            if locationAuthorization != .authorized { clearLocation() }
        } catch {
            invalidateLocationSnapshot()
        }
    }

    func requestLocationPermission() async {
        guard canStart(.location), !isPaused else { return }
        busyActivities.insert(.location)
        locationError = nil
        defer { busyActivities.remove(.location) }
        do {
            try await bridgeService.requestLocationPermission()
            apply(try await bridgeService.snapshot())
        } catch {
            locationError = "定位权限检查或状态刷新失败：\(error.localizedDescription)"
            if let snapshot = try? await bridgeService.snapshot() {
                apply(snapshot)
            } else {
                invalidateLocationSnapshot()
            }
        }
    }

    func readLocation() async {
        guard canStart(.location), !isPaused, locationAuthorization == .authorized else { return }
        clearLocation()
        let requestID = locationRequestID
        busyActivities.insert(.location)
        defer { busyActivities.remove(.location) }
        do {
            let result = try await bridgeService.readLocation()
            apply(try await bridgeService.snapshot())
            guard locationRequestID == requestID else { return }
            guard locationAuthorization == .authorized else {
                locationError = "定位权限已变化，请重新检查权限。"
                return
            }
            if result.status == "succeeded", result.location != nil {
                locationResult = result
            } else {
                locationError = locationFailureMessage(result.stableError)
            }
        } catch {
            guard locationRequestID == requestID else { return }
            locationResult = nil
            locationError = "定位读取或状态刷新失败，请重新检查权限后再试。\(error.localizedDescription)"
            if let snapshot = try? await bridgeService.snapshot() {
                apply(snapshot)
            } else {
                invalidateLocationSnapshot()
            }
        }
    }

    private func locationFailureMessage(_ stableError: String?) -> String {
        switch stableError {
        case "permission_required": "定位权限不可用，请先检查并申请定位权限。"
        case "bridge_paused": "本地能力已暂停，恢复后可再次获取。"
        case "result_unverifiable": "这次未能取得可核实的位置（result_unverifiable）。请检查 Mac 定位服务和网络后重试。"
        case "execution_timeout": "本次定位超时（execution_timeout）。请检查 Mac 定位服务和网络后重试。"
        case "capability_disabled": "定位能力当前不可用（capability_disabled）。请检查系统定位服务状态。"
        default: "这次定位未成功（\(stableError ?? "未知错误")），请稍后重试。"
        }
    }

    private func invalidateLocationSnapshot() {
        locationAuthorization = .notChecked
        locationResult = nil
    }

    func readWeather(cityID: String) async {
        guard canStart(.weather), !isPaused else { return }
        clearWeather()
        let requestID = weatherRequestID
        busyActivities.insert(.weather)
        defer { busyActivities.remove(.weather) }
        do {
            let result = try await bridgeService.readWeather(cityID: cityID)
            apply(try await bridgeService.snapshot())
            guard weatherRequestID == requestID else { return }
            if result.status == "succeeded", let report = result.report, report.city.id == cityID {
                weatherResult = result
                weatherError = nil
            } else {
                weatherResult = nil
                weatherError = weatherFailureMessage(result.stableError)
            }
        } catch {
            guard weatherRequestID == requestID else { return }
            weatherResult = nil
            weatherError = "天气查询或最近动作刷新失败，请重新查询核对。\(error.localizedDescription)"
        }
    }

    private func weatherFailureMessage(_ stableError: String?) -> String {
        switch stableError {
        case "bridge_paused": "本地能力已暂停，请恢复后查询天气。"
        case "invalid_schema": "城市或天气数据无效，请重新选择城市。"
        case "network_unavailable": "天气服务暂时无法访问，请稍后重试。"
        default: "天气查询未成功（\(stableError ?? "未知错误")），请稍后重试。"
        }
    }

    private func apply(_ snapshot: BridgeSnapshot) {
        if snapshot.status == .paused || snapshot.status == .unavailable { clearQQChatPreview() }
        status = snapshot.status
        permissions = snapshot.permissions
        recentActions = snapshot.recentActions
        timers = snapshot.timers
        timerError = snapshot.timerError
        reminders = snapshot.reminders
        reminderError = snapshot.reminderError
        reminderReady = snapshot.reminderReady
        notesEnabled = snapshot.notesEnabled
        locationAuthorization = snapshot.locationAuthorization
        if locationAuthorization != .authorized { locationResult = nil }
        if !notesEnabled {
            notes = []
            selectedNote = nil
            notesResult = nil
        }
    }

    func requestNotificationPermission() async {
        guard canStart(.timers) else { return }
        busyActivities.insert(.timers)
        defer { busyActivities.remove(.timers) }
        do {
            try await bridgeService.requestNotificationPermission()
            apply(try await bridgeService.snapshot())
            lastErrorMessage = nil
        } catch {
            timerError = error.localizedDescription
            lastErrorMessage = error.localizedDescription
            if let snapshot = try? await bridgeService.snapshot() { apply(snapshot) }
        }
    }

    func createTimer(after seconds: TimeInterval, label: String) async {
        let id = UUID().uuidString.lowercased()
        await performTimerAction {
            try await self.bridgeService.createTimer(id: id, fireAt: Date().addingTimeInterval(seconds), label: label)
        }
    }

    func updateTimer(id: String, fireAt: Date?, label: String?) async {
        await performTimerAction { try await self.bridgeService.updateTimer(id: id, fireAt: fireAt, label: label) }
    }

    func cancelTimer(id: String) async {
        await performTimerAction { try await self.bridgeService.cancelTimer(id: id) }
    }

    private func performTimerAction(_ operation: () async throws -> TimerActionReadback) async {
        guard canStart(.timers), !isPaused else { return }
        busyActivities.insert(.timers)
        timerActionResult = nil
        defer { busyActivities.remove(.timers) }
        var completedResult: TimerActionReadback?
        do {
            let result = try await operation()
            completedResult = result
            let snapshot = try await bridgeService.snapshot()
            apply(snapshot)
            timerActionResult = result
            if result.outcome != .succeeded { timerError = result.message }
            lastErrorMessage = result.outcome == .succeeded ? nil : result.message
        } catch {
            timerActionResult = nil
            timerError = "计时器列表未刷新，当前显示上一次结果。"
            lastErrorMessage = completedResult == nil ? error.localizedDescription
                : "操作已有返回，但列表刷新失败；请刷新核对，不要重复创建。\(error.localizedDescription)"
        }
    }

    func enableReminders() async {
        guard canStart(.reminders), !isPaused else { return }
        busyActivities.insert(.reminders)
        reminderActionResult = nil
        defer { busyActivities.remove(.reminders) }
        do {
            try await bridgeService.enableReminders()
            apply(try await bridgeService.snapshot())
            lastErrorMessage = nil
        } catch {
            reminderError = error.localizedDescription
            lastErrorMessage = error.localizedDescription
            if let snapshot = try? await bridgeService.snapshot() { apply(snapshot) }
        }
    }

    func createReminder(title: String, dueAt: Date) async {
        let id = UUID().uuidString.lowercased()
        await performReminderAction {
            try await self.bridgeService.createReminder(id: id, title: title, dueAt: dueAt)
        }
    }

    func updateReminder(id: String, title: String?, dueAt: Date?) async {
        await performReminderAction {
            try await self.bridgeService.updateReminder(id: id, title: title, dueAt: dueAt)
        }
    }

    func completeReminder(id: String, completed: Bool) async {
        await performReminderAction {
            try await self.bridgeService.completeReminder(id: id, completed: completed)
        }
    }

    private func performReminderAction(_ operation: () async throws -> ReminderActionReadback) async {
        guard canStart(.reminders), !isPaused, reminderReady else { return }
        busyActivities.insert(.reminders)
        reminderActionResult = nil
        defer { busyActivities.remove(.reminders) }
        var completedResult: ReminderActionReadback?
        do {
            let result = try await operation()
            completedResult = result
            apply(try await bridgeService.snapshot())
            reminderActionResult = result
            if result.outcome != .succeeded { reminderError = result.message }
            lastErrorMessage = result.outcome == .succeeded ? nil : result.message
        } catch {
            reminderActionResult = nil
            reminderError = "提醒事项列表未刷新，当前显示上一次结果。"
            lastErrorMessage = completedResult == nil ? error.localizedDescription
                : "操作已有返回，但列表刷新失败；请刷新核对，不要重复创建。\(error.localizedDescription)"
        }
    }

    func enableNotes() async {
        guard canStart(.notes), !isPaused else { return }
        busyActivities.insert(.notes)
        notesResult = nil
        notesError = nil
        defer { busyActivities.remove(.notes) }
        do {
            try await bridgeService.enableNotes()
            apply(try await bridgeService.snapshot())
            guard notesEnabled else {
                notesError = "备忘录连接状态未能确认，请重试连接。"
                return
            }
            let result = try await bridgeService.listNotes(query: "")
            apply(try await bridgeService.snapshot())
            if notesEnabled { acceptNotesResult(result, listUpdate: .replace, updateSelection: false) }
        } catch {
            notesResult = nil
            notesError = error.localizedDescription
            if let snapshot = try? await bridgeService.snapshot() { apply(snapshot) }
        }
    }

    func listNotes(query: String) async {
        await performNotesAction(listUpdate: .replace, updateSelection: false) {
            try await self.bridgeService.listNotes(query: query)
        }
    }

    func readNote(id: String) async {
        guard canStart(.notes), !isPaused, notesEnabled else { return }
        // A failed read must never leave the previous note under the new selection.
        selectedNote = nil
        await performNotesAction(listUpdate: .none, updateSelection: true) {
            try await self.bridgeService.readNote(id: id)
        }
    }

    func createNote(title: String, text: String) async {
        let id = UUID().uuidString.lowercased()
        await performNotesAction(listUpdate: .merge, updateSelection: true) {
            try await self.bridgeService.createNote(id: id, title: title, text: text)
        }
    }

    func appendNote(text: String) async {
        guard let selectedNote, selectedNote.canAppend else { return }
        let id = selectedNote.id
        let revision = selectedNote.revision
        await performNotesAction(listUpdate: .merge, updateSelection: true) {
            try await self.bridgeService.appendNote(id: id, text: text, expectedRevision: revision)
        }
    }

    private func performNotesAction(
        listUpdate: NotesListUpdate,
        updateSelection: Bool,
        _ operation: () async throws -> LocalNotesCommandResult
    ) async {
        guard canStart(.notes), !isPaused, notesEnabled else { return }
        busyActivities.insert(.notes)
        notesResult = nil
        notesError = nil
        defer { busyActivities.remove(.notes) }
        do {
            let result = try await operation()
            apply(try await bridgeService.snapshot())
            if notesEnabled {
                acceptNotesResult(result, listUpdate: listUpdate, updateSelection: updateSelection)
            } else {
                notesError = "备忘录连接已失效，请重新连接。"
            }
        } catch {
            notesResult = nil
            if updateSelection { selectedNote = nil }
            notesError = "备忘录操作或最近动作刷新失败；请重新查询核对。\(error.localizedDescription)"
        }
    }

    private enum NotesListUpdate { case none, replace, merge }

    private func acceptNotesResult(_ result: LocalNotesCommandResult, listUpdate: NotesListUpdate, updateSelection: Bool) {
        notesResult = result
        guard result.status == "succeeded" else {
            if updateSelection { selectedNote = nil }
            notesError = notesFailureMessage(result.stableError)
            return
        }
        switch listUpdate {
        case .none: break
        case .replace: notes = result.notes
        case .merge:
            for item in result.notes {
                if let index = notes.firstIndex(where: { $0.id == item.id }) {
                    notes[index] = item
                } else {
                    notes.append(item)
                }
            }
        }
        if updateSelection { selectedNote = result.note }
    }

    private func notesFailureMessage(_ stableError: String?) -> String {
        switch stableError {
        case "bridge_paused": "本地能力已暂停，请恢复后再管理备忘录。"
        case "permission_required": "需要允许工作台访问备忘录；请重新连接并完成系统授权。"
        case "capability_disabled": "备忘录专用文件夹尚未连接，请先连接。"
        case "result_unverifiable", "execution_timeout": "写入或读取结果无法核实，请重新连接并核对待定写入；不要重复创建或追加。"
        case "revision_conflict", "invalid_schema": "内容或版本已变化、目标不存在或参数无效，请重新读取后核对。"
        default: "备忘录操作未成功（\(stableError ?? "未知错误")），请重新查询核对。"
        }
    }
}
