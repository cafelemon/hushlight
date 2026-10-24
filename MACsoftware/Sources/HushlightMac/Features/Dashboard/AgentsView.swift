import SwiftUI
import WorkbenchKit

@MainActor
final class AgentManager: ObservableObject {
    @Published var name = ""
    @Published var clients: [WorkbenchClientRecord] = []
    @Published var history: [WorkbenchHistoryEntry] = []
    @Published var selectedClientID: String?
    @Published var draftGrants: Set<WorkbenchGrant> = []
    @Published var createdClientID: String?
    @Published var errorMessage: String?
    @Published var isWorking = false
    @Published private(set) var isConnected = false
    @Published private(set) var mailScope: MailScopeKey?
    @Published private(set) var calendarScopeID: String?

    let host: WorkbenchHost?

    init(host: WorkbenchHost?) { self.host = host }

    var selectedClient: WorkbenchClientRecord? {
        clients.first { $0.id == selectedClientID }
    }

    func load() async {
        guard let host else {
            isConnected = false
            errorMessage = "Orbit 智轨无法初始化，请检查本机工作目录。"
            return
        }
        do {
            try await host.start()
            isConnected = true
            clients = await host.clients()
            mailScope = try? await host.selectedMailScope()
            calendarScopeID = await host.selectedCalendarScope()
            history = await host.history()
            if let selectedClientID, !clients.contains(where: { $0.id == selectedClientID }) {
                self.selectedClientID = nil
                draftGrants = []
            }
            errorMessage = nil
        } catch {
            isConnected = false
            errorMessage = "Orbit 智轨无法连接：\(error.localizedDescription)"
        }
    }

    func select(_ clientID: String?) {
        selectedClientID = clientID
        draftGrants = clients.first { $0.id == clientID }?.grants ?? []
    }

    func create() async {
        guard let host, !isWorking else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let credential = try await host.createClient(name: trimmed)
            createdClientID = credential.id
            name = ""
            await load()
            select(credential.id)
        } catch {
            errorMessage = "创建 Agent 失败：\(error.localizedDescription)"
        }
    }

    func saveGrants() async {
        guard let host, let selectedClientID, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await host.setGrants(clientID: selectedClientID, grants: draftGrants)
            await load()
        } catch {
            if case WorkbenchHostError.mailScopeMissing = error {
                errorMessage = "请先在 Apple Mail 页面选择邮箱，再保存邮件读取授权。"
            } else if case WorkbenchHostError.calendarScopeMissing = error {
                errorMessage = "请先在日历页面启用专用日历，再保存日历授权。"
            } else { errorMessage = "保存授权失败：\(error.localizedDescription)" }
        }
    }

    func revoke() async {
        guard let host, let selectedClientID, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await host.revoke(clientID: selectedClientID)
            createdClientID = nil
            await load()
            select(selectedClientID)
        } catch {
            errorMessage = "撤销 Agent 失败：\(error.localizedDescription)"
        }
    }

    func dismissCredential() { createdClientID = nil }
}

struct AgentsView: View {
    @ObservedObject var manager: AgentManager

    private let grantOptions: [WorkbenchGrant] = [
        .automationRead, .automationWorker, .volumeRead, .timerRead, .timerWrite, .reminderRead, .reminderWrite,
        .calendarRead, .calendarWrite,
        .noteRead, .noteWrite, .musicRead, .musicPlaybackRead, .musicWrite, .weatherRead, .locationRead, .mailRead, .mailWrite, .mailSendRequest
    ]

