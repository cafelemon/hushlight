import BridgeCore
import Foundation
import XCTest
import UserNotifications
@testable import HushlightMac

final class TimerServiceTests: XCTestCase {
    func testRejectedSimulationServiceDoesNotRestoreOrPromptProductionBackend() async throws {
        let fixture = try TimerServiceFixture()
        defer { fixture.cleanup() }
        let simulated = fixture.service(access: FakeNotificationAccess(status: .authorized))
        _ = try await simulated.createTimer(id: "persisted", fireAt: Date().addingTimeInterval(900), label: "Test")
        let production = FakeNotificationAccess(status: .authorized, isSimulation: false)
        let rejected = fixture.service(access: production)
        do {
            _ = try await rejected.snapshot()
            XCTFail("Expected simulation/production rejection")
        } catch {}
        do {
            try await rejected.requestNotificationPermission()
            XCTFail("Rejected runtime must not prompt")
        } catch {}
        let schedules = await production.scheduleCount
        let prompts = await production.promptCount
        XCTAssertEqual(schedules, 0)
        XCTAssertEqual(prompts, 0)
    }

    func testNotificationTriggerKeepsAbsoluteTimeAcrossTimeZones() throws {
        let date = Date(timeIntervalSince1970: ceil(Date().addingTimeInterval(600).timeIntervalSince1970))
        let trigger = UserNotificationScheduler.trigger(fireAt: date)
        XCTAssertFalse(trigger.repeats)
        XCTAssertEqual(try XCTUnwrap(trigger.nextTriggerDate()).timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.1)
        for zone in ["Asia/Shanghai", "America/New_York"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let interpreted = try XCTUnwrap(calendar.date(from: trigger.dateComponents))
            XCTAssertEqual(interpreted.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.1)
        }
    }

    func testExplicitGrantThenCreateUpdateCancelAndRestart() async throws {
        let fixture = try TimerServiceFixture()
        defer { fixture.cleanup() }
        let access = FakeNotificationAccess(status: .notDetermined)
        let service = fixture.service(access: access)
        let initial = try await service.snapshot()
        XCTAssertEqual(initial.permissions.first(where: { $0.kind == .notifications })?.state, .notRequested)
        let promptCount = await access.promptCount
        XCTAssertEqual(promptCount, 0)

        try await service.requestNotificationPermission()
        let granted = try await service.snapshot()
        XCTAssertEqual(granted.permissions.first(where: { $0.kind == .notifications })?.state, .granted)
        XCTAssertTrue(granted.permissions.filter { $0.kind != .notifications }.allSatisfy { $0.state == .notRequested || $0.state == .notChecked })
        let afterGrantPrompts = await access.promptCount
        XCTAssertEqual(afterGrantPrompts, 1)

        let fireAt = Date().addingTimeInterval(600)
        let created = try await service.createTimer(id: "tea", fireAt: fireAt, label: "Tea")
        XCTAssertEqual(created.outcome, .succeeded)
        XCTAssertNil(created.stableError)
        let afterCreate = try await service.snapshot()
        XCTAssertEqual(afterCreate.timers.map(\.id), ["tea"])

        let updated = try await service.updateTimer(id: "tea", fireAt: fireAt.addingTimeInterval(60), label: "Tea ready")
        XCTAssertEqual(updated.outcome, .succeeded)
        let afterUpdate = try await service.snapshot()
        XCTAssertEqual(afterUpdate.timers.first?.label, "Tea ready")
        let restarted = fixture.service(access: access)
        let restored = try await restarted.snapshot()
        XCTAssertEqual(restored.timers.first?.label, "Tea ready")
        XCTAssertNil(restored.timerError)

        let cancelled = try await restarted.cancelTimer(id: "tea")
        XCTAssertEqual(cancelled.outcome, .succeeded)
        let afterCancel = try await restarted.snapshot()
        XCTAssertTrue(afterCancel.timers.isEmpty)
        let pending = await access.pendingIDs()
        XCTAssertTrue(pending.isEmpty)
    }

    func testDeniedGrantAndCorruptStorageDoNotBlockVolumeRuntime() async throws {
        let fixture = try TimerServiceFixture()
        defer { fixture.cleanup() }
        let access = FakeNotificationAccess(status: .denied)
        let service = fixture.service(access: access)
        let denied = try await service.snapshot()
        XCTAssertEqual(denied.permissions.first(where: { $0.kind == .notifications })?.state, .denied)
        XCTAssertNotNil(denied.timerError)
        let rejected = try await service.createTimer(id: "tea", fireAt: Date().addingTimeInterval(600), label: "Tea")
        XCTAssertEqual(rejected.outcome, .rejected)
        XCTAssertEqual(rejected.stableError, "permission_required")
        let volume = try await service.readSystemVolume()
        XCTAssertEqual(volume.outcome, .succeeded)
        XCTAssertTrue(volume.isSimulation)

        try FileManager.default.createDirectory(at: fixture.storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let badData = Data("{broken".utf8)
        try badData.write(to: fixture.storageURL)
        let brokenService = fixture.service(access: access)
        let broken = try await brokenService.snapshot()
        XCTAssertNotNil(broken.timerError)
        XCTAssertTrue(broken.timers.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.storageURL), badData)
        let stillReadable = try await brokenService.readSystemVolume()
        XCTAssertEqual(stillReadable.outcome, .succeeded)
    }

