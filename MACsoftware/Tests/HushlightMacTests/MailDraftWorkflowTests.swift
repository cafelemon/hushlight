import BridgeCore
import Foundation
import XCTest
@testable import HushlightMac

private actor WorkflowScopeRunner: MailScopeScriptRunning {
    func run(operation: String, scope: MailScopeKey?) async throws -> [[String]] {
        if operation == "list" {
            return [["account-1", "First", "sender@example.com", "Inbox"],
                    ["account-2", "Second", "other@example.com", "Inbox"]]
        }
        if operation == "verify", let scope {
            let name = scope.accountID == "account-1" ? "First" : "Second"
            let address = scope.accountID == "account-1" ? "sender@example.com" : "other@example.com"
            return [[scope.accountID, name, address] + scope.mailboxPath]
        }
        return []
    }
}

private actor WorkflowNativeDriver: MailDraftNativeDriving {
    var native: MailDraftContent?
    var createCount = 0
    var readCount = 0
    var sendCount = 0
    var outcome: MailSendNativeOutcome = .submitted
    var holdSend = false
    var sendStarted: CheckedContinuation<Void, Never>?
    var sendWaiter: CheckedContinuation<Void, Never>?

    func create(scope: MailScopeKey, input: MailDraftInput) async throws -> MailDraftContent {
        createCount += 1
        let value = MailDraftContent(id: "mail.draft.\(scope.scopeID).42", scopeID: scope.scopeID,
                                     sender: input.sender, to: input.to, cc: input.cc, bcc: input.bcc,
                                     subject: input.subject, text: input.text,
                                     revision: AppleMailDraftBackend.revision(input))
        native = value
        return value
    }
    func read(scope: MailScopeKey, id: String) async throws -> MailDraftContent {
        readCount += 1
        guard let native, native.id == id, native.scopeID == scope.scopeID else {
            throw StableErrorCode.resultUnverifiable
        }
        return native
    }
    func send(scope: MailScopeKey, draft: MailDraftContent) async throws -> MailSendNativeOutcome {
        sendCount += 1
        sendStarted?.resume()
        sendStarted = nil
        if holdSend { await withCheckedContinuation { sendWaiter = $0 } }
        return outcome
    }
    func changeNative(_ value: MailDraftContent) { native = value }
    func setOutcome(_ value: MailSendNativeOutcome) { outcome = value }
    func pauseSend() { holdSend = true }
    func waitForSendStart() async {
        if sendCount > 0 { return }
        await withCheckedContinuation { sendStarted = $0 }
    }
    func releaseSend() { holdSend = false; sendWaiter?.resume(); sendWaiter = nil }
    func counts() -> (Int, Int, Int) { (createCount, readCount, sendCount) }
}

final class MailDraftWorkflowTests: XCTestCase {
    private let first = MailScopeKey(accountID: "account-1", mailboxPath: ["Inbox"])
    private let second = MailScopeKey(accountID: "account-2", mailboxPath: ["Inbox"])
    private let input = MailDraftInput(sender: "sender@example.com", to: ["to@example.com"],
                                       cc: ["cc@example.com"], bcc: ["bcc@example.com"],
                                       subject: "Subject", text: "Body")

