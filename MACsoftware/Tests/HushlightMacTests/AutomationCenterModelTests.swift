import XCTest
import BridgeCore
import CryptoKit
@testable import HushlightMac

private struct CenterTestKey: AutomationKeyProviding {
    func key() throws -> SymmetricKey { .init(data: Data(repeating: 42, count: 32)) }
}
private struct CenterTestInput: AutomationInputProviding {
    func collect(rule: AutomationRule, cursor: String?) async throws -> AutomationInputBatch { throw AutomationError.unavailableInput }
}
private struct CenterTestAnalyzer: AutomationAnalyzing {
    func analyze(rule: AutomationRule, item: AutomationInputItem) async throws -> [AutomationAgentDecision] { throw AutomationError.unavailableInput }
}
private struct CenterTestEffects: AutomationEffectDriving {
    func apply(_ decision: AutomationAgentDecision, idempotencyKey: String, resourceID: String?,
               sourceMetadata: [String: String], authorization: AutomationEffectAuthorization) async throws -> String? { throw AutomationError.unavailableInput }
}
private actor CenterTestBridge: BridgeService {
    static let first = MailScopeKey(accountID: "synthetic-a", mailboxPath: ["Inbox"])
    static let second = MailScopeKey(accountID: "synthetic-b", mailboxPath: ["Inbox"])
    var scope = first
    var hold = false
    var started = false
    var gate: CheckedContinuation<Void, Never>?
    var waiter: CheckedContinuation<Void, Never>?
    var mismatchedBaseline = false
    var changeScopeAtBaseline = false
    var calls = 0
    func holdResources() { hold = true }
    func waitForResources() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func releaseResources() { hold = false; gate?.resume(); gate = nil }
    func setMismatchedBaseline() { mismatchedBaseline = true }
    func setChangeScopeAtBaseline() { changeScopeAtBaseline = true }
    func snapshot() async throws -> BridgeSnapshot { .init(status: .localReady, permissions: [], recentActions: []) }
    func setPaused(_ value: Bool) async throws {}
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
    func workbenchState() async throws -> WorkbenchServiceState { .init(status: "localReady", supportedActions: [], isSimulation: false) }
    func selectedMailScope() async throws -> MailScopeKey? { scope }
    func mailBaseline() async throws -> MailIncrementalCursor {
        if changeScopeAtBaseline { scope = Self.second }
        return .init(scopeID: mismatchedBaseline ? Self.second.scopeID : Self.first.scopeID,
                     baselineAt: Date(), watermark: Date(), recent: [])
    }
    func automationResources() async -> [AutomationAction: String] {
        calls += 1
        if hold {
            started = true; waiter?.resume(); waiter = nil
            await withCheckedContinuation { gate = $0 }
        }
        return [.createDraft: scope.scopeID, .appendDailyNote: "synthetic-folder"]
    }
}

@MainActor
final class AutomationCenterModelTests: XCTestCase {
    private func make(_ bridge: CenterTestBridge) throws -> (AutomationCenterModel, URL) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("AutomationCenter-\(UUID().uuidString)/state.json")
        let engine = try AutomationEngine(storageURL: file, keyProvider: CenterTestKey(), input: CenterTestInput(),
            analyzer: CenterTestAnalyzer(), effectDriver: CenterTestEffects())
        return (AutomationCenterModel(bridge: bridge, engine: engine), file.deletingLastPathComponent())
    }
    func testNewPageInstancesShareUnsavedFormWithoutAccessingBridge() async throws {
        let bridge = CenterTestBridge(); let (model, dir) = try make(bridge)
        defer { try? FileManager.default.removeItem(at: dir) }
        model.formDraft.cityID = "london"; model.formDraft.dailyNote = false
        model.formDraft.mailCalendar = true; model.formDraft.mailNotes = false; model.formDraft.consent = true
        let draft = model.formDraft
        _ = AutomationCenterView(model: model)
        _ = AutomationCenterView(model: model)
        XCTAssertEqual(model.formDraft, draft)
        XCTAssertEqual(model.formDraft.mailActions, [.notify, .createDraft, .createCalendar])
        let calls = await bridge.calls; XCTAssertEqual(calls, 0)
    }
    func testWeatherSaveFreezesAgentAndParametersAcrossAwait() async throws {
        let bridge = CenterTestBridge(); await bridge.holdResources()
        let (model, dir) = try make(bridge); defer { try? FileManager.default.removeItem(at: dir) }
        let save = Task { await model.saveWeather(cityID: "paris", dailyNote: true) }
        await bridge.waitForResources()
        model.selectedAgentID = "connection:" + UUID().uuidString
        model.formDraft.cityID = "london"; model.formDraft.dailyNote = false
        await bridge.releaseResources(); await save.value
        XCTAssertNil(model.error)
        let rule = try XCTUnwrap(model.snapshot.rules.first)
        XCTAssertEqual(rule.agentID, "codex.exec.v1")
        XCTAssertEqual(rule.trigger, .morningWeather(cityID: "paris", timeZoneID: "Europe/Paris"))
        XCTAssertEqual(rule.grantedActions, [.notify, .appendDailyNote])
    }
    func testExplicitClickSnapshotAgentIsUsedForMailSave() async throws {
        let bridge = CenterTestBridge(); let (model, dir) = try make(bridge)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clickedAgent = "codex.exec.v1"
        model.selectedAgentID = "connection:" + UUID().uuidString
        await model.saveMail(actions: [.notify, .createDraft], agentID: clickedAgent)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.snapshot.rules.first?.agentID, clickedAgent)
    }
    func testMismatchedBaselineCannotInstallMailRule() async throws {
        let bridge = CenterTestBridge(); await bridge.setMismatchedBaseline()
        let (model, dir) = try make(bridge); defer { try? FileManager.default.removeItem(at: dir) }
        await model.saveMail(actions: [.notify])
        XCTAssertTrue(model.snapshot.rules.isEmpty); XCTAssertNotNil(model.error)
    }
    func testChangedSelectedMailboxCannotInstallOldScopeRule() async throws {
        let bridge = CenterTestBridge(); await bridge.setChangeScopeAtBaseline()
        let (model, dir) = try make(bridge); defer { try? FileManager.default.removeItem(at: dir) }
        await model.saveMail(actions: [.notify, .createDraft])
        XCTAssertTrue(model.snapshot.rules.isEmpty); XCTAssertNotNil(model.error)
    }
}
