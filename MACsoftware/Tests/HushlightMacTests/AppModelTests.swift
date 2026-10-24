import Foundation
import BridgeCore
import XCTest
@testable import HushlightMac

@MainActor
final class AppModelTests: XCTestCase {
    func testSelectingEachPageDoesNotStartCapabilities() async {
        let service = ModelServiceFixture()
        let model = AppModel(bridgeService: service)
        for page in WorkbenchPage.allCases {
            model.selectPage(page)
            XCTAssertEqual(model.selectedPage, page)
        }
        let reads = await service.readCount
        let timerActions = await service.timerActionCount
        let pauses = await service.pauseCount
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(timerActions, 0)
        XCTAssertEqual(pauses, 0)
    }

    func testMailScopeDiscoveryAndSelectionRequireExplicitActions() async {
        let service = ModelServiceFixture()
        let model = AppModel(bridgeService: service)
        model.selectPage(.mail)
        await model.loadMailScope()
        var discoveries = await service.mailDiscoveries
        XCTAssertEqual(discoveries, 0)
        XCTAssertTrue(model.mailScopeOptions.isEmpty)
        await model.discoverMailScopes()
        discoveries = await service.mailDiscoveries
        XCTAssertEqual(discoveries, 1)
        XCTAssertEqual(model.mailScopeOptions.count, 1)
        let key = model.mailScopeOptions[0].key
        await model.selectMailScope(key)
        XCTAssertEqual(model.selectedMailScope, key)
        XCTAssertTrue(model.mailScopeVerified)
        XCTAssertFalse(model.isBusy(.mail))
    }

    func testRefreshAndPauseShareOneServiceState() async {
        let service = ModelServiceFixture()
        let model = AppModel(bridgeService: service)
        await model.refresh()
        XCTAssertEqual(model.status, .localReady)
        await model.togglePause()
        XCTAssertTrue(model.isPaused)
        let snapshot = try? await service.snapshot()
        XCTAssertEqual(snapshot?.status, .paused)
        await model.togglePause()
        XCTAssertEqual(model.status, .localReady)
    }

    func testReadShowsResultAndRealActionSnapshot() async {
        let model = AppModel(bridgeService: ModelServiceFixture())
        await model.readSystemVolume()
        XCTAssertEqual(model.volumeReadback?.value, 37)
        XCTAssertEqual(model.recentActions.count, 1)
        XCTAssertNil(model.lastErrorMessage)
        XCTAssertFalse(model.isBusy)
    }

    func testFailedReadClearsPreviousSuccessAndDisplaysFailure() async {
        let service = ModelServiceFixture()
        let model = AppModel(bridgeService: service)
        await model.readSystemVolume()
        await service.setFailure(true)
        await model.readSystemVolume()
        XCTAssertEqual(model.volumeReadback?.outcome, .failed)
        XCTAssertNil(model.volumeReadback?.value)
        XCTAssertNotNil(model.lastErrorMessage)
        XCTAssertFalse(model.isBusy)
    }

    func testDuplicateReadIsBlockedButOtherCapabilityAndPauseRemainAvailable() async {
        let service = ModelServiceFixture(delayRead: true)
        let model = AppModel(bridgeService: service)
        let first = Task { await model.readSystemVolume() }
        await service.waitForReadStart()
        XCTAssertTrue(model.isBusy)
        XCTAssertTrue(model.isBusy(.volume))
        XCTAssertFalse(model.isBusy(.timers))
        await model.readSystemVolume()
        await model.createTimer(after: 30, label: "busy test")
        await model.togglePause()
        let reads = await service.readCount
        let pauses = await service.pauseCount
        let timerActions = await service.timerActionCount
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(timerActions, 1)
        await service.releaseRead()
        await first.value
        XCTAssertFalse(model.isBusy)
    }

    func testInitializationFailureIsUnavailable() async {
        let model = AppModel(bridgeService: UnavailableServiceFixture())
        await model.refresh()
        XCTAssertEqual(model.status, .unavailable)
        XCTAssertNotNil(model.lastErrorMessage)
        XCTAssertFalse(model.isBusy)
    }

    func testTimerCreateUpdateCancelRefreshActualList() async {
        let model = AppModel(bridgeService: ModelServiceFixture())
        await model.createTimer(after: 300, label: "test timer")
        XCTAssertEqual(model.timerActionResult?.outcome, .succeeded)
        guard let id = model.timers.first?.id else { return XCTFail("Expected saved timer") }
        await model.updateTimer(id: id, fireAt: nil, label: "changed")
        XCTAssertEqual(model.timers.first?.label, "changed")
        await model.cancelTimer(id: id)
        XCTAssertTrue(model.timers.isEmpty)
        XCTAssertFalse(model.isBusy)
    }

