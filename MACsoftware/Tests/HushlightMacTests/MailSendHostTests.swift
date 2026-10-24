import Foundation
import XCTest
import BridgeCore
import WorkbenchKit
@testable import HushlightMac

private actor SendHostBridge: BridgeService {
    var owner = ""
    var sends = 0
    var waiting: CheckedContinuation<Void, Never>?
    var startedWaiters: [CheckedContinuation<Void, Never>] = []
    let preview = MailDraftContent(id: "draft", scopeID: "scope", sender: "sender@example.com", to: ["to@example.com"], cc: [], bcc: [], subject: "test", text: "body", revision: String(repeating: "a", count: 64))
    func setOwner(_ id: String) { owner = id }
    func snapshot() async throws -> BridgeSnapshot { .init(status: .localReady, permissions: [], recentActions: []) }
    func workbenchState() async throws -> WorkbenchServiceState { .init(status: "localReady", supportedActions: ["mail.send.request"], isSimulation: true, mailScopeID: "scope") }
    func setPaused(_ value: Bool) async throws {}
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
    func mailDrafts() async throws -> [MailDraftEntry] { [.init(id: "draft", owner: owner, scopeID: "scope", inputHash: "hash", state: "awaiting_confirmation")] }
    func confirmMailSend(id: String, preview: MailDraftContent, authorize: @escaping @Sendable () async -> Bool) async throws -> String {
        startedWaiters.forEach { $0.resume() }; startedWaiters = []
        await withCheckedContinuation { waiting = $0 }
        guard await authorize() else { throw StableErrorCode.permissionRequired }
        sends += 1
        return "submitted"
    }
    func waitForFinalCheck() async {
        if waiting != nil { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }
    func release() { waiting?.resume(); waiting = nil }
}

final class MailSendHostTests: XCTestCase {
    func testRevokedSendGrantDuringReadPreflightBlocksFinalAdmission() async throws {
        let root = URL(fileURLWithPath: "/tmp/mail-send-host-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = SendHostBridge()
        let host = try WorkbenchHost(bridge: bridge, directory: root)
        let client = try await host.createClient(name: "Mail sender")
        await bridge.setOwner(client.id)
        try await host.setGrants(clientID: client.id, grants: [.mailSendRequest])
        let preview = await bridge.preview
        let confirmation = Task { try await host.confirmMailSend(id: "draft", preview: preview) }
        await bridge.waitForFinalCheck()
        try await host.revoke(clientID: client.id)
        await bridge.release()
        do { _ = try await confirmation.value; XCTFail("Revoked grant") }
        catch StableErrorCode.permissionRequired {}
        let count = await bridge.sends
        XCTAssertEqual(count, 0)
    }

    func testWireCannotSubmitConfirmationOrDirectSend() async throws {
        let root = URL(fileURLWithPath: "/tmp/mail-send-host-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try WorkbenchHost(bridge: SendHostBridge(), directory: root)
        let client = try await host.createClient(name: "Mail sender")
        try await host.setGrants(clientID: client.id, grants: [.mailSendRequest])
        let direct = await host.process(.init(requestID: UUID().uuidString, operation: "action", action: "mail.send", credential: client.credential))
        XCTAssertEqual(direct.error, "capability_disabled")
        let approval = await host.process(.init(requestID: UUID().uuidString, operation: "confirmMailSend", credential: client.credential))
        XCTAssertEqual(approval.error, "invalid_schema")
    }
}
