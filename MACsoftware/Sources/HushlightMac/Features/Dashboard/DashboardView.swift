import SwiftUI
import BridgeCore
import WorkbenchKit

struct DashboardView: View {
    @ObservedObject var model: AppModel
    let host: WorkbenchHost?
    @ObservedObject var automation: AutomationCenterModel
    @ObservedObject var speechInput: MacSpeechInputModel
    @ObservedObject var windowVision: WindowVisionModel
    @ObservedObject var voiceCommands: VoiceCommandModel
    @StateObject private var agentManager: AgentManager
    @State private var timerLabel = "休息一下"
    @State private var timerSeconds = 300
    @State private var editingTimerID: String?
    @State private var editLabel = ""
    @State private var editDate = Date()
    @State private var reminderTitle = ""
    @State private var reminderDueAt = Date().addingTimeInterval(3600)
    @State private var editingReminderID: String?
    @State private var editReminderTitle = ""
    @State private var editReminderDueAt = Date()
    @State private var notesQuery = ""
    @State private var newNoteTitle = ""
    @State private var newNoteBody = ""
    @State private var appendText = ""
    @State private var selectedWeatherCityID = WeatherCities.all.first?.id ?? ""
    @State private var mailQuery = ""
    @State private var mailUnreadOnly = false
    @State private var draftSender = ""
    @State private var draftTo = ""
    @State private var draftCc = ""
    @State private var draftBcc = ""
    @State private var draftSubject = ""
    @State private var draftText = ""
    @State private var mailSection = "read"

