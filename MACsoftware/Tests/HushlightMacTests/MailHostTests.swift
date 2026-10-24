import XCTest
import Foundation
import WorkbenchKit
import BridgeCore
@testable import HushlightMac

private actor MailHostFixture: BridgeService {
    var scope = "scope-a"
    var blockAfterRead = false
    var pending: CheckedContinuation<Void, Never>?
    var waiters: [CheckedContinuation<Void, Never>] = []
    func snapshot() async throws -> BridgeSnapshot { .init(status: .localReady, permissions: [], recentActions: []) }
    func setPaused(_ paused: Bool) async throws {}
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
    func workbenchState() async throws -> WorkbenchServiceState {
        if blockAfterRead {
            waiters.forEach { $0.resume() }; waiters = []
            await withCheckedContinuation { pending = $0 }
        }
        return .init(status: "localReady", supportedActions: ["mail.search", "mail.read"], isSimulation: true, mailScopeID: scope)
    }
    func searchMail(query: String, unreadOnly: Bool) async throws -> LocalMailCommandResult { .init(status: "succeeded") }
    func readMail(id: String) async throws -> LocalMailCommandResult {
        blockAfterRead = true
        return .init(status: "succeeded", mail: .init(message: .init(id: id, subject: "private-subject", sender: "private@example.com", receivedAt: Date(), isUnread: true), text: "private-body"))
    }
    func changeScope() { scope = "scope-b" }
    func waitForBlockedStatus() async {
        if pending != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func releaseStatus() { blockAfterRead = false; pending?.resume(); pending = nil }
}

final class MailHostTests: XCTestCase {
    func testMailGrantBindsScopeAndDoesNotFollowSelectionChange() async throws {
        let root = URL(fileURLWithPath: "/tmp/mail-host-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = MailHostFixture()
        let host = try WorkbenchHost(bridge: bridge, directory: root)
        let client = try await host.createClient(name: "Mail")
        func request(_ operation: String, action: String? = nil) -> WorkbenchRequest {
            .init(requestID: UUID().uuidString, operation: operation, action: action, credential: client.credential)
        }
        var response = await host.process(request("action", action: "mail.search"))
        XCTAssertEqual(response.error, "permission_required")
        try await host.setGrants(clientID: client.id, grants: [.mailRead])
        response = await host.process(request("action", action: "mail.search"))
        XCTAssertEqual(response.status, "succeeded")
        await bridge.changeScope()
        response = await host.process(request("action", action: "mail.search"))
        XCTAssertEqual(response.error, "permission_required")
        let discovery = await host.process(request("capabilities"))
        if case .object(let fields) = discovery.result { XCTAssertEqual(fields["actions"], .array([])) }
        else { XCTFail("Expected discovery") }
        try await host.setGrants(clientID: client.id, grants: [.mailRead])
        response = await host.process(request("action", action: "mail.search"))
        XCTAssertEqual(response.status, "succeeded")
    }

    func testRevocationWhilePostReadStatusSuspendsDiscardsBody() async throws {
        let root = URL(fileURLWithPath: "/tmp/mail-host-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = MailHostFixture()
        let host = try WorkbenchHost(bridge: bridge, directory: root)
        let client = try await host.createClient(name: "Mail")
        try await host.setGrants(clientID: client.id, grants: [.mailRead])
        let request = WorkbenchRequest(requestID: UUID().uuidString, operation: "action", action: "mail.read",
            parameters: .object(["message_id": .string("id")]), credential: client.credential)
        let read = Task { await host.process(request) }
        await bridge.waitForBlockedStatus()
        try await host.revoke(clientID: client.id)
        await bridge.releaseStatus()
        let response = await read.value
        XCTAssertEqual(response.error, "permission_required")
        XCTAssertEqual(response.result, .object([:]))
        let history = await host.history()
        XCTAssertFalse(String(describing: history).contains("private-body"))
    }
}
