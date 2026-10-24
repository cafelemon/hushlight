import BridgeCore
import CryptoKit
import XCTest
@testable import HushlightMac

private struct WorkflowKey: AutomationKeyProviding {
    func key() throws -> SymmetricKey { .init(data: Data(repeating: 18, count: 32)) }
}
private final class WorkflowClock: @unchecked Sendable {
    var date = ISO8601DateFormatter().date(from: "2026-10-23T09:00:00Z")!
}
private struct WorkflowInput: AutomationInputProviding {
    let date: Date
    func collect(rule: AutomationRule, cursor: String?) async throws -> AutomationInputBatch {
        let metadata = ["scopeID": WorkflowBridge.scope.scopeID, "sender": "me@example.com", "replyTo": "sender@example.com", "subject": "Project review", "day": "2026-10-23", "source": "synthetic.source"]
        return .init(items: [
            .init(sourceID: "important", occurredAt: date, text: "2026-10-24 09:00 to 2026-10-24 10:00 UTC Project review", metadata: metadata),
            .init(sourceID: "advertisement", occurredAt: date, text: "Synthetic promotion", metadata: metadata),
            .init(sourceID: "ambiguous", occurredAt: date, text: "Please review tomorrow", metadata: metadata)
        ], nextCursor: "synthetic-page-complete")
    }
}
private struct WorkflowAnalyzer: AutomationAnalyzing {
    func analyze(rule: AutomationRule, item: AutomationInputItem) async throws -> [AutomationAgentDecision] {
        if item.sourceID == "advertisement" {
            return [.init(action: .notify, title: "Advertisement", body: "Promotion", confidence: 1, classification: "ads")]
        }
        if item.sourceID == "ambiguous" {
            return [.init(action: .createReminder, title: "Review", body: "Tomorrow", confidence: 1, classification: "uncertain")]
        }
        let date = ISO8601DateFormatter().date(from: "2026-10-24T09:00:00Z")!
        return [
            .init(action: .createDraft, title: "Reply", body: "I will attend.", confidence: 1, classification: "important"),
            .init(action: .createCalendar, title: "Project review", body: "Meeting", confidence: 1, classification: "important", sourceExcerpt: item.text, eventAt: date, eventEndAt: date.addingTimeInterval(3600), timeZoneID: "UTC"),
            .init(action: .createReminder, title: "Project review", body: "Prepare", confidence: 1, classification: "important", sourceExcerpt: item.text, eventAt: date, timeZoneID: "UTC"),
            .init(action: .appendDailyNote, title: "Project review", body: "Meeting and draft prepared", confidence: 1, classification: "important")
        ]
    }
}
private actor WorkflowBridge: BridgeService {
    static let scope = MailScopeKey(accountID: "synthetic", mailboxPath: ["Inbox"])
    var writes: [String] = []
    var simulatedDraft = false
    func simulateDraftResult() { simulatedDraft = true }
    var note: LocalNoteContent?
    var draft: MailDraftInput?
    func snapshot() async throws -> BridgeSnapshot { .init(status: .localReady, permissions: [], recentActions: []) }
    func setPaused(_ value: Bool) async throws {}
    func workbenchState() async throws -> WorkbenchServiceState { .init(status: "localReady", supportedActions: [], isSimulation: false) }
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
    func selectedMailScope() async throws -> MailScopeKey? { Self.scope }
    func automationResources() async -> [AutomationAction: String] {
        [.createDraft: Self.scope.scopeID, .createCalendar: "synthetic-calendar", .createReminder: "synthetic-list", .appendDailyNote: "synthetic-folder"]
    }
    func calendarConflict(start: Date, end: Date) async throws -> Bool { false }
    func createMailDraft(id: String, input: MailDraftInput) async throws -> LocalMailCommandResult {
        writes.append("draft"); draft = input
        XCTAssertEqual(BridgeExecutionContext.callerID, "automation")
        XCTAssertEqual(BridgeExecutionContext.mailScopeID, Self.scope.scopeID)
        return .init(status: "succeeded", isSimulation: simulatedDraft, draftID: id)
    }
    func createCalendarEvent(id: String, title: String, start: Date, end: Date, sourceURL: URL?) async throws -> CalendarEventRecord {
        writes.append("calendar")
        XCTAssertEqual(sourceURL?.scheme, "workbench-source")
        return .init(id: id, title: title, start: start, end: end, sourceURL: sourceURL)
    }
    func createReminder(id: String, title: String, dueAt: Date) async throws -> ReminderActionReadback {
        writes.append("reminder")
        XCTAssertTrue(title.contains("[来源:synthetic.source]"))
        return .init(outcome: .succeeded, stableError: nil, completedAt: Date())
    }
    func readNote(id: String) async throws -> LocalNotesCommandResult {
        .init(status: note == nil ? "failed" : "succeeded", stableError: note == nil ? "invalid_schema" : nil, completedAt: Date(), note: note, isSimulation: false)
    }
    func createNote(id: String, title: String, text: String) async throws -> LocalNotesCommandResult {
        writes.append("note")
        note = .init(id: id, title: title, text: text, revision: "synthetic-revision", canAppend: true)
        return .init(status: "succeeded", stableError: nil, completedAt: Date(), note: note, isSimulation: false)
    }
    func evidence() -> ([String], MailDraftInput?, LocalNoteContent?) { (writes, draft, note) }
}