    private func setup() async throws -> (URL, AppleMailScopeBackend, WorkflowNativeDriver, MailDraftWorkflow) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-workflow-\(UUID())")
        let scope = AppleMailScopeBackend(storageURL: root.appendingPathComponent("scope.json"),
                                          runner: WorkflowScopeRunner())
        try await scope.choose(first)
        let native = WorkflowNativeDriver()
        let workflow = MailDraftWorkflow(scope: scope, driver: native,
                                         storageURL: root.appendingPathComponent("drafts.json"))
        return (root, scope, native, workflow)
    }

    func testCreateReplayOnceAndSendRequestDoesNotDispatch() async throws {
        let (root, _, native, workflow) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try await workflow.createDraft(id: "request-1", input: input)
        let replay = try await workflow.createDraft(id: "request-1", input: input)
        XCTAssertEqual(created, replay)
        XCTAssertEqual(created.id, "request-1")
        let changed = MailDraftInput(sender: input.sender, to: input.to, cc: input.cc, bcc: input.bcc,
                                     subject: "Changed", text: input.text)
        do { _ = try await workflow.createDraft(id: "request-1", input: changed); XCTFail("Changed replay") }
        catch StableErrorCode.replayDetected {}
        try await workflow.requestSend(id: "request-1", revision: created.revision)
        let counts = await native.counts()
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.2, 0)
        let entries = try await workflow.list()
        XCTAssertEqual(entries.first?.state, "awaiting_confirmation")
    }

    func testExactPreviewSendsOnceAndSecondConfirmationIsDenied() async throws {
        let (root, _, native, workflow) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = try await workflow.createDraft(id: "request-2", input: input)
        try await workflow.requestSend(id: preview.id, revision: preview.revision)
        await native.pauseSend()
        let firstConfirmation = Task { try await workflow.confirmSend(id: preview.id, preview: preview, authorize: { true }) }
        await native.waitForSendStart()
        do { _ = try await workflow.confirmSend(id: preview.id, preview: preview, authorize: { true }); XCTFail("Duplicate confirmation") }
        catch StableErrorCode.confirmationExpired {}
        await native.releaseSend()
        let state = try await firstConfirmation.value
        XCTAssertEqual(state, "submitted")
        let counts = await native.counts()
        XCTAssertEqual(counts.2, 1)
        let entries = try await workflow.list()
        XCTAssertEqual(entries.first?.state, "submitted")
        let submitted = try await workflow.draftStatus(id: preview.id)
        XCTAssertEqual(submitted, "submitted")
    }

    func testChangedNativeDraftAndPausePreventSend() async throws {
        let (root, _, native, workflow) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = try await workflow.createDraft(id: "request-3", input: input)
        try await workflow.requestSend(id: preview.id, revision: preview.revision)
        await workflow.setPaused(true)
        do { _ = try await workflow.confirmSend(id: preview.id, preview: preview, authorize: { true }); XCTFail("Paused") }
        catch StableErrorCode.bridgePaused {}
        await workflow.setPaused(false)
        let changed = MailDraftContent(id: "mail.draft.\(first.scopeID).42", scopeID: first.scopeID,
                                       sender: input.sender, to: input.to, cc: input.cc,
                                       bcc: ["changed@example.com"], subject: input.subject,
                                       text: input.text, revision: "changed")
        await native.changeNative(changed)
        do { _ = try await workflow.confirmSend(id: preview.id, preview: preview, authorize: { true }); XCTFail("Edited draft") }
        catch StableErrorCode.confirmationRequired {}
        let counts = await native.counts()
        XCTAssertEqual(counts.2, 0)
    }

    func testUnknownAndInterruptedDispatchRemainUnreplayableAfterRestart() async throws {
        let (root, scope, native, workflow) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("drafts.json")
        let preview = try await workflow.createDraft(id: "request-4", input: input)
        try await workflow.requestSend(id: preview.id, revision: preview.revision)
        await native.setOutcome(.unknown)
        let result = try await workflow.confirmSend(id: preview.id, preview: preview, authorize: { true })
        XCTAssertEqual(result, "unknown")
        let restarted = MailDraftWorkflow(scope: scope, driver: native, storageURL: file)
        do { _ = try await restarted.confirmSend(id: preview.id, preview: preview, authorize: { true }); XCTFail("Unknown replay") }
        catch StableErrorCode.confirmationExpired {}
        var entries = try await restarted.list()
        XCTAssertEqual(entries.first?.state, "unknown")
        entries[0].state = "dispatching"
        try JSONEncoder().encode(entries).write(to: file, options: .atomic)
        let interrupted = MailDraftWorkflow(scope: scope, driver: native, storageURL: file)
        let recovered = try await interrupted.list()
        XCTAssertEqual(recovered.first?.state, "unknown")
        do { _ = try await interrupted.confirmSend(id: preview.id, preview: preview, authorize: { true }); XCTFail("Interrupted replay") }
        catch StableErrorCode.confirmationExpired {}
        let counts = await native.counts()
        XCTAssertEqual(counts.2, 1)
    }

    func testCorruptLedgerAndChangedScopeFailClosed() async throws {
        let (root, scope, native, workflow) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = try await workflow.createDraft(id: "request-5", input: input)
        try await workflow.requestSend(id: preview.id, revision: preview.revision)
        try await scope.choose(second)
        do { _ = try await workflow.confirmSend(id: preview.id, preview: preview, authorize: { true }); XCTFail("Changed scope") }
        catch StableErrorCode.permissionRequired {}
        let counts = await native.counts()
        XCTAssertEqual(counts.2, 0)
        let file = root.appendingPathComponent("corrupt.json")
        try Data("{bad".utf8).write(to: file)
        let corrupt = MailDraftWorkflow(scope: scope, driver: native, storageURL: file)
        do { _ = try await corrupt.list(); XCTFail("Corrupt ledger") }
        catch StableErrorCode.capabilityDisabled {}
        XCTAssertEqual(try Data(contentsOf: file), Data("{bad".utf8))
    }

    func testFinalGateDenialNeverDispatchesAndLedgerHasNoBody() async throws {
        let (root, _, native, workflow) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = try await workflow.createDraft(id: "request-gate", input: input)
        try await workflow.requestSend(id: preview.id, revision: preview.revision)
        do { _ = try await workflow.confirmSend(id: preview.id, preview: preview, authorize: { false }); XCTFail("Gate must reject") }
        catch StableErrorCode.permissionRequired {}
        let counts = await native.counts()
        XCTAssertEqual(counts.2, 0)
        let ledger = try String(contentsOf: root.appendingPathComponent("drafts.json"), encoding: .utf8)
        XCTAssertFalse(ledger.contains("Body"))
        XCTAssertFalse(ledger.contains("to@example.com"))
    }

    func testAgentDuplicateRequestDoesNotExtendConfirmationDeadline() async throws {
        let (root, _, _, workflow) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = try await BridgeExecutionContext.$callerID.withValue("agent") {
            try await workflow.createDraft(id: "request-expiry", input: input)
        }
        try await BridgeExecutionContext.$callerID.withValue("agent") { try await workflow.requestSend(id: preview.id, revision: preview.revision) }
        let firstEntries = try await workflow.list()
        try await BridgeExecutionContext.$callerID.withValue("agent") { try await workflow.requestSend(id: preview.id, revision: preview.revision) }
        let secondEntries = try await workflow.list()
        XCTAssertEqual(firstEntries.first?.requestedAt, secondEntries.first?.requestedAt)
        do {
            _ = try await BridgeExecutionContext.$callerID.withValue("another-agent") { try await workflow.draftStatus(id: preview.id) }
            XCTFail("Another agent must not inspect status")
        } catch StableErrorCode.permissionRequired {}
    }
}
