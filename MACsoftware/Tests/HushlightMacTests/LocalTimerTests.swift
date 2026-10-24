import Foundation
import XCTest
@testable import BridgeCore

final class LocalTimerTests: XCTestCase {
    func testCreateUpdateCancelAndRestartRestore() async throws {
        let fixture = try Fixture()
        let scheduler = TimerSchedulerFake()
        let runtime = try await fixture.runtime(scheduler)
        let time = Date().addingTimeInterval(600)
        let created = await runtime.createTimer(id: "one", fireAt: time, label: "Private label")
        XCTAssertEqual(created.status, "succeeded")
        let observed1 = (await runtime.snapshot()).supportedActions.suffix(3)
        XCTAssertEqual(observed1, ["timer.cancel", "timer.create", "timer.update"])
        let observed2 = try await runtime.timerSnapshot().map(\.id)
        XCTAssertEqual(observed2, ["one"])
        let moved = await runtime.updateTimer(id: "one", fireAt: time.addingTimeInterval(60), label: "Changed")
        XCTAssertEqual(moved.status, "succeeded")
        let observed3 = await scheduler.scheduledCount("one")
        XCTAssertEqual(observed3, 2)
        let restarted = try await fixture.runtime(scheduler)
        let observed4 = try await restarted.timerSnapshot().first?.label
        XCTAssertEqual(observed4, "Changed")
        let observed5 = await scheduler.scheduledCount("one")
        XCTAssertEqual(observed5, 3)
        let observed6 = (await restarted.cancelTimer(id: "one")).status
        XCTAssertEqual(observed6, "succeeded")
        let observed7 = (await restarted.cancelTimer(id: "one")).status
        XCTAssertEqual(observed7, "succeeded")
        let observed8 = try await restarted.timerSnapshot().isEmpty
        XCTAssertTrue(observed8)
        let observed9 = await scheduler.cancelledCount("one")
        XCTAssertEqual(observed9, 1)
        let text = try String(contentsOf: fixture.url, encoding: .utf8)
        XCTAssertFalse(text.contains("Private label"))
        XCTAssertFalse(text.contains("Changed"))
    }

    func testPastDuplicateMissingUpdateCapacityAndPermission() async throws {
        let fixture = try Fixture()
        let scheduler = TimerSchedulerFake()
        let runtime = try await fixture.runtime(scheduler)
        let observed10 = (await runtime.createTimer(id: "past", fireAt: Date().addingTimeInterval(-1), label: "Past")).stableError
        XCTAssertEqual(observed10, "invalid_schema")
        let observed11 = (await runtime.updateTimer(id: "missing", label: "Other")).status
        XCTAssertEqual(observed11, "rejected")
        let future = Date().addingTimeInterval(3600)
        let observed12 = (await runtime.createTimer(id: "same", fireAt: future, label: "One")).status
        XCTAssertEqual(observed12, "succeeded")
        let observed13 = (await runtime.createTimer(id: "same", fireAt: future, label: "Two")).status
        XCTAssertEqual(observed13, "rejected")
        for index in 1..<128 {
            let observed14 = (await runtime.createTimer(id: "id-\(index)", fireAt: future, label: "T")).status
            XCTAssertEqual(observed14, "succeeded")
        }
        let observed15 = (await runtime.createTimer(id: "overflow", fireAt: future, label: "T")).status
        XCTAssertEqual(observed15, "rejected")
        await scheduler.setAuthorization(.denied)
        let observed16 = (await runtime.createTimer(id: "denied", fireAt: future, label: "T")).stableError
        XCTAssertEqual(observed16, "permission_required")
        let missingCancel = await runtime.cancelTimer(id: "never-created")
        XCTAssertEqual(missingCancel.status, "succeeded")
    }

