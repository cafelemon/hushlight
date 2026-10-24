import Foundation
import XCTest
@testable import BridgeCore

private actor MailRuntimeFixture: MailReadingBackend {
    nonisolated let isSimulation = true
    var scope = "scope-a"
    var calls = 0
    func scopeID() -> String? { scope }
    func search(query: String, unreadOnly: Bool) -> [LocalMailSummary] {
        calls += 1
        return [.init(id: "fake-id", subject: "subject", sender: "sender@example.com", receivedAt: Date(), isUnread: true)]
    }
    func read(id: String) -> LocalMailContent {
        calls += 1
        return .init(message: .init(id: id, subject: "subject", sender: "sender@example.com", receivedAt: Date(), isUnread: true), text: "private-body")
    }
}

final class LocalMailTests: XCTestCase {
    func testRuntimeMailUsesRouterPauseScopeAndMetadataOnlyHistory() async throws {
        let backend = MailRuntimeFixture()
        let runtime = try await BridgeLocalRuntime(simulate: true, mailCoordinator: LocalMailCoordinator(backend: backend))
        let list = await runtime.searchMail(query: "subject", unreadOnly: true)
        XCTAssertEqual(list.status, "succeeded")
        XCTAssertEqual(list.messages.count, 1)
        let content = await runtime.readMail(id: "fake-id")
        XCTAssertEqual(content.mail?.text, "private-body")
        let snapshot = await runtime.snapshot()
        XCTAssertFalse(String(describing: snapshot).contains("private-body"))
        let denied = await BridgeExecutionContext.$mailScopeID.withValue("scope-b") { await runtime.readMail(id: "fake-id") }
        XCTAssertEqual(denied.stableError, "permission_required")
        await runtime.setPaused(true)
        let paused = await runtime.searchMail(query: "", unreadOnly: false)
        XCTAssertEqual(paused.stableError, "bridge_paused")
        let calls = await backend.calls
        XCTAssertEqual(calls, 2)
    }

    func testMailResultsAreNotCachedByRouter() async throws {
        let adapter = LocalMailCoordinator(backend: MailRuntimeFixture())
        let router = try CommandRouter(registry: .mailExtended, adapters: [adapter])
        let command = BridgeCommand(requestID: UUID().uuidString, source: .init(kind: .debugConsole, id: "test"),
            issuedAt: Date(), expiresAt: Date().addingTimeInterval(60), action: "mail.read", riskLevel: .l0,
            parameters: .object(["message_id": .string("fake-id")]), confirmation: nil)
        let result = await router.handle(command)
        XCTAssertEqual(result.status, .succeeded)
        let cached = await router.cachedResult(for: command.requestID)
        XCTAssertNil(cached)
    }

    func testProtocolMailVersionAndParameters() throws {
        let validator = ActionParameterValidator()
        XCTAssertThrowsError(try validator.validate(action: "mail.search", parameters: .emptyObject, protocolVersion: "1.4"))
        XCTAssertNoThrow(try validator.validate(action: "mail.search", parameters: .object(["query": .string(""), "unread_only": .bool(true)]), protocolVersion: "1.5"))
        XCTAssertThrowsError(try validator.validate(action: "mail.read", parameters: .object(["message_id": .string("id"), "account": .string("other")]), protocolVersion: "1.5"))
        let schema = try JSONSerialization.jsonObject(with: BridgeProtocolSchema.data(version: "1.5")) as? [String: Any]
        XCTAssertNotNil(schema)
    }
}