    func testRevokedAuthorizationStillShowsSavedTimersWithoutPrompting() async throws {
        let fixture = try TimerServiceFixture()
        defer { fixture.cleanup() }
        let access = FakeNotificationAccess(status: .authorized)
        let first = fixture.service(access: access)
        let created = try await first.createTimer(
            id: "saved", fireAt: Date().addingTimeInterval(900), label: "Saved timer"
        )
        XCTAssertEqual(created.outcome, .succeeded)
        await access.setAuthorization(.denied)

        let restarted = fixture.service(access: access)
        let snapshot = try await restarted.snapshot()
        XCTAssertEqual(snapshot.permissions.first(where: { $0.kind == .notifications })?.state, .denied)
        XCTAssertEqual(snapshot.timers.map(\.id), ["saved"])
        XCTAssertNotNil(snapshot.timerError)
        let prompts = await access.promptCount
        XCTAssertEqual(prompts, 0)
        do {
            try await restarted.requestNotificationPermission()
            XCTFail("Denied authorization should be reported")
        } catch UserNotificationSchedulerError.permissionRequired {
            let requested = await access.promptCount
            XCTAssertEqual(requested, 1)
        }
    }

    func testCancelWhilePermissionRevokedStaysCancelledAfterRestartAndGrant() async throws {
        let fixture = try TimerServiceFixture()
        defer { fixture.cleanup() }
        let access = FakeNotificationAccess(status: .authorized)
        let service = fixture.service(access: access)
        let created = try await service.createTimer(id: "cancel-after-revoke", fireAt: Date().addingTimeInterval(900), label: "Test")
        XCTAssertEqual(created.outcome, .succeeded)
        await access.setAuthorization(.denied)
        let cancelled = try await service.cancelTimer(id: "cancel-after-revoke")
        XCTAssertEqual(cancelled.outcome, .succeeded)
        let restarted = fixture.service(access: access)
        let deniedSnapshot = try await restarted.snapshot()
        XCTAssertTrue(deniedSnapshot.timers.isEmpty)
        await access.setAuthorization(.authorized)
        try await restarted.requestNotificationPermission()
        let grantedSnapshot = try await restarted.snapshot()
        XCTAssertTrue(grantedSnapshot.timers.isEmpty)
        let pending = await access.pendingIDs()
        XCTAssertTrue(pending.isEmpty)
    }

    func testFailedCancelWhileRevokedPersistsIntentUntilRegrant() async throws {
        let fixture = try TimerServiceFixture()
        defer { fixture.cleanup() }
        let access = FakeNotificationAccess(status: .authorized)
        let service = fixture.service(access: access)
        _ = try await service.createTimer(id: "cancel-pending", fireAt: Date().addingTimeInterval(900), label: "Test")
        await access.setAuthorization(.denied)
        await access.setCancelFailure(true)
        let result = try await service.cancelTimer(id: "cancel-pending")
        XCTAssertEqual(result.outcome, .unknown)
        let restarted = fixture.service(access: access)
        let beforeGrant = try await restarted.snapshot()
        XCTAssertTrue(beforeGrant.timers.isEmpty)
        await access.setCancelFailure(false)
        await access.setAuthorization(.authorized)
        try await restarted.requestNotificationPermission()
        let restored = try await restarted.snapshot()
        XCTAssertTrue(restored.timers.isEmpty)
        let pending = await access.pendingIDs()
        XCTAssertTrue(pending.isEmpty)
    }

    func testSystemSchedulerInSwiftTestRequiresDevelopmentAppBundle() async throws {
        guard Bundle.main.bundleIdentifier != "com.hushlight.bridge.mac" else {
            throw XCTSkip("This assertion applies only to the SwiftPM test executable")
        }
        let scheduler = UserNotificationScheduler()
        let status = await scheduler.authorizationStatus()
        XCTAssertEqual(status, .denied)
        do {
            _ = try await scheduler.requestAuthorization()
            XCTFail("Expected an App bundle requirement")
        } catch UserNotificationSchedulerError.requiresAppBundle {
            // This path never obtains UNUserNotificationCenter or prompts the system.
        }
    }
}

private struct TimerServiceFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hushlight-timer-service-\(UUID().uuidString)")
    var storageURL: URL { root.appendingPathComponent("Bridge/timers.json") }

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func service(access: FakeNotificationAccess) -> LocalBridgeService {
        LocalBridgeService(
            preferences: MemoryPauseStore(),
            notificationAccess: access,
            timerStorageURL: storageURL,
            runtimeFactory: { paused, coordinator in
                try await BridgeLocalRuntime(simulate: true, paused: paused, timerCoordinator: coordinator)
            }
        )
    }
}

private final class MemoryPauseStore: PausePreferenceStore, @unchecked Sendable {
    func loadPaused() -> Bool { false }
    func savePaused(_ paused: Bool) {}
}

private actor FakeNotificationAccess: NotificationAccess {
    nonisolated let isSimulation: Bool
    private var status: TimerNotificationAuthorization
    private var pending: [String: LocalTimerRecord] = [:]
    private(set) var promptCount = 0
    private(set) var scheduleCount = 0
    private var cancelFails = false

    init(status: TimerNotificationAuthorization, isSimulation: Bool = true) {
        self.status = status
        self.isSimulation = isSimulation
    }

    func authorizationStatus() async -> TimerNotificationAuthorization { status }
    func setAuthorization(_ value: TimerNotificationAuthorization) { status = value }
    func setCancelFailure(_ value: Bool) { cancelFails = value }
    func requestAuthorization() async throws -> Bool {
        promptCount += 1
        if status == .notDetermined { status = .authorized }
        return status == .authorized
    }
    func schedule(_ timer: LocalTimerRecord) async throws {
        scheduleCount += 1
        pending[timer.id] = timer
    }
    func cancel(timerID: String) async throws {
        if cancelFails { throw UserNotificationSchedulerError.readbackFailed }
        pending.removeValue(forKey: timerID)
    }
    func pendingIDs() -> [String] { pending.keys.sorted() }
}
