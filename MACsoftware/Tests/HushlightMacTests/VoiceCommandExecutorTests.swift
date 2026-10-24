import Foundation
import XCTest
import BridgeCore
@testable import HushlightMac

private actor VoiceExecutorBridge: BridgeService {
    var status = "localReady"
    var simulated = false
    var timerOutcome: ActionOutcome = .succeeded
    var timerCalls = 0
    var volumeCalls = 0
    var weatherCalls = 0
    var timers: [LocalTimerRecord] = []
    var holdTimer: CheckedContinuation<Void, Never>?
    var hold = false
    var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    var stateCalls = 0
    var holdStateAtCall: Int?
    var heldState: CheckedContinuation<Void, Never>?
    var stateWaiters: [CheckedContinuation<Void, Never>] = []

    func setStatus(_ value: String) { status = value }
    func setSimulation(_ value: Bool) { simulated = value }
    func setTimerOutcome(_ value: ActionOutcome) { timerOutcome = value }
    func setTimers(_ value: [LocalTimerRecord]) { timers = value }
    func setHold(_ value: Bool) { hold = value }
    func releaseTimer() { holdTimer?.resume(); holdTimer = nil }
    func waitUntilTimerCalled() async {
        if timerCalls > 0 { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func holdState(at call: Int) { holdStateAtCall = call }
    func waitUntilStateHeld() async {
        if heldState != nil { return }
        await withCheckedContinuation { stateWaiters.append($0) }
    }
    func releaseState() { heldState?.resume(); heldState = nil }

    func snapshot() async throws -> BridgeSnapshot { throw BridgeServiceError.notConfigured }
    func setPaused(_ paused: Bool) async throws { status = paused ? "paused" : "localReady" }
    func workbenchState() async throws -> WorkbenchServiceState {
        stateCalls += 1
        if stateCalls == holdStateAtCall {
            await withCheckedContinuation { continuation in
                heldState = continuation
                for waiter in stateWaiters { waiter.resume() }
                stateWaiters = []
            }
        }
        return .init(status: status, supportedActions: [], isSimulation: simulated)
    }
    func workbenchTimers() async throws -> [LocalTimerRecord] { timers }
    func readSystemVolume() async throws -> VolumeReadback {
        volumeCalls += 1
        return .init(outcome: .succeeded, stableError: nil, value: 42, muted: false, readAt: Date(), isSimulation: simulated)
    }
    func readWeather(cityID: String) async throws -> LocalWeatherCommandResult {
        weatherCalls += 1
        let city = WeatherCities.byID(cityID)!
        let point = WeatherPoint(time: Date(), temperatureC: 20, relativeHumidityPercent: 50, windSpeedMS: 2, symbol: nil)
        let report = WeatherReport(city: city, modelUpdatedAt: Date(), fetchedAt: Date(), current: point, hourly: [], isCached: false)
        return .init(status: "succeeded", stableError: nil, completedAt: Date(), report: report, isSimulation: simulated)
    }
    func createTimer(id: String, fireAt: Date, label: String) async throws -> TimerActionReadback {
        timerCalls += 1
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters = []
        if hold { await withCheckedContinuation { holdTimer = $0 } }
        if timerOutcome == .succeeded { timers.append(.init(id: id, fireAt: fireAt, label: label)) }
        return .init(outcome: timerOutcome, stableError: nil, completedAt: Date())
    }
}

private actor VoiceAuthorizationFlag {
    var allowed = true
    func revoke() { allowed = false }
    func check() -> Bool { allowed }
}

final class VoiceCommandExecutorTests: XCTestCase {
    private func journal() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-executor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("voice-command-journal.json")
    }

    func testAuthorizationPauseSimulationAndInvalidInputsNeverDispatch() async throws {
        let bridge = VoiceExecutorBridge()
        let executor = BridgeVoiceCommandExecutor(bridge: bridge, journalURL: try journal())
        let deny: @Sendable () async -> Bool = { false }
        let allow: @Sendable () async -> Bool = { true }
        let id = UUID()
        let actual1 = await executor.execute(id: id, action: .timerCreate(label: "计时器", seconds: 5), authorize: deny).outcome
        XCTAssertEqual(actual1, .denied)
        await bridge.setStatus("paused")
        let actual2 = await executor.execute(id: UUID(), action: .volumeRead, authorize: allow).outcome
        XCTAssertEqual(actual2, .denied)
        await bridge.setStatus("localReady")
        await bridge.setSimulation(true)
        let simulated = await executor.execute(id: UUID(), action: .weatherGet(cityID: "beijing"), authorize: allow)
        XCTAssertEqual(simulated.outcome, .denied)
        XCTAssertTrue(simulated.isSimulation)
        await bridge.setSimulation(false)
        let actual4 = await executor.execute(id: UUID(), action: .timerCreate(label: "bad\n", seconds: 5), authorize: allow).outcome
        XCTAssertEqual(actual4, .denied)
        let actual5 = await executor.execute(id: UUID(), action: .timerCreate(label: "计时器", seconds: 4), authorize: allow).outcome
        XCTAssertEqual(actual5, .denied)
        let actual6 = await executor.execute(id: UUID(), action: .weatherGet(cityID: "wrong"), authorize: allow).outcome
        XCTAssertEqual(actual6, .denied)
        let actual7 = await bridge.timerCalls
        XCTAssertEqual(actual7, 0)
        let actual8 = await bridge.volumeCalls
        XCTAssertEqual(actual8, 0)
        let actual9 = await bridge.weatherCalls
        XCTAssertEqual(actual9, 0)
    }

    func testReadOnlyActionsUseBridgeAndRequireFreshAuthorization() async throws {
        let bridge = VoiceExecutorBridge()
        let executor = BridgeVoiceCommandExecutor(bridge: bridge, journalURL: try journal())
        let allow: @Sendable () async -> Bool = { true }
        let volume = await executor.execute(id: UUID(), action: .volumeRead, authorize: allow)
        XCTAssertEqual(volume.outcome, .succeeded)
        XCTAssertTrue(volume.message.contains("42%"))
        let weather = await executor.execute(id: UUID(), action: .weatherGet(cityID: "beijing"), authorize: allow)
        XCTAssertEqual(weather.outcome, .succeeded)
        XCTAssertTrue(weather.message.contains("北京"))
        let pausedBridge = bridge
        let revoke: @Sendable () async -> Bool = {
            await pausedBridge.setStatus("paused")
            return true
        }
        let actual10 = await executor.execute(id: UUID(), action: .volumeRead, authorize: revoke).outcome
        XCTAssertEqual(actual10, .denied)
        let actual11 = await bridge.volumeCalls
        XCTAssertEqual(actual11, 1)
    }

    func testConfirmationRevokedDuringFinalStateAwaitPreventsTimerDispatch() async throws {
        let bridge = VoiceExecutorBridge()
        await bridge.holdState(at: 3)
        let flag = VoiceAuthorizationFlag()
        let authorize: @Sendable () async -> Bool = { await flag.check() }
        let executor = BridgeVoiceCommandExecutor(bridge: bridge, journalURL: try journal())
        let pending = Task { await executor.execute(id: UUID(), action: .timerCreate(label: "计时器", seconds: 5), authorize: authorize) }
        await bridge.waitUntilStateHeld()
        await flag.revoke()
        await bridge.releaseState()
        let result = await pending.value
        XCTAssertEqual(result.outcome, .denied)
        let calls = await bridge.timerCalls
        XCTAssertEqual(calls, 0)
    }

    func testArchivedReceiptCompletesBeforeFinalAuthorization() async throws {
        let file = try journal()
        let bridge = VoiceExecutorBridge()
        let flag = VoiceAuthorizationFlag()
        let authorize: @Sendable () async -> Bool = { await flag.check() }
        let executor = BridgeVoiceCommandExecutor(bridge: bridge, journalURL: file, activeLimit: 1)
        let action = VoiceCommandAction.timerCreate(label: "计时器", seconds: 5)
        let firstID = UUID()
        let first = await executor.execute(id: firstID, action: action, authorize: authorize)
        XCTAssertEqual(first.outcome, .succeeded)
        await bridge.holdState(at: 6)
        let pending = Task { await executor.execute(id: UUID(), action: action, authorize: authorize) }
        await bridge.waitUntilStateHeld()
        let archived = file.deletingLastPathComponent()
            .appendingPathComponent("voice-command-receipts/\(firstID.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.path))
        await flag.revoke()
        await bridge.releaseState()
        let second = await pending.value
        XCTAssertEqual(second.outcome, .denied)
        let calls = await bridge.timerCalls
        XCTAssertEqual(calls, 1)
    }

    func testTimerPersistsMetadataDedupeAndDigestMismatch() async throws {
        let file = try journal()
        let bridge = VoiceExecutorBridge()
        let executor = BridgeVoiceCommandExecutor(bridge: bridge, journalURL: file)
        let allow: @Sendable () async -> Bool = { true }
        let id = UUID()
        let action = VoiceCommandAction.timerCreate(label: "私密标签", seconds: 5)
        let actual12 = await executor.execute(id: id, action: action, authorize: allow).outcome
        XCTAssertEqual(actual12, .succeeded)
        let bytes = try Data(contentsOf: file)
        let content = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(content.contains("私密标签"))
        XCTAssertFalse(content.contains("timer_create"))
        let actual13 = await executor.execute(id: id, action: action, authorize: allow).outcome
        XCTAssertEqual(actual13, .succeeded)
        let actual14 = await executor.execute(id: id, action: .timerCreate(label: "另一个", seconds: 5), authorize: allow).outcome
        XCTAssertEqual(actual14, .denied)
        let restarted = BridgeVoiceCommandExecutor(bridge: bridge, journalURL: file)
        let actual15 = await restarted.execute(id: id, action: action, authorize: allow).outcome
        XCTAssertEqual(actual15, .succeeded)
        let actual16 = await bridge.timerCalls
        XCTAssertEqual(actual16, 1)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testConcurrentDuplicateAndRestartedDispatchingAreNeverReplayed() async throws {
        let file = try journal()
        let bridge = VoiceExecutorBridge()
        await bridge.setHold(true)
        let executor = BridgeVoiceCommandExecutor(bridge: bridge, journalURL: file)
        let allow: @Sendable () async -> Bool = { true }
        let id = UUID()
        let action = VoiceCommandAction.timerCreate(label: "计时器", seconds: 5)
        let first = Task { await executor.execute(id: id, action: action, authorize: allow) }
        await bridge.waitUntilTimerCalled()
        let actual17 = await executor.execute(id: id, action: action, authorize: allow).outcome
        XCTAssertEqual(actual17, .unknown)
        let restarted = BridgeVoiceCommandExecutor(bridge: bridge, journalURL: file)
        let actual18 = await restarted.execute(id: id, action: action, authorize: allow).outcome
        XCTAssertEqual(actual18, .unknown)
        let actual19 = await restarted.unresolvedTimerIDs()
        XCTAssertEqual(actual19, [id])
        await bridge.releaseTimer()
        let actual20 = await first.value.outcome
        XCTAssertEqual(actual20, .succeeded)
        let actual21 = await bridge.timerCalls
        XCTAssertEqual(actual21, 1)
    }

    func testUnknownNeedsAcknowledgementAndNeverReplaysOriginalID() async throws {
        let file = try journal()
        let bridge = VoiceExecutorBridge()
        await bridge.setTimerOutcome(.unknown)
        let executor = BridgeVoiceCommandExecutor(bridge: bridge, journalURL: file)
        let allow: @Sendable () async -> Bool = { true }
        let firstID = UUID()
        let action = VoiceCommandAction.timerCreate(label: "计时器", seconds: 5)
        let actual22 = await executor.execute(id: firstID, action: action, authorize: allow).outcome
        XCTAssertEqual(actual22, .unknown)
        let restarted = BridgeVoiceCommandExecutor(bridge: bridge, journalURL: file)
        let actual23 = await restarted.unresolvedTimerIDs()
        XCTAssertEqual(actual23, [firstID])
        let actual24 = await restarted.execute(id: UUID(), action: action, authorize: allow).outcome
        XCTAssertEqual(actual24, .denied)
        let actual25 = await restarted.acknowledgeUnknown(id: firstID)
        XCTAssertTrue(actual25)
        let actual26 = await restarted.unresolvedTimerIDs()
        XCTAssertEqual(actual26, [])
        let actual27 = await restarted.execute(id: firstID, action: action, authorize: allow).outcome
        XCTAssertEqual(actual27, .unknown)
        await bridge.setTimerOutcome(.succeeded)
        let actual28 = await restarted.execute(id: UUID(), action: action, authorize: allow).outcome
        XCTAssertEqual(actual28, .succeeded)
        let actual29 = await bridge.timerCalls
        XCTAssertEqual(actual29, 2)
    }

    func testDesiredTimerListPresenceDoesNotResolveUnknown() async throws {
        let file = try journal()
        let bridge = VoiceExecutorBridge()
        await bridge.setTimerOutcome(.unknown)
        let executor = BridgeVoiceCommandExecutor(bridge: bridge, journalURL: file)
        let allow: @Sendable () async -> Bool = { true }
        let id = UUID()
        let action = VoiceCommandAction.timerCreate(label: "计时器", seconds: 5)
        let first = await executor.execute(id: id, action: action, authorize: allow)
        XCTAssertEqual(first.outcome, .unknown)
        await bridge.setTimers([.init(id: id.uuidString, fireAt: Date().addingTimeInterval(5), label: "计时器")])
        let unresolved = await executor.unresolvedTimerIDs()
        XCTAssertEqual(unresolved, [id])
        let same = await executor.execute(id: id, action: action, authorize: allow)
        XCTAssertEqual(same.outcome, .unknown)
        let new = await executor.execute(id: UUID(), action: action, authorize: allow)
        XCTAssertEqual(new.outcome, .denied)
        let calls = await bridge.timerCalls
        XCTAssertEqual(calls, 1)
    }

    func testCompletionPersistenceFailureStaysUnknownAndDoesNotRepeat() async throws {
        let file = try journal()
        let bridge = VoiceExecutorBridge()
        await bridge.setHold(true)
        let executor = BridgeVoiceCommandExecutor(bridge: bridge, journalURL: file)
        let allow: @Sendable () async -> Bool = { true }
        let id = UUID()
        let action = VoiceCommandAction.timerCreate(label: "计时器", seconds: 5)
        let pending = Task { await executor.execute(id: id, action: action, authorize: allow) }
        await bridge.waitUntilTimerCalled()
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await bridge.releaseTimer()
        let result = await pending.value
        XCTAssertEqual(result.outcome, .unknown)
        let same = await executor.execute(id: id, action: action, authorize: allow)
        XCTAssertEqual(same.outcome, .unknown)
        let calls = await bridge.timerCalls
        XCTAssertEqual(calls, 1)
    }

    func testTerminalReceiptsRotateAndArchivedIDNeverReplaysAfterRestart() async throws {
        let file = try journal()
        let bridge = VoiceExecutorBridge()
        let allow: @Sendable () async -> Bool = { true }
        let executor = BridgeVoiceCommandExecutor(bridge: bridge, journalURL: file, activeLimit: 2)
        let ids = (0..<6).map { _ in UUID() }
        let action = VoiceCommandAction.timerCreate(label: "计时器", seconds: 5)
        for id in ids {
            let outcome = await executor.execute(id: id, action: action, authorize: allow)
            XCTAssertEqual(outcome.outcome, .succeeded)
        }
        let archive = file.deletingLastPathComponent().appendingPathComponent("voice-command-receipts")
        let files = try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 4)
        let active = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]]
        XCTAssertEqual(active?.count, 2)
        let archivedFile = archive.appendingPathComponent(ids[0].uuidString + ".json")
        let attrs = try FileManager.default.attributesOfItem(atPath: archivedFile.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let restarted = BridgeVoiceCommandExecutor(bridge: bridge, journalURL: file, activeLimit: 2)
        let same = await restarted.execute(id: ids[0], action: action, authorize: allow)
        XCTAssertEqual(same.outcome, .succeeded)
        let changed = await restarted.execute(id: ids[0], action: .timerCreate(label: "别名", seconds: 5), authorize: allow)
        XCTAssertEqual(changed.outcome, .denied)
        let calls = await bridge.timerCalls
        XCTAssertEqual(calls, 6)
    }

    func testCorruptArchivedReceiptDeniesOnlyItsID() async throws {
        let file = try journal()
        let bridge = VoiceExecutorBridge()
        let allow: @Sendable () async -> Bool = { true }
        let executor = BridgeVoiceCommandExecutor(bridge: bridge, journalURL: file, activeLimit: 2)
        let action = VoiceCommandAction.timerCreate(label: "计时器", seconds: 5)
        let firstID = UUID()
        for id in [firstID, UUID(), UUID()] {
            let result = await executor.execute(id: id, action: action, authorize: allow)
            XCTAssertEqual(result.outcome, .succeeded)
        }
        let archiveFile = file.deletingLastPathComponent().appendingPathComponent("voice-command-receipts/\(firstID.uuidString).json")
        try Data("corrupt".utf8).write(to: archiveFile)
        let restarted = BridgeVoiceCommandExecutor(bridge: bridge, journalURL: file, activeLimit: 2)
        let old = await restarted.execute(id: firstID, action: action, authorize: allow)
        XCTAssertEqual(old.outcome, .denied)
        let fresh = await restarted.execute(id: UUID(), action: action, authorize: allow)
        XCTAssertEqual(fresh.outcome, .succeeded)
        let calls = await bridge.timerCalls
        XCTAssertEqual(calls, 4)
    }

    func testCorruptAndUnwritableJournalBlockTimerWithoutDispatch() async throws {
        let file = try journal()
        try Data("broken".utf8).write(to: file)
        let bridge = VoiceExecutorBridge()
        let allow: @Sendable () async -> Bool = { true }
        let corrupt = BridgeVoiceCommandExecutor(bridge: bridge, journalURL: file)
        let actual30 = await corrupt.execute(id: UUID(), action: .timerCreate(label: "计时器", seconds: 5), authorize: allow).outcome
        XCTAssertEqual(actual30, .denied)
        let actual31 = await corrupt.execute(id: UUID(), action: .volumeRead, authorize: allow).outcome
        XCTAssertEqual(actual31, .succeeded)
        let blockedURL = file.appendingPathComponent("nested/journal.json")
        let unwritable = BridgeVoiceCommandExecutor(bridge: bridge, journalURL: blockedURL)
        let outcome = await unwritable.execute(id: UUID(), action: .timerCreate(label: "计时器", seconds: 5), authorize: allow)
        XCTAssertEqual(outcome.outcome, .unknown)
        let actual32 = await bridge.timerCalls
        XCTAssertEqual(actual32, 0)
    }
}