final class AutomationWorkflowIntegrationTests: XCTestCase {
    func testSimulatedDraftCannotBecomeAnActualSuccessfulEffect() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-simulation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = WorkflowBridge(), clock = WorkflowClock()
        await bridge.simulateDraftResult()
        let engine = try AutomationEngine(storageURL: directory.appendingPathComponent("state.json"), keyProvider: WorkflowKey(), input: WorkflowInput(date: clock.date), analyzer: WorkflowAnalyzer(), effectDriver: BridgeAutomationEffects(bridge: bridge), now: { clock.date })
        try await engine.install(rule: .init(id: "mail", title: "Synthetic", trigger: .mailPoll(scopeID: WorkflowBridge.scope.scopeID, intervalSeconds: 300), grantedActions: [.createDraft, .createCalendar, .createReminder, .appendDailyNote], resourceIDs: await bridge.automationResources(), enabled: true))
        await engine.tick(paused: false)
        let state = await engine.snapshot()
        XCTAssertEqual(state.effects.first(where: { $0.action == .createDraft })?.status, .rejected)
        XCTAssertTrue(state.runs.contains { $0.failureCode == "simulation_not_allowed" })
        XCTAssertFalse(state.effects.contains { $0.action == .createDraft && $0.status == .succeeded })
    }

    func testMailDecisionUsesSharedEffectsAndRestartDoesNotDuplicateWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.json"), bridge = WorkflowBridge(), clock = WorkflowClock()
        func engine() throws -> AutomationEngine {
            try AutomationEngine(storageURL: file, keyProvider: WorkflowKey(), input: WorkflowInput(date: clock.date),
                analyzer: WorkflowAnalyzer(), effectDriver: BridgeAutomationEffects(bridge: bridge), now: { clock.date })
        }
        let first = try engine()
        let resources = await bridge.automationResources()
        try await first.install(rule: .init(id: "mail", title: "Synthetic mail", trigger: .mailPoll(scopeID: WorkflowBridge.scope.scopeID, intervalSeconds: 300), grantedActions: [.notify, .createDraft, .createCalendar, .createReminder, .appendDailyNote], resourceIDs: resources, enabled: true))
        await first.tick(paused: false)
        await first.tick(paused: false)
        await first.tick(paused: false)
        let state = await first.snapshot(), evidence = await bridge.evidence()
        XCTAssertEqual(evidence.0, ["draft", "calendar", "reminder", "note"])
        XCTAssertEqual(evidence.1?.to, ["sender@example.com"])
        XCTAssertTrue(evidence.2?.text.contains("来源：synthetic.source") == true)
        XCTAssertEqual(state.effects.filter { $0.status == .succeeded }.count, 5) // Includes silent advertisement metadata.
        let pending = try await first.pendingReview()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.decision.classification, "uncertain")
        let plaintext = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertFalse(plaintext.contains("I will attend."))
        XCTAssertFalse(plaintext.contains("Please review tomorrow"))
        clock.date.addTimeInterval(600)
        let restored = try engine()
        await restored.tick(paused: false)
        await restored.tick(paused: false)
        let after = await bridge.evidence()
        XCTAssertEqual(after.0, evidence.0)
        try await restored.resolve(runID: XCTUnwrap(pending.first?.runID), approve: false)
        let final = await bridge.evidence()
        XCTAssertEqual(final.0.count, 4)
    }
}