    func testTimerSuccessDoesNotRemainWhenListRefreshFails() async {
        let service = ModelServiceFixture()
        let model = AppModel(bridgeService: service)
        await model.createTimer(after: 300, label: "first")
        XCTAssertEqual(model.timerActionResult?.outcome, .succeeded)
        await service.setSnapshotFailure(true)
        await model.createTimer(after: 300, label: "second")
        XCTAssertNil(model.timerActionResult)
        XCTAssertNotNil(model.timerError)
        XCTAssertTrue(model.lastErrorMessage?.contains("不要重复创建") == true)
        XCTAssertEqual(model.timers.count, 1)
    }
}

private actor ModelServiceFixture: BridgeService {
    private var paused = false
    private var fails = false
    private var actions: [ActionRecord] = []
    private var timerRecords: [LocalTimerRecord] = []
    private var failsSnapshot = false
    private let delayRead: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var readStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var readCount = 0
    private(set) var pauseCount = 0
    private(set) var timerActionCount = 0
    private(set) var mailDiscoveries = 0
    private var mailSelection: MailScopeKey?

    init(delayRead: Bool = false) { self.delayRead = delayRead }

    func snapshot() async throws -> BridgeSnapshot {
        if failsSnapshot { throw BridgeServiceError.notConfigured }
        return BridgeSnapshot(status: paused ? .paused : .localReady, permissions: [], recentActions: actions, timers: timerRecords)
    }

    func setPaused(_ paused: Bool) async throws {
        self.paused = paused
        pauseCount += 1
    }

    func setFailure(_ failed: Bool) { fails = failed }
    func setSnapshotFailure(_ failed: Bool) { failsSnapshot = failed }

    func selectedMailScope() async throws -> MailScopeKey? { mailSelection }
    func listMailScopes() async throws -> [MailScopeOption] {
        mailDiscoveries += 1
        return [.init(key: .init(accountID: "test-account", mailboxPath: ["Inbox"]),
                      accountName: "Test", accountAddresses: ["mailbox@example.com"])]
    }
    func selectMailScope(_ key: MailScopeKey) async throws { mailSelection = key }

    func createTimer(id: String, fireAt: Date, label: String) async throws -> TimerActionReadback {
        timerActionCount += 1
        timerRecords.append(LocalTimerRecord(id: id, fireAt: fireAt, label: label))
        return TimerActionReadback(outcome: .succeeded, stableError: nil, completedAt: Date())
    }

    func updateTimer(id: String, fireAt: Date?, label: String?) async throws -> TimerActionReadback {
        timerActionCount += 1
        if let index = timerRecords.firstIndex(where: { $0.id == id }) {
            let record = timerRecords[index]
            timerRecords[index] = LocalTimerRecord(id: id, fireAt: fireAt ?? record.fireAt, label: label ?? record.label)
        }
        return TimerActionReadback(outcome: .succeeded, stableError: nil, completedAt: Date())
    }

    func cancelTimer(id: String) async throws -> TimerActionReadback {
        timerActionCount += 1
        timerRecords.removeAll { $0.id == id }
        return TimerActionReadback(outcome: .succeeded, stableError: nil, completedAt: Date())
    }

    func readSystemVolume() async throws -> VolumeReadback {
        readCount += 1
        readStartWaiters.forEach { $0.resume() }
        readStartWaiters.removeAll()
        if delayRead { await withCheckedContinuation { continuation = $0 } }
        let outcome: ActionOutcome = fails ? .failed : .succeeded
        let now = Date()
        actions.append(ActionRecord(name: "读取系统音量", outcome: outcome, occurredAt: now))
        return VolumeReadback(outcome: outcome, stableError: fails ? "internal_error" : nil,
                              value: fails ? nil : 37, muted: fails ? nil : true, readAt: now)
    }

    func waitForReadStart() async {
        if readCount > 0 { return }
        await withCheckedContinuation { readStartWaiters.append($0) }
    }

    func releaseRead() { continuation?.resume(); continuation = nil }
}

private struct UnavailableServiceFixture: BridgeService {
    func snapshot() async throws -> BridgeSnapshot { throw BridgeServiceError.notConfigured }
    func setPaused(_ paused: Bool) async throws { throw BridgeServiceError.notConfigured }
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
}
