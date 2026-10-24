import BridgeCore
import Foundation
import ServiceManagement
import SwiftUI

struct AutomationFormDraft: Equatable {
    var cityID = "paris"
    var dailyNote = true
    var mailDrafts = true
    var mailNotes = true
    var mailCalendar = false
    var mailReminders = false
    var consent = false

    var mailActions: Set<AutomationAction> {
        var actions: Set<AutomationAction> = [.notify]
        if mailDrafts { actions.insert(.createDraft) }
        if mailNotes { actions.insert(.appendDailyNote) }
        if mailCalendar { actions.insert(.createCalendar) }
        if mailReminders { actions.insert(.createReminder) }
        return actions
    }
}

@MainActor
final class AutomationCenterModel: ObservableObject {
    @Published private(set) var snapshot = AutomationSnapshot(rules: [], runs: [], effects: [])
    @Published private(set) var workers: [WorkbenchClientRecord] = []
    @Published var selectedAgentID = "codex.exec.v1"
    @Published var formDraft = AutomationFormDraft()
    let host: WorkbenchHost?
    @Published private(set) var weather: WeatherReport?
    @Published private(set) var pending: [AutomationPendingReview] = []
    @Published private(set) var resources: [AutomationAction: String] = [:]
    @Published private(set) var calendarEvents: [CalendarEventRecord] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var manualRunSummary: String?
    @Published private(set) var loginEnabled = false
    let bridge: any BridgeService
    let engine: AutomationEngine?
    private var scheduler: Task<Void, Never>?

    init(bridge: any BridgeService, engine: AutomationEngine?, host: WorkbenchHost? = nil) {
        self.bridge = bridge; self.engine = engine; self.host = host
    }

    func start() {
        guard scheduler == nil else { return }
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func tick() async {
        guard let engine else { error = "联动存储未就绪，自动运行已停止。"; return }
        let paused = (try? await bridge.workbenchState().status) != "localReady"
        await engine.tick(paused: paused)
        await refresh()
    }

    func refresh() async {
        if let engine {
            snapshot = await engine.snapshot()
            pending = (try? await engine.pendingReview()) ?? []
        }
        workers = await host?.clients().filter { !$0.revoked && $0.grants.contains(.automationWorker) } ?? []
        weather = await bridge.lastAutomationWeather()
        resources = await bridge.automationResources()
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    func saveWeather(cityID: String, dailyNote: Bool, agentID: String? = nil) async {
        let authorizedAgentID = agentID ?? selectedAgentID
        await perform {
            guard let engine = self.engine, let city = WeatherCities.byID(cityID) else { throw AutomationError.invalidRule }
            var grants: Set<AutomationAction> = [.notify]
            var targets: [AutomationAction: String] = [:]
            if dailyNote {
                guard let target = await self.bridge.automationResources()[.appendDailyNote] else { throw AutomationError.unauthorized }
                grants.insert(.appendDailyNote); targets[.appendDailyNote] = target
            }
            let rule = AutomationRule(id: UUID().uuidString, title: "早间天气 · " + city.name,
                trigger: .morningWeather(cityID: cityID, timeZoneID: city.timeZoneID), grantedActions: grants,
                resourceIDs: targets, enabled: true, agentID: authorizedAgentID)
            try await engine.install(rule: rule)
        }
    }

    func saveMail(actions: Set<AutomationAction>, agentID: String? = nil) async {
        let authorizedAgentID = agentID ?? selectedAgentID
        await perform {
            guard let engine = self.engine, let scope = try await self.bridge.selectedMailScope(), !actions.isEmpty else { throw AutomationError.invalidRule }
            let available = await self.bridge.automationResources()
            guard available[.createDraft] == scope.scopeID else { throw AutomationError.unauthorized }
            var targets: [AutomationAction: String] = [:]
            for action in actions where action != .notify {
                guard let target = available[action] else { throw AutomationError.unauthorized }
                targets[action] = target
            }
            let baseline = try await self.bridge.mailBaseline()
            guard baseline.scopeID == scope.scopeID,
                  try await self.bridge.selectedMailScope()?.scopeID == scope.scopeID else {
                throw AutomationError.unauthorized
            }
            let cursor = String(decoding: try JSONEncoder().encode(baseline), as: UTF8.self)
            try await engine.install(rule: AutomationRule(id: UUID().uuidString, title: "邮件助理",
                trigger: .mailPoll(scopeID: scope.scopeID, intervalSeconds: 300), grantedActions: actions,
                resourceIDs: targets, enabled: true, cursor: cursor, agentID: authorizedAgentID))
        }
    }

    func runWeatherNow(ruleID: String) async {
        manualRunSummary = nil
        await perform {
            guard let engine = self.engine,
                  try await self.bridge.workbenchState().status == "localReady" else { throw AutomationError.unauthorized }
            let priorIDs = Set(await engine.snapshot().runs.map(\.id))
            do { try await engine.runWeatherNow(ruleID: ruleID) }
            catch AutomationError.duplicate {
                self.manualRunSummary = "今天已接纳过该规则的手动运行，不会重复执行。请查看处理记录；分析失败可使用重试入口。"
                return
            }
            let state = await engine.snapshot()
            let runs = state.runs.filter { $0.ruleID == ruleID && !priorIDs.contains($0.id) && $0.sourceID.hasPrefix("weather.manual.") }
            let counts = Dictionary(grouping: runs, by: \.status).map { "\($0.key.rawValue)：\($0.value.count)" }.sorted().joined(separator: " · ")
            self.manualRunSummary = "手动天气实际记录 · " + (counts.isEmpty ? "尚无动作结果，请查看运行记录。" : counts)
        }
    }

    func enable(_ value: Bool, ruleID: String) async {
        await perform { guard let engine = self.engine else { throw AutomationError.unavailableInput }; try await engine.setEnabled(value, for: ruleID) }
    }
    func resolve(_ id: String, approve: Bool, corrected: AutomationAgentDecision? = nil) async {
        await perform { guard let engine = self.engine else { throw AutomationError.unavailableInput }; try await engine.resolve(runID: id, approve: approve, correctedDecision: corrected) }
    }
    func retryAnalysis() async { await engine?.retryPendingAnalysis(); await refresh() }
    func enableCalendar() async { await perform { try await self.bridge.enableCalendar() } }
    func refreshCalendar() async {
        await perform {
            let now = Date()
            self.calendarEvents = try await self.bridge.listCalendar(start: now.addingTimeInterval(-86400), end: now.addingTimeInterval(30 * 86400))
        }
    }
    func setLogin(_ value: Bool) async {
        await perform {
            if value { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
        }
    }
    private func perform(_ body: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await body() }
        catch AutomationError.runInProgress { self.error = "已有联动正在处理，请稍后再试。" }
        catch { self.error = (error as? LocalizedError)?.errorDescription ?? "未完成：\(String(describing: error))。请核对授权范围和运行记录。" }
        await refresh()
    }
}