    var body: some View {
        GroupBox("本机连接") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Agent 通过本机 Socket 连接。新建连接默认没有任何能力授权。")
                    .foregroundStyle(.secondary)
                LabeledContent("Socket 路径", value: WorkbenchPaths.defaultSocketPath)
                    .textSelection(.enabled)
                HStack {
                    TextField("Agent 名称", text: $manager.name)
                        .accessibilityIdentifier("agentName")
                    Button("创建 Agent") { Task { await manager.create() } }
                        .disabled(manager.isWorking || manager.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("createAgent")
                }
                if let clientID = manager.selectedClientID, manager.selectedClient?.revoked == false {
                    Divider()
                    Text("凭据已保存在仅当前用户可读的文件。请在 MCP 客户端配置中使用此文件路径。")
                        .foregroundStyle(.secondary)
                    LabeledContent("Agent ID", value: clientID)
                        .textSelection(.enabled)
                    LabeledContent("凭据文件", value: credentialPath(clientID))
                        .textSelection(.enabled)
                    HStack {
                        Text(launchCommand(clientID))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("agentConfiguration")
                        Spacer()
                        Button("复制启动命令") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                launchCommand(clientID),
                                forType: .string
                            )
                        }
                        Button("复制 Codex 配置") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(codexConfiguration(clientID), forType: .string)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        GroupBox("Agent 授权") {
            VStack(alignment: .leading, spacing: 12) {
                if manager.clients.isEmpty {
                    Text("尚未创建 Agent。")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("选择 Agent", selection: Binding(
                        get: { manager.selectedClientID },
                        set: { manager.select($0) }
                    )) {
                        Text("选择一个 Agent").tag(String?.none)
                        ForEach(manager.clients, id: \.id) { client in
                            Text(client.revoked ? "\(client.name)（已撤销）" : client.name)
                                .tag(Optional(client.id))
                        }
                    }
                    if let client = manager.selectedClient {
                        Text("ID：\(client.id)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if client.revoked {
                            Label("此连接已撤销，不能再次使用。", systemImage: "xmark.shield")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(grantOptions, id: \.self) { grant in
                                Toggle(grantTitle(grant), isOn: Binding(
                                    get: { manager.draftGrants.contains(grant) },
                                    set: { enabled in
                                        if enabled { manager.draftGrants.insert(grant) }
                                        else { manager.draftGrants.remove(grant) }
                                    }
                                ))
                            }
                            if manager.draftGrants.contains(where: { $0.rawValue.hasPrefix("mail.") }) {
                                if let scope = manager.mailScope {
                                    Text("保存将授权：\(scope.mailboxPath.joined(separator: " / "))（账户 ID：\(scope.accountID)）")
                                        .font(.caption).textSelection(.enabled)
                                    if client.mailScopeID != nil && client.mailScopeID != scope.scopeID {
                                        Text("所选邮箱已改变，原邮件授权已失效；保存后将绑定此邮箱。")
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                } else {
                                    Text("请先在 Apple Mail 页面选择并核对账户和邮箱。")
                                        .foregroundStyle(.orange)
                                }
                            }
                            if manager.draftGrants.contains(where: { $0.rawValue.hasPrefix("calendar.") }) {
                                if let scope = manager.calendarScopeID {
                                    Text("保存将授权专用日历（ID：\(scope)）。")
                                        .font(.caption).textSelection(.enabled)
                                    if client.calendarScopeID != nil && client.calendarScopeID != scope {
                                        Text("专用日历已改变，原日历授权已失效；保存后将绑定当前日历。")
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                } else {
                                    Text("请先在日历页面启用并核对专用日历。")
                                        .foregroundStyle(.orange)
                                }
                            }
                            HStack {
                                Button("保存授权") { Task { await manager.saveGrants() } }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(manager.isWorking || (manager.draftGrants == client.grants &&
                                        !(manager.draftGrants.contains(where: { $0.rawValue.hasPrefix("mail.") }) && manager.mailScope?.scopeID != client.mailScopeID) &&
                                        !(manager.draftGrants.contains(where: { $0.rawValue.hasPrefix("calendar.") }) && manager.calendarScopeID != client.calendarScopeID)))
                                Button("撤销 Agent", role: .destructive) { Task { await manager.revoke() } }
                                    .disabled(manager.isWorking)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        Text("写入去重账本最多保留 10,000 笔。达到上限后会停止新写入；核对待定结果后撤销旧连接并创建新连接可释放空间。撤销连接的动作摘要最多保留最近 1,000 笔。")
            .font(.caption).foregroundStyle(.secondary)

        GroupBox("最近请求") {
            VStack(alignment: .leading, spacing: 8) {
                Button("刷新记录") { Task { await manager.load() } }
                    .disabled(manager.isWorking)
                if manager.history.isEmpty {
                    Text("暂无 Agent 请求。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.history.prefix(20), id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.action)
                                Spacer()
                                Text(entry.status)
                                Text(entry.occurredAt, style: .time)
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.clientID == "local_ui"
                                 ? "本机界面"
                                 : entry.clientID == "bridge_core"
                                    ? "Bridge 动作 · 来源未标记"
                                    : "Agent：\(manager.clients.first(where: { $0.id == entry.clientID })?.name ?? entry.clientID)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let error = entry.error {
                                Text("原因：\(error)")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let error = manager.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func grantTitle(_ grant: WorkbenchGrant) -> String {
        switch grant {
        case .automationWorker: "领取被规则指定的分析任务（原文读取，不能自行授权）"
        case .automationRead: "查看联动状态与脱敏运行记录"
        case .musicPlaybackRead: "读取 QQ 音乐播放状态与当前歌曲"
        case .musicWrite: "控制 QQ 音乐播放、暂停、切歌及回读结果"
        case .musicRead: "读取 QQ 音乐安装与运行状态（不读取播放内容）"
        case .volumeRead: "读取系统音量"
        case .timerRead: "查看计时器"
        case .timerWrite: "管理计时器"
        case .reminderRead: "查看提醒事项"
        case .reminderWrite: "管理提醒事项"
        case .calendarRead: "查看专用日历事件"
        case .calendarWrite: "管理专用日历事件"
        case .noteRead: "查看备忘录"
        case .noteWrite: "管理备忘录"
        case .weatherRead: "查询天气"
        case .locationRead: "读取定位"
        case .mailWrite: "创建 Mail 草稿（不发送）"
        case .mailSendRequest: "提出发送请求（仍须你在 App 确认）"
        case .mailRead: "读取当前所选邮箱（保存时绑定；换邮箱后须重新授权）"
        }
    }

    private var mcpExecutablePath: String {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("agent-workbench-mcp").path ?? "agent-workbench-mcp"
    }

    private func launchCommand(_ clientID: String) -> String {
        WorkbenchConnectionConfiguration.command(executable: mcpExecutablePath, credential: credentialPath(clientID))
    }

    private func codexConfiguration(_ clientID: String) -> String {
        WorkbenchConnectionConfiguration.toml(clientID: clientID, executable: mcpExecutablePath, credential: credentialPath(clientID))
    }

    private func credentialPath(_ clientID: String) -> String {
        WorkbenchPaths.defaultDirectory.appendingPathComponent(clientID + ".credential").path
    }
}
