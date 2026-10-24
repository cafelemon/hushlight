import BridgeCore
import SwiftUI

struct AutomationCenterView: View {
    @ObservedObject var model: AutomationCenterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("规则保存并启用后，App 在菜单栏驻留时自动执行。关闭 App 或睡眠期间不保证准点；06:00 天气在 08:00 前补跑一次。")
                .foregroundStyle(.secondary)
            Picker("新规则使用的分析 Agent", selection: $model.selectedAgentID) {
                Text("Codex 后台分析").tag("codex.exec.v1")
                ForEach(model.workers) { worker in Text(worker.name + " · 已授权分析连接").tag("connection:" + worker.id) }
            }
            Text("选择会保存在新规则中；连接只可领取被指定给自己的任务。更换 Agent 需重新保存规则，不会修改旧规则授权。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let summary = model.manualRunSummary { Text(summary).font(.caption).textSelection(.enabled) }
            if let report = model.weather {
                GroupBox("最近取得的真实预报") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(report.city.name + " · " + String(format: "%.1f°C", report.current.temperatureC))
                        Text("获取时间：" + report.fetchedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                        Text("预报获取与 AI 分析分别记录；分析失败时不会显示已完成建议。").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            GroupBox("早间天气") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("常用地点", selection: $model.formDraft.cityID) {
                        ForEach(WeatherCities.all, id: \.id) { city in Text(city.name + " · " + city.region).tag(city.id) }
                    }
                    Text("保存城市坐标及时区，不保存家庭精确地址。每天按 Mac 当前时区 06:00 查询。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("写入当天联动摘要", isOn: $model.formDraft.dailyNote)
                    if model.formDraft.dailyNote && model.resources[.appendDailyNote] == nil {
                        Text("请先在备忘录页连接专用文件夹；已有授权会静默恢复。系统备忘录未运行时请先打开。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button("保存并启用早间天气") {
                        let draft = model.formDraft
                        let agentID = model.selectedAgentID
                        Task { await model.saveWeather(cityID: draft.cityID, dailyNote: draft.dailyNote, agentID: agentID) }
                    }
                        .disabled(model.busy || (model.formDraft.dailyNote && model.resources[.appendDailyNote] == nil))
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            GroupBox("邮件助理") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("每五分钟检查已选邮箱的新邮件。明确广告只在工作台静默记录；不会删除、归档或标记已读。请同时检查 Mail 自带通知，避免重复提醒。")
                    Toggle("需要回复时自动创建原生 Mail 草稿", isOn: $model.formDraft.mailDrafts)
                    Toggle("写入当天联动摘要", isOn: $model.formDraft.mailNotes)
                    Toggle("明确事项同步专用日历", isOn: $model.formDraft.mailCalendar)
                    Toggle("明确事项同步专用提醒列表", isOn: $model.formDraft.mailReminders)
                    Text("输入：Mail 页已选邮箱。输出：此处勾选的专用范围。日期、时间或时区不明确及冲突事项进入待确认。发送始终逐封确认。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("保存此规则时，授权所选 Agent 分析新邮件及以上联动范围", isOn: $model.formDraft.consent)
                    Text("保存后请在下方已保存规则中停用，撤销框选不会修改已保存规则。Codex 以临时分析会话运行；不挂接工作台写工具。模型处理方式遵循你的 Codex 账号设置。启用时仅建立当前游标，不回扫历史邮件。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("保存范围并启用邮件助理") {
                        let actions = model.formDraft.mailActions
                        let agentID = model.selectedAgentID
                        Task { await model.saveMail(actions: actions, agentID: agentID) }
                    }.disabled(model.busy || !model.formDraft.consent)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            GroupBox("已保存规则") {
                VStack(alignment: .leading, spacing: 12) {
                    if model.snapshot.rules.isEmpty { Text("尚未启用规则").foregroundStyle(.secondary) }
                    Text("手动天气会尝试分析并执行已授权动作，实际状态见处理记录；当天接纳一次后不重复运行。15分钟后不执行旧建议，早间计划仍独立运行。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.snapshot.rules) { rule in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(rule.title).fontWeight(.medium)
                                Text(rule.grantedActions.map(\.rawValue).sorted().joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                let queued = model.snapshot.queuedInputCounts[rule.id, default: 0]
                                let retry = model.snapshot.retryInputCounts[rule.id, default: 0]
                                if queued > 0 || retry > 0 {
                                    Text("已保存待分析：\(queued) · 分析待重试：\(retry)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let error = rule.lastErrorCode {
                                    Text(error == "scope_or_permission_requires_repair" ? "已停用：请先在对应能力页修复原授权范围，再启用此规则。" : "输入或分析未完成：未接纳页保留游标，已接纳内容加密排队；请查看处理记录。")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            if rule.enabled, case .morningWeather = rule.trigger {
                                Button("手动运行一次") { Task { await model.runWeatherNow(ruleID: rule.id) } }
                                    .disabled(model.busy)
                                    .help("按已保存的城市、Agent及输出范围运行；当天接纳一次后不重复运行，不替代06:00调度。结果未知不重放。")
                            }
                            Button(rule.enabled ? "停用" : "启用") { Task { await model.enable(!rule.enabled, ruleID: rule.id) } }.disabled(model.busy)
                        }
                    }
                    HStack {
                        Button("检查运行状态") { Task { await model.tick() } }.disabled(model.busy)
                        Button("重试未完成的分析") { Task { await model.retryAnalysis() } }.disabled(model.busy)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            GroupBox("待确认") {
                VStack(alignment: .leading, spacing: 12) {
                    if model.pending.isEmpty { Text("暂无待确认事项").foregroundStyle(.secondary) }
                    ForEach(model.pending, id: \.runID) { item in
                        AutomationReviewCard(item: item, busy: model.busy) { approve, corrected in
                            Task { await model.resolve(item.runID, approve: approve, corrected: corrected) }
                        }
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            GroupBox("处理记录") {
                VStack(alignment: .leading, spacing: 8) {
                    if model.snapshot.runs.isEmpty { Text("尚无实际运行记录").foregroundStyle(.secondary) }
                    ForEach(Array(model.snapshot.runs.suffix(80).reversed())) { run in
                        VStack(alignment: .leading, spacing: 2) {
                            Text((run.action?.rawValue ?? "分析") + " · " + run.status.rawValue)
                            Text((model.snapshot.rules.first { $0.id == run.ruleID }?.title ?? run.ruleID) + " · " + run.sourceID)
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if let note = run.scheduleNote {
                                Text(note == "manual_weather_check" ? "本人手动运行" : note).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(run.startedAt.formatted() + (run.failureCode.map { " · " + $0 } ?? "")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
        }.task { await model.refresh() }
    }
}

struct WorkbenchCalendarView: View {
    @ObservedObject var model: AutomationCenterModel
    var body: some View {
        GroupBox("专用日历") {
            VStack(alignment: .leading, spacing: 12) {
                Text("仅管理工作台创建的日历和条目；不发送邀请、不操作其他日历。")
                if model.resources[.createCalendar] == nil {
                    Button("检查并启用专用日历") { Task { await model.enableCalendar() } }.disabled(model.busy)
                }
                Button("读取未来 30 天工作台日程") { Task { await model.refreshCalendar() } }.disabled(model.busy)
                if let error = model.error { Text(error).foregroundStyle(.orange) }
                ForEach(model.calendarEvents, id: \.id) { event in
                    VStack(alignment: .leading) {
                        Text(event.title).fontWeight(.medium)
                        Text(event.start.formatted() + " — " + event.end.formatted()).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }.task { await model.refresh() }
    }
}

struct WorkbenchSettingsView: View {
    @ObservedObject var model: AutomationCenterModel
    var body: some View {
        GroupBox("后台运行与授权层次") {
            VStack(alignment: .leading, spacing: 10) {
                Text("系统权限由 macOS 保存；资源范围保存专用文件夹、列表、日历和邮箱；Agent 连接授权与每条联动规则授权分别管理。重启会静默核对，失效时在对应页面修复。")
                Text("已就绪的联动输出：" + model.resources.keys.map(\.rawValue).sorted().joined(separator: "、"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(model.loginEnabled ? "关闭登录启动" : "开启登录启动") { Task { await model.setLogin(!model.loginEnabled) } }.disabled(model.busy)
                Text("仅在固定安装的 App 中开启；macOS 可能要求在登录项中确认。关闭窗口后菜单栏继续运行，退出 App 则停止。")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }.task { await model.refresh() }
    }
}

private struct AutomationReviewCard: View {
    let item: AutomationPendingReview
    let busy: Bool
    let submit: (Bool, AutomationAgentDecision?) -> Void
    @State private var editTime = false
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(3600)
    @State private var zone = TimeZone.current.identifier
    private var isSchedule: Bool { [.createCalendar, .createReminder].contains(item.decision.action) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.decision.title).fontWeight(.medium)
            Text(item.decision.body).textSelection(.enabled)
            if let excerpt = item.decision.sourceExcerpt { Text("原文：" + excerpt).font(.caption).foregroundStyle(.secondary) }
            Text("动作：" + item.decision.action.rawValue).font(.caption)
            if isSchedule {
                Text("建议时间：" + formatted(item.decision.eventAt, zone: item.decision.timeZoneID) + (item.decision.eventEndAt.map { " 至 " + formatted($0, zone: item.decision.timeZoneID) } ?? ""))
                    .font(.caption)
                Toggle("补充或修正此项时间", isOn: $editTime)
                if editTime {
                    TextField("时区，如 Asia/Shanghai", text: $zone)
                    if let timeZone = TimeZone(identifier: zone) {
                        DatePicker("开始或截止", selection: $start).environment(\.timeZone, timeZone)
                        if item.decision.action == .createCalendar { DatePicker("结束", selection: $end).environment(\.timeZone, timeZone) }
                    } else { Text("请输入有效时区").foregroundStyle(.orange) }
                    Text("你填写的时间将作为本次明确确认的内容，不会扩大规则范围。").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("确认此项") {
                    if editTime {
                        let old = item.decision
                        submit(true, .init(action: old.action, title: old.title, body: old.body, confidence: old.confidence,
                            classification: old.classification, sourceExcerpt: old.sourceExcerpt, eventAt: start,
                            eventEndAt: old.action == .createCalendar ? end : nil, timeZoneID: zone))
                    } else { submit(true, nil) }
                }.disabled(busy || (isSchedule && !editTime && (item.decision.eventAt == nil || (item.decision.action == .createCalendar && item.decision.eventEndAt == nil))) || (editTime && (TimeZone(identifier: zone) == nil || (item.decision.action == .createCalendar && end <= start))))
                Button("忽略此项") { submit(false, nil) }.disabled(busy)
            }
        }.onAppear {
            start = item.decision.eventAt ?? Date(); end = item.decision.eventEndAt ?? start.addingTimeInterval(3600)
            zone = item.decision.timeZoneID ?? TimeZone.current.identifier
        }
    }
    private func formatted(_ date: Date?, zone: String?) -> String {
        guard let date else { return "待你补充" }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .current
        return formatter.string(from: date) + " (" + formatter.timeZone.identifier + ")"
    }
}
