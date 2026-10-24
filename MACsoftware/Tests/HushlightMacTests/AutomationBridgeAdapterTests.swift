import BridgeCore
import XCTest
@testable import HushlightMac

private actor AutomationDraftBridge: BridgeService {
    nonisolated static let key = MailScopeKey(accountID: "a", mailboxPath: ["Inbox"])
    var capturedScope: String?
    var calls = 0
    func snapshot() async throws -> BridgeSnapshot { .init(status: .localReady, permissions: [], recentActions: []) }
    func workbenchState() async throws -> WorkbenchServiceState { .init(status: "localReady", supportedActions: [], isSimulation: false, mailScopeID: "scope-a") }
    func selectedMailScope() async throws -> MailScopeKey? { Self.key }
    func automationResources() async -> [AutomationAction: String] { [.createDraft: Self.key.scopeID] }
    func setPaused(_ value: Bool) async throws {}
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
    func createMailDraft(id: String, input: MailDraftInput) async throws -> LocalMailCommandResult {
        capturedScope = BridgeExecutionContext.mailScopeID
        calls += 1
        return .init(status: "succeeded", draftID: id)
    }
}

final class AutomationBridgeAdapterTests: XCTestCase {
    func testMultibyteInputBoundedWithoutReplacementCharacters() {
        let input = String(repeating: "邮件📬", count: 12000)
        let output = BridgeAutomationInput.prefixUTF8(input, bytes: 24000)
        XCTAssertLessThanOrEqual(output.utf8.count, 24000)
        XCTAssertTrue(input.hasPrefix(output))
        XCTAssertFalse(output.contains("�"))
    }
    func testDraftUsesFrozenSourceScopeAndCannotSend() async throws {
        let bridge = AutomationDraftBridge()
        let driver = BridgeAutomationEffects(bridge: bridge)
        let result = try await driver.apply(.init(action: .createDraft, title: "Reply", body: "Draft only", confidence: 1),
            idempotencyKey: "stable", resourceID: AutomationDraftBridge.key.scopeID,
            sourceMetadata: ["scopeID": AutomationDraftBridge.key.scopeID, "sender": "me@example.com", "replyTo": "sender@example.com", "subject": "Topic"],
            authorization: .init(leaseID: UUID(), validate: { true }))
        XCTAssertEqual(result, "automation.stable")
        let scope = await bridge.capturedScope, calls = await bridge.calls
        XCTAssertEqual(scope, AutomationDraftBridge.key.scopeID); XCTAssertEqual(calls, 1)
        do {
            _ = try await driver.apply(.init(action: .createDraft, title: "Reply", body: "body", confidence: 1),
                idempotencyKey: "other", resourceID: "scope-b", sourceMetadata: [:],
                authorization: .init(leaseID: UUID(), validate: { true }))
            XCTFail("Scope change must reject")
        } catch AutomationError.unauthorized {}
        let count = await bridge.calls
        XCTAssertEqual(count, 1)
    }
}
