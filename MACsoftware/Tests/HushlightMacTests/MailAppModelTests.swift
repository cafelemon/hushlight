import Foundation
import XCTest
import BridgeCore
@testable import HushlightMac

private actor MailModelFixture: BridgeService {
    var reads = 0
    var readContinuation: CheckedContinuation<Void, Never>?
    var waiters: [CheckedContinuation<Void, Never>] = []
    var sendRequests = 0
    var actualSends = 0
    func snapshot() async throws -> BridgeSnapshot { .init(status: .localReady, permissions: [], recentActions: []) }
    func setPaused(_ paused: Bool) async throws {}
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
    func selectedMailScope() async throws -> MailScopeKey? { .init(accountID: "test", mailboxPath: ["Inbox"]) }
    func searchMail(query: String, unreadOnly: Bool) async throws -> LocalMailCommandResult {
        .init(status: "succeeded", messages: [.init(id: "test-id", subject: "test", sender: "sender@example.com", receivedAt: Date(), isUnread: true)], isSimulation: true)
    }
    func readMail(id: String) async throws -> LocalMailCommandResult {
        reads += 1
        waiters.forEach { $0.resume() }; waiters = []
        await withCheckedContinuation { readContinuation = $0 }
        return .init(status: "succeeded", mail: .init(message: .init(id: id, subject: "test", sender: "sender@example.com", receivedAt: Date(), isUnread: true), text: "private"), isSimulation: true)
    }
    func waitForRead() async {
        if reads > 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func finishRead() { readContinuation?.resume(); readContinuation = nil }
    func readMailDraft(id: String) async throws -> LocalMailCommandResult {
        .init(status: "succeeded", isSimulation: true, draft: .init(id: id, scopeID: "scope", sender: "sender@example.com", to: ["to@example.com"], cc: [], bcc: ["bcc@example.com"], subject: "test", text: "body", revision: String(repeating: "a", count: 64)))
    }
    func requestMailSend(id: String, revision: String) async throws -> LocalMailCommandResult {
        sendRequests += 1
        return .init(status: "succeeded", isSimulation: true, draftID: id, sendState: "awaiting_confirmation")
    }
    func confirmMailSend(id: String, preview: MailDraftContent, authorize: @escaping @Sendable () async -> Bool) async throws -> String {
        actualSends += 1
        return "submitted"
    }
}

@MainActor final class MailAppModelTests: XCTestCase {
    func testPreparingAndDismissingPreviewDoesNotSend() async {
        let service = MailModelFixture()
        let model = AppModel(bridgeService: service)
        await model.prepareMailSend(id: "draft")
        XCTAssertEqual(model.mailSendPreview?.bcc, ["bcc@example.com"])
        let requests = await service.sendRequests
        XCTAssertEqual(requests, 1)
        model.dismissMailSendPreview()
        await model.confirmMailSend(host: nil)
        let sends = await service.actualSends
        XCTAssertEqual(sends, 0)
        XCTAssertNil(model.mailSendPreview)
    }
    func testReadBlocksDuplicateWhileNavigationAndClearRemainUsable() async {
        let service = MailModelFixture()
        let model = AppModel(bridgeService: service)
        await model.loadMailScope()
        await model.searchMail(query: "test", unreadOnly: true)
        XCTAssertEqual(model.mailMessages.count, 1)
        let read = Task { await model.readMail(id: "test-id") }
        await service.waitForRead()
        await model.readMail(id: "test-id")
        model.selectPage(.timers)
        XCTAssertEqual(model.selectedPage, .timers)
        model.clearMailResults()
        await service.finishRead()
        await read.value
        let count = await service.reads
        XCTAssertEqual(count, 1)
        XCTAssertNil(model.selectedMail)
        XCTAssertTrue(model.mailMessages.isEmpty)
        XCTAssertFalse(model.isBusy(.mail))
    }
}