    init(model: AppModel, host: WorkbenchHost?, automation: AutomationCenterModel, speechInput: MacSpeechInputModel, windowVision: WindowVisionModel, voiceCommands: VoiceCommandModel) {
        self.voiceCommands = voiceCommands
        self.windowVision = windowVision
        self.speechInput = speechInput
        self.automation = automation
        self.model = model
        self.host = host
        _agentManager = StateObject(wrappedValue: AgentManager(host: host))
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { Optional(model.selectedPage) },
                set: { model.selectPage($0 ?? .overview) }
            )) {
                Section("工作台") { navigationRows([.overview, .agents, .automationCenter]) }
                Section("Mac 能力") { navigationRows([.volume, .timers, .reminders, .notes, .weather, .location, .mail, .calendar, .music, .qqChat, .voice, .windowVision]) }
                Section("管理") { navigationRows([.permissions, .history]) }
            }
            .navigationTitle("Orbit 智轨")
            .listStyle(.sidebar)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    pageContent
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(model.isPaused ? "恢复本地能力" : "暂停本地能力") {
                        Task { await model.togglePause() }
                    }
                    .disabled(model.isBusy(.pause))
                    .accessibilityIdentifier("globalPause")
                }
            }
        }
        .task {
            await model.refresh()
            await agentManager.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await model.refreshLocationAuthorization()
                await model.refresh()
                await agentManager.load()
            }
        }
        .sheet(isPresented: Binding(get: { model.mailSendPreview != nil }, set: { if !$0 { model.dismissMailSendPreview() } })) {
            if let draft = model.mailSendPreview {
                VStack(alignment: .leading, spacing: 14) {
                    Text("确认发送这封邮件").font(.title2.bold())
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("发件人：\(draft.sender)")
                            Text("收件人：\(draft.to.joined(separator: ", "))")
                            Text("抄送：\(draft.cc.joined(separator: ", "))")
                            Text("密送：\(draft.bcc.joined(separator: ", "))")
                            Text("主题：\(draft.subject)").fontWeight(.medium)
                            Divider()
                            Text(draft.text).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text("附件：无。发送前会再次核对全部内容；请先停止在 Mail 中编辑此草稿。确认后无法撤回。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("暂不发送") { model.dismissMailSendPreview() }
                            .keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("确认发送") { Task { await model.confirmMailSend(host: host) } }
                            .disabled(model.isPaused || model.isBusy(.mail))
                            .accessibilityIdentifier("confirmMailSend")
                    }
                }
                .padding(24).frame(width: 640, height: 600)
            }
        }
    }

    private func navigationRows(_ pages: [WorkbenchPage]) -> some View {
        ForEach(pages) { page in
            Label(page.title, systemImage: page.symbol).tag(page)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.selectedPage.title)
                .font(.largeTitle.bold())
            Text(model.selectedPage == .agents ? "管理本机 Agent 的连接与授权。" : "在获得授权后，安全地使用这台 Mac 的本地能力。")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch model.selectedPage {
        case .overview:
            statusCard
            agentStatusCard
            recentActionsCard
        case .agents:
            AgentsView(manager: agentManager)
                .task { await agentManager.load() }
        case .automationCenter: AutomationCenterView(model: automation)
        case .calendar: WorkbenchCalendarView(model: automation)
        case .music: qqMusicCard
        case .qqChat: QQChatPreviewView(model: model)
        case .voice: VoiceInputView(model: speechInput, commands: voiceCommands, isPaused: model.isPaused || model.isBusy(.pause))
        case .windowVision: WindowVisionView(model: windowVision, isPaused: model.isPaused || model.isBusy(.pause))
        case .volume: volumeCard
        case .timers: timersCard
        case .reminders: remindersCard
        case .notes: notesCard
        case .weather: weatherCard
        case .location: locationCard
        case .mail: mailCard
        case .permissions:
            WorkbenchSettingsView(model: automation)
            permissionsCard
        case .history: recentActionsCard
        }
    }

    private var qqMusicCard: some View {
        GroupBox("QQ 音乐连接检查") {
            VStack(alignment: .leading, spacing: 12) {
                Text("检查已注册的 QQ 音乐及其进程，不启动应用、不申请新权限。")
                    .foregroundStyle(.secondary)
                Button("检查安装与运行状态") { Task { await model.readQQMusicStatus() } }
                    .disabled(model.isPaused || model.isBusy(.music))
                if let value = model.qqMusicReadback {
                    Text(value.installed ? "已找到 QQ 音乐" : "未找到已注册的 QQ 音乐")
                    Text(value.running ? "进程正在运行" : "进程未运行")
                    if let version = value.version { Text("版本：" + version) }
                    Text("核对时间：" + value.checkedAt.formatted()).font(.caption)
                }
                if let error = model.qqMusicError { Text(error).foregroundStyle(.orange) }
                Divider()
                Text("播放控制使用辅助功能。系统权限较广；工作台仅操作 QQ 音乐播放控制栏。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("检查并申请辅助功能") { Task { await model.requestQQMusicAccess() } }
                    Button("读取播放状态") { Task { await model.readQQMusicPlayback() } }
                }.disabled(model.isPaused || model.isBusy(.music))
                if let message = model.qqMusicAccessMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                if let playback = model.qqMusicPlaybackReadback {
                    Text(playback.playing ? "正在播放（已回读控件）" : "已暂停（已回读控件）")
                    if let track = playback.track { Text(track).textSelection(.enabled) }
                    Text("核对时间：" + playback.checkedAt.formatted()).font(.caption)
                }
                HStack {
                    Button("上一首") { Task { await model.performQQMusic(.previous) } }
                    Button("播放") { Task { await model.performQQMusic(.play) } }
                    Button("暂停") { Task { await model.performQQMusic(.pause) } }
                    Button("下一首") { Task { await model.performQQMusic(.next) } }
                }.disabled(model.isPaused || model.isBusy(.music) || model.qqMusicPlaybackReadback == nil)
                Divider()
                Text("按歌曲直接播放").font(.headline)
                TextField("歌曲名", text: $model.songTitle).disabled(model.isBusy(.music))
                TextField("歌手（可选，有同名歌曲时建议填写）", text: $model.songArtist).disabled(model.isBusy(.music))
                Picker("版本", selection: $model.songVersion) {
                    Text("原版").tag(QQSongVersion.original)
                    Text("Live / 现场").tag(QQSongVersion.live)
                }.disabled(model.isBusy(.music))
                Text("使用既有辅助功能与屏幕录制权限在本机搜索、选曲和回读。指定歌曲即授权播放；没有唯一候选时明确失败。QQ需已打开，播放时会切到QQ主窗口；不会自动购买或下载。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("搜索并直接播放") {
                    let title = model.songTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    let artist = model.songArtist.trimmingCharacters(in: .whitespacesAndNewlines)
                    let request = QQSongRequest(title: title, artist: artist.isEmpty ? nil : artist, version: model.songVersion)
                    Task { await model.searchAndPlayQQSong(request) }
                }.disabled(model.isPaused || model.isBusy(.music) || model.songTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.songPending != nil)
                if let result = model.songPlayResult {
                    Text("请求：" + result.requestID).font(.caption).textSelection(.enabled)
                    Text(result.displayMessage)
                        .foregroundStyle(result.status == "succeeded" ? Color.primary : Color.orange)
                }
                if let pending = model.songPending {
                    Text("待核对播放请求：" + pending.requestID).font(.caption).foregroundStyle(.orange)
                    Button("我已核对实际曲目，允许新播放请求") { Task { await model.acknowledgeQQSong() } }
                        .disabled(model.isPaused || model.isBusy(.music))
                    Text("只解除未知记录的阻塞，不重新执行旧请求。").font(.caption).foregroundStyle(.secondary)
                }
                Text("每次控制后回读，无法核实时显示未知；搜索播放不会要求额外确认。")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }.task { await model.refreshQQSongPending() }
    }

    private var statusCard: some View {
        GroupBox {
            HStack(spacing: 16) {
                Image(systemName: model.status.menuBarSymbol)
                    .font(.system(size: 30))
                    .foregroundStyle(statusColor)
                    .frame(width: 48, height: 48)
                    .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.status.title)
                        .font(.title3.bold())
                    Text(model.status.detail)
                        .foregroundStyle(.secondary)
                }

                Spacer()

            }

            if let message = model.lastErrorMessage {
                Divider()
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } label: {
            Label("Bridge 状态", systemImage: "link")
        }
    }

    private var agentStatusCard: some View {
        GroupBox("Agent 连接") {
            VStack(alignment: .leading, spacing: 10) {
                Label(agentManager.isConnected ? "本机服务已启动" : "本机服务未连接",
                      systemImage: agentManager.isConnected ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(agentManager.isConnected ? .green : .orange)
                HStack(spacing: 24) {
                    Text("已登记：\(agentManager.clients.count)")
                    Text("可用授权：\(agentManager.clients.filter { !$0.revoked && !$0.grants.isEmpty }.count)")
                    Text("最近动作记录：\(agentManager.history.count)")
                }
                .foregroundStyle(.secondary)
                Text("登记和授权数量来自本机记录；当前 Socket 会话数未统计。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let error = agentManager.errorMessage {
                    Text(error).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var permissionsCard: some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(Array(model.permissions.enumerated()), id: \.element.id) { index, permission in
                    if index > 0 { Divider() }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: permission.state == .granted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(permission.state == .granted ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(permission.kind.title).fontWeight(.medium)
                            Text(permission.kind.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(permission.state.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                }
            }
        } label: {
            Label("权限", systemImage: "checkmark.shield")
        }
    }

    private var volumeCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("读取默认输出设备，不改变系统音量。")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("读取系统音量") {
                        Task { await model.readSystemVolume() }
                    }
                    .disabled(model.isBusy(.volume) || model.isPaused)
                    .accessibilityIdentifier("readSystemVolume")
                }
                if let error = model.volumeError { Text(error).foregroundStyle(.orange) }
                if let reading = model.volumeReadback {
                    if reading.isSimulation {
                        Text("模拟结果 · 未读取真实设备")
                            .foregroundStyle(.orange)
                    }
                    if reading.outcome == .succeeded, let value = reading.value {
                        Text("音量：\(Int(value.rounded()))%")
                            .font(.title3.bold())
                        Text(reading.muted.map { $0 ? "系统已静音" : "系统未静音" } ?? "静音状态不可读取")
                        Text("读取时间：\(reading.readAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(reading.errorMessage ?? "读取结果未知")
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text(model.isPaused ? "本地能力已暂停，恢复后可读取。" : "尚未读取音量")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("系统音量", systemImage: "speaker.wave.2")
        }
    }

    private var recentActionsCard: some View {
        GroupBox {
            if model.recentActions.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("还没有本地动作")
                        .font(.headline)
                    Text("执行能力后，这里显示实际返回的结果。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.recentActions) { action in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(action.name)
                                Spacer()
                                Text(action.outcome.title)
                                    .foregroundStyle(.secondary)
                                Text(action.occurredAt, style: .time)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(action.callerID == "local_ui" ? "本机界面" : "Agent：\(action.callerID)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let correlationID = action.correlationID {
                                Text("请求：\(correlationID)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }
                            if let error = action.stableError {
                                Text("原因：\(error)")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        } label: {
            Label("最近动作", systemImage: "clock.arrow.circlepath")
        }
    }

    private var timersCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("保存在这台 Mac，到时由系统通知。")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("刷新计时器") { Task { await model.refresh() } }
                        .disabled(model.isBusy(.timers))
                }
                if notificationState != .granted {
                    Text(notificationState == .denied
                         ? "通知已拒绝，请在系统设置的通知中开启；未授权时不会创建计时器。"
                         : "首次使用时允许通知，不会申请麦克风、定位或辅助功能权限。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("允许通知") { Task { await model.requestNotificationPermission() } }
                        .disabled(model.isBusy(.timers))
                }
                if let error = model.timerError {
                    Text(error).foregroundStyle(.orange)
                }
                TextField("提醒内容", text: $timerLabel)
                    .accessibilityIdentifier("timerLabel")
                HStack {
                    Text("多少秒后提醒")
                    TextField("秒", value: $timerSeconds, format: .number)
                        .frame(width: 100)
                        .accessibilityIdentifier("timerSeconds")
                    Text("5–86400 秒").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("创建计时器") {
                        Task { await model.createTimer(after: Double(timerSeconds), label: timerLabel) }
                    }
                    .disabled(model.isBusy(.timers) || model.isPaused || notificationState != .granted
                              || !(5...86_400).contains(timerSeconds)
                              || timerLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let result = model.timerActionResult {
                    Text(result.message)
                        .font(.caption)
                        .foregroundStyle(result.outcome == .succeeded ? Color.secondary : Color.orange)
                }
                if model.timers.isEmpty {
                    Text(model.timerError == nil ? "暂无待触发计时器" : "计时器列表待核对")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.timers, id: \.id) { timer in
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(timer.label)
                            Text(timer.fireAt.formatted(date: .abbreviated, time: .standard))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("修改") {
                            editingTimerID = timer.id
                            editLabel = timer.label
                            editDate = timer.fireAt
                        }
                        Button("取消计时器") { Task { await model.cancelTimer(id: timer.id) } }
                    }
                    .disabled(model.isBusy(.timers) || model.isPaused)
                    DisclosureGroup("核对计时器标识") {
                        Text(timer.id).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                if let id = editingTimerID {
                    Divider()
                    Text("修改计时器").fontWeight(.medium)
                    TextField("修改提醒内容", text: $editLabel)
                    DatePicker("提醒时间", selection: $editDate, displayedComponents: [.date, .hourAndMinute])
                    HStack {
                        Button("保存修改") {
                            Task {
                                await model.updateTimer(id: id, fireAt: editDate, label: editLabel)
                                if model.timerActionResult?.outcome == .succeeded { editingTimerID = nil }
                            }
                        }
                        .disabled(model.isBusy(.timers) || model.isPaused || editLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("放弃修改") { editingTimerID = nil }.disabled(model.isBusy(.timers))
                    }
                }
                Text("暂停会阻止新操作，已安排的计时器仍会到时提醒；需要停止时先取消计时器。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("计时器", systemImage: "timer")
        }
    }

    private var notificationState: PermissionState {
        model.permissions.first { $0.kind == .notifications }?.state ?? .notRequested
    }

    private var remindersCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("只显示和管理已连接的专用列表中由 Bridge 创建的提醒事项。")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("刷新提醒事项") { Task { await model.refresh() } }
                        .disabled(model.isBusy(.reminders))
                }
                if !model.reminderReady {
                    Text(reminderPermissionState == .denied
                         ? "提醒事项权限已拒绝，请在系统设置中允许完整访问后重试。"
                         : "首次使用需允许完整提醒事项访问；工作台只读取其专用列表。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("允许提醒事项并创建专用列表") {
                        Task { await model.enableReminders() }
                    }
                    .disabled(model.isBusy(.reminders) || model.isPaused)
                    .accessibilityIdentifier("enableReminders")
                }
                if let error = model.reminderError {
                    Text(error).foregroundStyle(.orange)
                }
                if model.reminderReady {
                    TextField("提醒内容", text: $reminderTitle)
                        .accessibilityIdentifier("reminderTitle")
                    HStack {
                        DatePicker("提醒时间", selection: $reminderDueAt,
                                   displayedComponents: [.date, .hourAndMinute])
                            .accessibilityIdentifier("reminderDueAt")
                        Button("创建提醒事项") {
                            Task { await model.createReminder(title: reminderTitle, dueAt: reminderDueAt) }
                        }
                        .disabled(model.isBusy(.reminders) || model.isPaused
                                  || reminderTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || reminderDueAt <= Date())
                        .accessibilityIdentifier("createReminder")
                    }
                    if model.reminders.isEmpty {
                        Text("专用列表中暂无提醒事项")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.reminders, id: \.id) { reminder in
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(reminder.title)
                                    .strikethrough(reminder.isCompleted)
                                Text(reminder.dueAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("修改") {
                                editingReminderID = reminder.id
                                editReminderTitle = reminder.title
                                editReminderDueAt = reminder.dueAt
                            }
                            Button(reminder.isCompleted ? "恢复" : "完成") {
                                Task { await model.completeReminder(id: reminder.id,
                                                                    completed: !reminder.isCompleted) }
                            }
                        }
                        .disabled(model.isBusy(.reminders) || model.isPaused)
                    }
                    if let id = editingReminderID {
                        Divider()
                        Text("修改提醒事项").fontWeight(.medium)
                        TextField("修改提醒内容", text: $editReminderTitle)
                        DatePicker("提醒时间", selection: $editReminderDueAt,
                                   displayedComponents: [.date, .hourAndMinute])
                        HStack {
                            Button("保存修改") {
                                Task {
                                    await model.updateReminder(id: id, title: editReminderTitle,
                                                               dueAt: editReminderDueAt)
                                    if model.reminderActionResult?.outcome == .succeeded {
                                        editingReminderID = nil
                                    }
                                }
                            }
                            .disabled(model.isBusy(.reminders) || model.isPaused
                                      || editReminderTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("放弃修改") { editingReminderID = nil }
                                .disabled(model.isBusy(.reminders))
                        }
                    }
                }
                if let result = model.reminderActionResult {
                    Text(result.message)
                        .font(.caption)
                        .foregroundStyle(result.outcome == .succeeded ? Color.secondary : Color.orange)
                }
                Text("暂停会阻止新操作，已创建的提醒仍保留在系统提醒事项中。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("提醒事项", systemImage: "checklist")
        }
    }

    private var reminderPermissionState: PermissionState {
        model.permissions.first { $0.kind == .reminders }?.state ?? .notRequested
    }

    private var notesCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("每次启动工作台都需显式连接。仅在工作台专用文件夹内查询、读取、创建备忘录；只有 Bridge 创建且未被外部修改的纯文本备忘录可追加。不支持富文本改写、附件或删除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !model.notesEnabled {
                    Button("连接备忘录并启用专用文件夹") {
                        Task { await model.enableNotes() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy(.notes) || model.isPaused)
                    .accessibilityIdentifier("enableNotes")
                } else {
                    Button("重新连接并核对待定写入") { Task { await model.enableNotes() } }
                        .disabled(model.isBusy(.notes) || model.isPaused)
                    HStack {
                        TextField("按标题搜索专用文件夹", text: $notesQuery)
                            .accessibilityIdentifier("notesQuery")
                        Button("查询") { Task { await model.listNotes(query: notesQuery) } }
                            .disabled(model.isBusy(.notes) || model.isPaused)
                            .accessibilityIdentifier("listNotes")
                    }

                    if model.notes.isEmpty {
                        Text("专用文件夹中暂无匹配备忘录")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.notes, id: \.id) { note in
                        HStack {
                            Text(note.title)
                            Spacer()
                            Button("读取详情") { Task { await model.readNote(id: note.id) } }
                                .disabled(model.isBusy(.notes) || model.isPaused)
                                .accessibilityIdentifier("readNote-\(note.id)")
                        }
                    }

                    if let selected = model.selectedNote {
                        Divider()
                        Text(selected.title).font(.headline)
                        Text(selected.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("selectedNoteText")
                        if selected.canAppend {
                            TextField("追加纯文本", text: $appendText, axis: .vertical)
                                .accessibilityIdentifier("appendNoteText")
                            Button("追加到此备忘录") {
                                Task {
                                    await model.appendNote(text: appendText)
                                    if model.notesResult?.status == "succeeded" { appendText = "" }
                                }
                            }
                            .disabled(model.isBusy(.notes) || model.isPaused || appendText.isEmpty)
                            .accessibilityIdentifier("appendNote")
                        } else {
                            Text("此备忘录无法追加：仅支持 Bridge 创建且未被外部修改的纯文本。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Divider()
                    Text("创建纯文本备忘录").fontWeight(.medium)
                    TextField("标题", text: $newNoteTitle)
                        .accessibilityIdentifier("newNoteTitle")
                    TextField("正文", text: $newNoteBody, axis: .vertical)
                        .accessibilityIdentifier("newNoteBody")
                    Button("创建备忘录") {
                        Task {
                            await model.createNote(title: newNoteTitle, text: newNoteBody)
                            if model.notesResult?.status == "succeeded" {
                                newNoteTitle = ""
                                newNoteBody = ""
                            }
                        }
                    }
                    .disabled(model.isBusy(.notes) || model.isPaused
                              || newNoteTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("createNote")
                }

                if let error = model.notesError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let result = model.notesResult {
                    if result.isSimulation {
                        Text("模拟结果 · 未访问真实备忘录")
                            .foregroundStyle(.orange)
                    }
                    if result.status == "succeeded" {
                        Text("备忘录操作已完成 · \(result.completedAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("备忘录", systemImage: "note.text")
        }
    }

    private var weatherCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("选择城市后手动查询。展示的是 MET Norway 的天气预报。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Picker("城市", selection: $selectedWeatherCityID) {
                        ForEach(WeatherCities.all, id: \.id) { city in
                            Text("\(city.name) · \(city.region)").tag(city.id)
                        }
                    }
                    .frame(maxWidth: 320)
                    .onChange(of: selectedWeatherCityID) { _ in model.clearWeather() }
                    Button("查询天气") {
                        Task { await model.readWeather(cityID: selectedWeatherCityID) }
                    }
                    .disabled(model.isBusy(.weather) || model.isPaused || selectedWeatherCityID.isEmpty)
                    .accessibilityIdentifier("readWeather")
                }

                if let error = model.weatherError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if let result = model.weatherResult,
                          result.status == "succeeded", let report = result.report {
                    Divider()
                    Text("\(report.city.name) · 当前时段预报")
                        .font(.headline)
                    Text(weatherCondition(report.current.symbol))
                    Text("\(weatherTemperature(report.current.temperatureC)) · 湿度 \(report.current.relativeHumidityPercent.formatted(.number.precision(.fractionLength(0))))% · 风速 \(report.current.windSpeedMS.formatted(.number.precision(.fractionLength(1)))) m/s")
                        .font(.title3)
                    Text("预报时段：\(weatherTime(report.current.time, timeZoneID: report.city.timeZoneID))")
                        .font(.caption).foregroundStyle(.secondary)

                    if !report.hourly.isEmpty {
                        Text("未来 12 小时").fontWeight(.medium)
                        ForEach(Array(report.hourly.enumerated()), id: \.offset) { _, point in
                            HStack {
                                Text(weatherTime(point.time, timeZoneID: report.city.timeZoneID))
                                Spacer()
                                Text(weatherTemperature(point.temperatureC))
                                Text(weatherCondition(point.symbol))
                                Text("湿度 \(point.relativeHumidityPercent.formatted(.number.precision(.fractionLength(0))))%")
                                Text("风 \(point.windSpeedMS.formatted(.number.precision(.fractionLength(1)))) m/s")
                            }
                            .font(.caption)
                        }
                    }
                    Divider()
                    Text("模式更新时间：\(weatherTime(report.modelUpdatedAt, timeZoneID: report.city.timeZoneID))")
                    Text("获取时间：\(weatherTime(report.fetchedAt, timeZoneID: report.city.timeZoneID))")
                    if report.isCached { Text("缓存结果") }
                    if result.isSimulation { Text("模拟结果 · 未查询真实天气").foregroundStyle(.orange) }
                } else {
                    Text(model.isPaused ? "本地能力已暂停，恢复后可查询。" : "尚未查询天气")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Text("数据来源：")
                    Link("MET Norway", destination: URL(string: "https://api.met.no/")!)
                    Text("·")
                    Link("CC BY 4.0", destination: URL(string: "https://docs.api.met.no/doc/License")!)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("天气", systemImage: "cloud.sun")
        }
    }

    private var mailCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("只搜索所选邮箱的标题和发件人，点击单封邮件后读取纯文本正文。")
                    .foregroundStyle(.secondary)
                Button("列出账户和邮箱") { Task { await model.discoverMailScopes() } }
                    .disabled(model.isBusy(.mail) || model.isPaused)
                    .accessibilityIdentifier("discoverMailScopes")
                if let selected = model.selectedMailScope {
                    let label = model.mailScopeOptions.first(where: { $0.key == selected })?.displayName
                        ?? selected.mailboxPath.joined(separator: " / ")
                    Text("已选择：\(label)")
                        .fontWeight(.medium)
                    Text(model.mailScopeVerified ? "本次已核对账户和邮箱路径。" : "搜索或读取时会重新核对上次选择的账户和邮箱路径。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("尚未选择邮箱")
                        .foregroundStyle(.secondary)
                }
                if let error = model.mailScopeError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                ForEach(model.mailScopeOptions) { option in
                    HStack {
                        Text(option.displayName)
                            .lineLimit(2)
                        Spacer()
                        Button(model.selectedMailScope == option.key ? "重新核对" : "选择") {
                            Task { await model.selectMailScope(option.key) }
                        }
                        .disabled(model.isBusy(.mail) || model.isPaused)
                    }
                    .padding(.vertical, 4)
                }
                Divider()
                Picker("邮件操作", selection: $mailSection) {
                    Text("读取邮件").tag("read")
                    Text("写草稿").tag("draft")
                    Text("发送确认").tag("queue")
                }.pickerStyle(.segmented)
                if mailSection == "read" {
                TextField("搜索标题或发件人", text: $mailQuery)
                    .textFieldStyle(.roundedBorder)
                Toggle("只看未读", isOn: $mailUnreadOnly)
                HStack {
                    Button("搜索邮件") { Task { await model.searchMail(query: mailQuery, unreadOnly: mailUnreadOnly) } }
                        .disabled(model.isBusy(.mail) || model.isPaused || model.selectedMailScope == nil)
                        .accessibilityIdentifier("searchMail")
                    Button("清除邮件显示") { model.clearMailResults() }
                        .disabled(model.mailMessages.isEmpty && model.selectedMail == nil && model.mailReadError == nil)
                }
                Text("首版最多核对 1000 封邮件、返回 50 条结果。结果过多时请填写更具体的标题或发件人。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.mailReadError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if model.mailHasSearched && model.mailMessages.isEmpty { Text("没有匹配邮件").foregroundStyle(.secondary) }
                if model.mailIsSimulation { Text("模拟结果 · 未读取真实邮件").foregroundStyle(.orange) }
                ForEach(model.mailMessages, id: \.id) { message in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text((message.isUnread ? "● " : "") + (message.subject.isEmpty ? "（无主题）" : message.subject))
                                .fontWeight(.medium)
                            Text(message.sender).font(.caption).foregroundStyle(.secondary)
                            Text(message.receivedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("读取正文") { Task { await model.readMail(id: message.id) } }
                            .disabled(model.isBusy(.mail) || model.isPaused)
                    }
                    .padding(.vertical, 5)
                }
                if let mail = model.selectedMail {
                    Divider()
                    Text(mail.message.subject.isEmpty ? "（无主题）" : mail.message.subject).font(.headline)
                    Text(mail.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("正文只在本次窗口显示，不保存到执行记录。Agent 需要单独的邮箱读取授权。")
                    .font(.caption).foregroundStyle(.secondary)
                }
                if mailSection == "draft" {
                Divider()
                Text("写草稿").font(.headline)
                TextField("发件地址（必须属于所选账户）", text: $draftSender)
                TextField("收件人（多个地址用逗号分隔）", text: $draftTo)
                TextField("抄送（可选）", text: $draftCc)
                TextField("密送（可选）", text: $draftBcc)
                TextField("主题", text: $draftSubject)
                TextEditor(text: $draftText).frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                Button("保存到 Mail 草稿") {
                    Task { await model.createMailDraft(input: .init(sender: draftSender.trimmingCharacters(in: .whitespacesAndNewlines),
                        to: mailAddresses(draftTo), cc: mailAddresses(draftCc), bcc: mailAddresses(draftBcc), subject: draftSubject, text: draftText)) }
                }
                .disabled(model.isBusy(.mail) || model.isPaused || model.selectedMailScope == nil)
                }
                if let error = model.mailDraftError { Text(error).foregroundStyle(.orange) }
                if let message = model.mailSendMessage { Text(message).foregroundStyle(.secondary) }
                if mailSection == "queue" {
                HStack {
                    Text("工作台草稿和发送请求").font(.headline)
                    Spacer()
                    Button("刷新草稿记录") { Task { await model.refreshMailDrafts() } }
                }
                ForEach(model.mailDraftEntries) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("草稿 \(entry.id)").font(.caption)
                            Text("状态：\(mailDraftState(entry.state))").font(.caption)
                            Text(entry.owner == "local_ui" ? "来源：本机界面" : "来源：Agent \(entry.owner)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if ["draft", "awaiting_confirmation"].contains(entry.state) {
                            Button("核对并发送…") { Task { await model.prepareMailSend(id: entry.id) } }
                                .disabled(model.isBusy(.mail) || model.isPaused)
                        }
                    }
                }
                if model.mailDraftEntries.isEmpty { Text("尚无工作台草稿或发送请求").foregroundStyle(.secondary) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Apple Mail 邮箱范围", systemImage: "envelope")
        }
        .task { await model.loadMailScope(); await model.refreshMailDrafts() }
    }

    private func mailAddresses(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    private func mailDraftState(_ state: String) -> String {
        switch state {
        case "draft": "已保存，未发送"
        case "awaiting_confirmation": "等待你确认发送"
        case "submitted": "Mail 已接受发送，未证明送达"
        case "unknown": "结果未知，请在 Mail 核对，勿重发"
        case "creating": "正在创建"
        case "dispatching": "正在提交发送"
        default: state
        }
    }

    private var locationCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("约公里级，只在点击时获取一次，不自动共享给天气，不持续跟踪。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(locationAuthorizationMessage)
                    .foregroundStyle(model.locationAuthorization == .authorized ? Color.secondary : Color.orange)
                HStack {
                    Button("检查并申请定位权限") {
                        Task { await model.requestLocationPermission() }
                    }
                    .disabled(model.isBusy(.location) || model.isPaused)
                    .accessibilityIdentifier("requestLocationPermission")
                    Button("获取一次大致位置") {
                        Task { await model.readLocation() }
                    }
                    .disabled(model.isBusy(.location) || model.isPaused || model.locationAuthorization != .authorized)
                    .accessibilityIdentifier("readLocation")
                    Button("清除位置显示") { model.clearLocation() }
                        .disabled(model.locationResult == nil && model.locationError == nil)
                        .accessibilityIdentifier("clearLocation")
                }
                if let error = model.locationError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if let result = model.locationResult, let location = result.location {
                    Divider()
                    Text("约 \(location.latitude.formatted(.number.precision(.fractionLength(2))))°, \(location.longitude.formatted(.number.precision(.fractionLength(2))))°")
                        .font(.title3.bold())
                    Text("水平精度：约 \(location.horizontalAccuracyMeters.formatted(.number.precision(.fractionLength(0)))) 米")
                    Text("采样时间：\(location.timestamp.formatted(date: .abbreviated, time: .standard))")
                    Text("来源：\(location.source)")
                    if location.isApproximate { Text("大致位置") }
                    if result.isSimulation { Text("模拟结果 · 未读取真实位置").foregroundStyle(.orange) }
                    Text("清除位置显示只移除此处的本地结果，不修改系统定位权限。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("尚未获取位置")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("一次定位", systemImage: "location")
        }
    }

    private var locationAuthorizationMessage: String {
        switch model.locationAuthorization {
        case .notChecked: "尚未检查定位权限，当前状态未知。"
        case .notDetermined: "尚未决定是否允许定位；点击权限按钮后由系统询问。"
        case .authorized: "已获得定位权限，可主动获取一次大致位置。"
        case .denied: "定位权限已拒绝；如需使用，请在系统设置中允许工作台定位。"
        case .restricted: "此设备的定位权限受到系统或管理策略限制。"
        case .servicesDisabled: "系统定位服务已关闭；如需使用，请在系统设置中开启。"
        case .unavailable: "此设备暂时无法使用定位服务。"
        }
    }

    private func weatherCondition(_ symbol: String?) -> String {
        guard var code = symbol else { return "天气状态未知" }
        for suffix in ["_day", "_night", "_polartwilight"] where code.hasSuffix(suffix) {
            code = String(code.dropLast(suffix.count))
        }
        switch code {
        case "clearsky": return "晴"
        case "fair": return "晴间多云"
        case "partlycloudy": return "局部多云"
        case "cloudy": return "多云"
        case "fog": return "雾"
        default:
            if code.contains("thunder") { return "雷暴天气" }
            if code.contains("sleet") { return "雨夹雪" }
            if code.contains("snow") { return "降雪" }
            if code.contains("rain") { return "降雨" }
            return "天气状态未知"
        }
    }

    private func weatherTemperature(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) °C"
    }

    private func weatherTime(_ date: Date, timeZoneID: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var statusColor: Color {
        switch model.status {
        case .online, .localReady: .green
        case .connecting: .blue
        case .paused: .orange
        case .unavailable: .red
        case .notConfigured: .secondary
        }
    }
}

struct MenuBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.status.title, systemImage: model.status.menuBarSymbol)
                .font(.headline)
            Text(model.status.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 240, alignment: .leading)
            Divider()
            Button(model.isPaused ? "恢复本地能力" : "暂停本地能力") {
                Task { await model.togglePause() }
            }
            .disabled(model.isBusy(.pause))
            Button("读取系统音量") {
                Task { await model.readSystemVolume() }
            }
            .disabled(model.isBusy(.volume) || model.isPaused)
            if let reading = model.volumeReadback, reading.outcome == .succeeded, let value = reading.value {
                Text("\(reading.isSimulation ? "模拟音量" : "音量")：\(Int(value.rounded()))%")
                    .font(.caption)
            }
            Divider()
            Button("退出 Orbit 智轨") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
    }
}