    func testCorruptFileIsPreservedAndSaveFailureIsFailed() async throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(at: fixture.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bad = Data("{not json".utf8)
        try bad.write(to: fixture.url)
        XCTAssertThrowsError(try LocalTimerCoordinator(storageURL: fixture.url, scheduler: TimerSchedulerFake()))
        XCTAssertEqual(try Data(contentsOf: fixture.url), bad)

        let duplicate = try Fixture()
        try FileManager.default.createDirectory(at: duplicate.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let date = Date().addingTimeInterval(600).timeIntervalSinceReferenceDate
        let duplicateJSON = """
        {"version":1,"timers":[{"id":"same","fireAt":\(date),"label":"A"},
        {"id":"same","fireAt":\(date),"label":"B"}],"pending":[]}
        """
        try Data(duplicateJSON.utf8).write(to: duplicate.url)
        XCTAssertThrowsError(try LocalTimerCoordinator(storageURL: duplicate.url, scheduler: TimerSchedulerFake()))

        let blocked = try Fixture()
        try FileManager.default.createDirectory(at: blocked.root, withIntermediateDirectories: true)
        try Data("block".utf8).write(to: blocked.url.deletingLastPathComponent())
        let runtime = try await blocked.runtime(TimerSchedulerFake())
        let result = await runtime.createTimer(id: "a", fireAt: Date().addingTimeInterval(600), label: "A")
        XCTAssertEqual(result.status, "failed")
        XCTAssertEqual(result.stableError, "internal_error")
    }

    func testSchedulerFailureRemainsUnknownAndRestoresDesiredState() async throws {
        let fixture = try Fixture()
        let scheduler = TimerSchedulerFake()
        let runtime = try await fixture.runtime(scheduler)
        await scheduler.failNextSchedule()
        let result = await runtime.createTimer(id: "a", fireAt: Date().addingTimeInterval(600), label: "A")
        XCTAssertEqual(result.status, "unknown")
        XCTAssertEqual(result.stableError, "result_unverifiable")
        let restarted = try await fixture.runtime(scheduler)
        let observed17 = try await restarted.timerSnapshot().map(\.id)
        XCTAssertEqual(observed17, ["a"])
        let observed18 = await scheduler.scheduledCount("a")
        XCTAssertEqual(observed18, 1)
        await scheduler.failNextCancel()
        let observed19 = (await restarted.cancelTimer(id: "a")).status
        XCTAssertEqual(observed19, "unknown")
        let again = try await fixture.runtime(scheduler)
        let observed20 = try await again.timerSnapshot().isEmpty
        XCTAssertTrue(observed20)
        let observed21 = await scheduler.cancelledCount("a")
        XCTAssertEqual(observed21, 1)
    }

    func testConcurrentCreatesDoNotLoseStateAndExpiredIsNotRefired() async throws {
        let fixture = try Fixture()
        let scheduler = TimerSchedulerFake()
        let runtime = try await fixture.runtime(scheduler)
        let future = Date().addingTimeInterval(600)
        await withTaskGroup(of: LocalTimerCommandResult.self) { group in
            for index in 0..<30 {
                group.addTask { await runtime.createTimer(id: "concurrent-\(index)", fireAt: future, label: "T") }
            }
            for await result in group { XCTAssertEqual(result.status, "succeeded") }
        }
        let observed23 = try await runtime.timerSnapshot().count
        XCTAssertEqual(observed23, 30)
        let restarted = try await fixture.runtime(scheduler, now: future.addingTimeInterval(1))
        let observed24 = try await restarted.timerSnapshot().isEmpty
        XCTAssertTrue(observed24)
        let observed25 = await scheduler.totalSchedules()
        XCTAssertEqual(observed25, 30)
    }

    func testFailedScheduleIsNotReplayedAfterExpiry() async throws {
        let fixture = try Fixture()
        let scheduler = TimerSchedulerFake()
        let runtime = try await fixture.runtime(scheduler)
        let future = Date().addingTimeInterval(600)
        await scheduler.failNextSchedule()
        let result = await runtime.createTimer(id: "expired-pending", fireAt: future, label: "T")
        XCTAssertEqual(result.status, "unknown")
        let restarted = try await fixture.runtime(scheduler, now: future.addingTimeInterval(1))
        let timers = try await restarted.timerSnapshot()
        XCTAssertTrue(timers.isEmpty)
        let attempts = await scheduler.totalSchedules()
        XCTAssertEqual(attempts, 0)
    }

    func testUnauthorizedListingPreservesDesiredTimersAndPendingCancel() async throws {
        let fixture = try Fixture()
        let scheduler = TimerSchedulerFake()
        await scheduler.setAuthorization(.notDetermined)
        let first = try await fixture.runtime(scheduler)
        let future = Date().addingTimeInterval(600)
        let observed102 = (await first.createTimer(id: "before-grant", fireAt: future, label: "T")).stableError
        XCTAssertEqual(observed102,
                       "permission_required")
        let observed103 = try await first.timerSnapshot().isEmpty
        XCTAssertTrue(observed103)
        await scheduler.setAuthorization(.authorized)
        let observed104 = (await first.createTimer(id: "saved", fireAt: future, label: "T")).status
        XCTAssertEqual(observed104, "succeeded")
        let visible = await first.createTimer(id: "visible", fireAt: future, label: "T")
        XCTAssertEqual(visible.status, "succeeded")
        await scheduler.failNextCancel()
        let observed105 = (await first.cancelTimer(id: "saved")).status
        XCTAssertEqual(observed105, "unknown")
        await scheduler.setAuthorization(.denied)
        let restarted = try await fixture.runtime(scheduler)
        let listed = try await restarted.timerSnapshot()
        XCTAssertEqual(listed.map(\.id), ["visible"])
        await scheduler.setAuthorization(.authorized)
        try await restarted.timerSnapshot()
        let observed107 = await scheduler.cancelledCount("saved")
        XCTAssertEqual(observed107, 1)
    }

    func testExpiryPruningReopensCapacityWithoutRestart() async throws {
        let fixture = try Fixture()
        let scheduler = TimerSchedulerFake()
        let clock = TimerClock(Date())
        let coordinator = try LocalTimerCoordinator(storageURL: fixture.url, scheduler: scheduler, now: { clock.current() })
        let runtime = try await BridgeLocalRuntime(simulate: true, timerCoordinator: coordinator)
        let firstFire = clock.current().addingTimeInterval(10)
        for index in 0..<128 {
            let result = await runtime.createTimer(id: "old-\(index)", fireAt: firstFire, label: "T")
            XCTAssertEqual(result.status, "succeeded")
        }
        clock.set(firstFire.addingTimeInterval(2))
        let next = await runtime.createTimer(id: "new", fireAt: clock.current().addingTimeInterval(60), label: "T")
        XCTAssertEqual(next.status, "succeeded")
        let observed108 = try await runtime.timerSnapshot().map(\.id)
        XCTAssertEqual(observed108, ["new"])
    }

    func testFractionalSecondsRoundUpAndLegacyWindowDoesNotReplay() async throws {
        let fixture = try Fixture()
        let scheduler = TimerSchedulerFake()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TimerClock(base)
        let coordinator = try LocalTimerCoordinator(storageURL: fixture.url, scheduler: scheduler, now: { clock.current() })
        let runtime = try await BridgeLocalRuntime(simulate: true, timerCoordinator: coordinator)
        let result = await runtime.createTimer(id: "new", fireAt: base.addingTimeInterval(10.25), label: "T")
        XCTAssertEqual(result.status, "succeeded")
        let observed109 = try await runtime.timerSnapshot().first?.fireAt
        XCTAssertEqual(observed109, base.addingTimeInterval(11))

        let legacy = try Fixture()
        try FileManager.default.createDirectory(at: legacy.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fireAt = base.addingTimeInterval(20.75)
        let raw = """
        {"version":1,"timers":[{"id":"legacy","fireAt":\(fireAt.timeIntervalSinceReferenceDate),"label":"T"}],"pending":[]}
        """
        try Data(raw.utf8).write(to: legacy.url)
        let legacyClock = TimerClock(base.addingTimeInterval(20.25))
        let legacyScheduler = TimerSchedulerFake()
        let restored = try LocalTimerCoordinator(storageURL: legacy.url, scheduler: legacyScheduler, now: { legacyClock.current() })
        try await restored.restore()
        let observed110 = try await restored.timers().isEmpty
        XCTAssertTrue(observed110)
        let observed111 = await legacyScheduler.totalSchedules()
        XCTAssertEqual(observed111, 0)

        try Data(raw.utf8).write(to: legacy.url)
        let earlyClock = TimerClock(base)
        let early = try LocalTimerCoordinator(storageURL: legacy.url, scheduler: legacyScheduler, now: { earlyClock.current() })
        try await early.restore()
        let rounded = try await early.timers().first?.fireAt
        XCTAssertEqual(rounded, base.addingTimeInterval(21))
        let scheduled = await legacyScheduler.totalSchedules()
        XCTAssertEqual(scheduled, 1)
    }
}

private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var url: URL { root.appendingPathComponent("Bridge/timers.json") }
    init() throws {}
    func runtime(_ scheduler: TimerSchedulerFake, now: Date? = nil) async throws -> BridgeLocalRuntime {
        let coordinator = try LocalTimerCoordinator(storageURL: url, scheduler: scheduler, now: { now ?? Date() })
        return try await BridgeLocalRuntime(simulate: true, timerCoordinator: coordinator)
    }
}

private actor TimerSchedulerFake: TimerNotificationScheduling {
    nonisolated let isSimulation = true
    private var authorization: TimerNotificationAuthorization = .authorized
    private var schedules: [String: Int] = [:]
    private var cancels: [String: Int] = [:]
    private var failSchedule = false
    private var failCancel = false
    func authorizationStatus() async -> TimerNotificationAuthorization { authorization }
    func setAuthorization(_ value: TimerNotificationAuthorization) { authorization = value }
    func failNextSchedule() { failSchedule = true }
    func failNextCancel() { failCancel = true }
    func schedule(_ timer: LocalTimerRecord) async throws {
        if failSchedule { failSchedule = false; throw FakeError.failed }
        schedules[timer.id, default: 0] += 1
    }
    func cancel(timerID: String) async throws {
        if failCancel { failCancel = false; throw FakeError.failed }
        cancels[timerID, default: 0] += 1
    }
    func scheduledCount(_ id: String) -> Int { schedules[id, default: 0] }
    func cancelledCount(_ id: String) -> Int { cancels[id, default: 0] }
    func totalSchedules() -> Int { schedules.values.reduce(0, +) }
}

private enum FakeError: Error { case failed }

private final class TimerClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func current() -> Date { lock.withLock { value } }
    func set(_ date: Date) { lock.withLock { value = date } }
}
