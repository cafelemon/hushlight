import BridgeCore
import XCTest
@testable import HushlightMac

private actor CollectionBridge: BridgeService {
    enum Interruption: Sendable { case pause, changeScope, cancel, unavailable }
    static let scope = MailScopeKey(accountID: "synthetic", mailboxPath: ["Inbox"])
    let interruption: Interruption
    var reads: [String] = []
    var paused = false
    var changedScope = false
    init(_ interruption: Interruption) { self.interruption = interruption }
    func snapshot() async throws -> BridgeSnapshot { .init(status: .localReady, permissions: [], recentActions: []) }
    func setPaused(_ value: Bool) async throws { paused = value }
    func workbenchState() async throws -> WorkbenchServiceState {
        .init(status: paused ? "paused" : "localReady", supportedActions: [], isSimulation: false)
    }
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
    func selectedMailScope() async throws -> MailScopeKey? {
        changedScope ? .init(accountID: "other", mailboxPath: ["Inbox"]) : Self.scope
    }
    func mailSender() async throws -> String { "me@example.com" }
    func mailBaseline() async throws -> MailIncrementalCursor {
        .init(scopeID: Self.scope.scopeID, baselineAt: .distantPast, watermark: .distantPast, recent: [])
    }
    func pollMail(after cursor: MailIncrementalCursor) async throws -> MailIncrementalPoll {
        .init(messages: [message("first"), message("second")], nextCursor: cursor, hasMore: false)
    }
    func readMail(id: String) async throws -> LocalMailCommandResult {
        reads.append(id)
        switch interruption {
        case .pause: paused = true
        case .changeScope: changedScope = true
        case .cancel: throw CancellationError()
        case .unavailable: throw BridgeServiceError.notConfigured
        }
        return .init(status: "succeeded", mail: .init(message: message(id), text: "Synthetic body"))
    }
    func readIDs() -> [String] { reads }
    private func message(_ id: String) -> LocalMailSummary {
        .init(id: id, subject: "Synthetic", sender: "sender@example.com", receivedAt: Date(), isUnread: true)
    }
}

final class AutomationMailCollectionTests: XCTestCase {
    private func rule() -> AutomationRule {
        .init(id: "mail", title: "Mail", trigger: .mailPoll(scopeID: CollectionBridge.scope.scopeID, intervalSeconds: 300), grantedActions: [.notify], enabled: true)
    }
    func testPauseAndScopeChangeStopRemainingBodyReads() async throws {
        for interruption in [CollectionBridge.Interruption.pause, .changeScope] {
            let bridge = CollectionBridge(interruption)
            let input = BridgeAutomationInput(bridge: bridge, mailAuthorization: { true })
            do { _ = try await input.collect(rule: rule(), cursor: nil); XCTFail("Must stop collection without committing a cursor") }
            catch AutomationError.unauthorized {}
            let reads = await bridge.readIDs()
            XCTAssertEqual(reads, ["first"])
        }
    }
    func testCancellationIsNotConvertedToBodyUnavailable() async throws {
        let bridge = CollectionBridge(.cancel)
        let input = BridgeAutomationInput(bridge: bridge, mailAuthorization: { true })
        do { _ = try await input.collect(rule: rule(), cursor: nil); XCTFail("Cancellation must escape") }
        catch is CancellationError {}
        let reads = await bridge.readIDs()
        XCTAssertEqual(reads, ["first"])
    }
    func testUnreadableBodyStillProducesMetadataOnlyReviewItem() async throws {
        let bridge = CollectionBridge(.unavailable)
        let input = BridgeAutomationInput(bridge: bridge, mailAuthorization: { true })
        let batch = try await input.collect(rule: rule(), cursor: nil)
        XCTAssertEqual(batch.items.count, 2)
        XCTAssertTrue(batch.items.allSatisfy { $0.metadata["bodyUnavailable"] == "true" })
        XCTAssertFalse(batch.items.contains { $0.text.contains("Synthetic body") })
    }
    func testMissingSystemAuthorizationDoesNotReadBodies() async throws {
        let bridge = CollectionBridge(.unavailable)
        let input = BridgeAutomationInput(bridge: bridge, mailAuthorization: { false })
        do { _ = try await input.collect(rule: rule(), cursor: nil); XCTFail("Missing authorization") }
        catch AutomationError.unauthorized {}
        let reads = await bridge.readIDs()
        XCTAssertTrue(reads.isEmpty)
    }
}

private actor ScopeChangingNoteBridge: BridgeService {
    static let original = MailScopeKey(accountID: "synthetic", mailboxPath: ["Inbox"])
    var changed = false
    var appendCalls = 0
    func snapshot() async throws -> BridgeSnapshot { .init(status: .localReady, permissions: [], recentActions: []) }
    func setPaused(_ value: Bool) async throws {}
    func workbenchState() async throws -> WorkbenchServiceState {
        .init(status: "localReady", supportedActions: [], isSimulation: false)
    }
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
    func selectedMailScope() async throws -> MailScopeKey? {
        changed ? .init(accountID: "different", mailboxPath: ["Inbox"]) : Self.original
    }
    func automationResources() async -> [AutomationAction: String] { [.appendDailyNote: "note-folder"] }
    func readNote(id: String) async throws -> LocalNotesCommandResult {
        changed = true // Scope was switched during an awaited read, before the final append permit.
        return .init(status: "succeeded", stableError: nil, completedAt: Date(),
            note: .init(id: id, title: "Synthetic", text: "Existing", revision: "revision", canAppend: true))
    }
    func appendNote(id: String, text: String, expectedRevision: String) async throws -> LocalNotesCommandResult {
        appendCalls += 1
        return .init(status: "succeeded", stableError: nil, completedAt: Date())
    }
    func writes() -> Int { appendCalls }
}

extension AutomationMailCollectionTests {
    func testScopeRevokedDuringNoteReadBlocksFinalAppend() async throws {
        let bridge = ScopeChangingNoteBridge()
        let effects = BridgeAutomationEffects(bridge: bridge)
        do {
            _ = try await effects.apply(.init(action: .appendDailyNote, title: "Synthetic", body: "Synthetic", confidence: 1),
                idempotencyKey: "test", resourceID: "note-folder",
                sourceMetadata: ["scopeID": ScopeChangingNoteBridge.original.scopeID, "source": "synthetic", "day": "2026-10-23"],
                authorization: .init(leaseID: UUID(), validate: { true }))
            XCTFail("Changed mail scope must invalidate the final write permit")
        } catch AutomationError.unauthorized {}
        let writes = await bridge.writes()
        XCTAssertEqual(writes, 0)
    }
}
