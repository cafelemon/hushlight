import BridgeCore
import Foundation
import XCTest
@testable import HushlightMac

@MainActor
final class ReminderAppModelTests: XCTestCase {
    func testExplicitEnableAndActionsRefreshDedicatedList() async {
        let service = ReminderModelFixture()
        let model = AppModel(bridgeService: service)

        await model.refresh()
        XCTAssertFalse(model.reminderReady)
        XCTAssertTrue(model.reminders.isEmpty)
        await model.createReminder(title: "Before enable", dueAt: Date().addingTimeInterval(3600))
        let beforeEnableActions = await service.actionCount
        XCTAssertEqual(beforeEnableActions, 0)

        await model.enableReminders()
        XCTAssertTrue(model.reminderReady)
        XCTAssertEqual(model.permissions.first { $0.kind == .reminders }?.state, .granted)

        let due = Date().addingTimeInterval(3600)
        await model.createReminder(title: "Doctor", dueAt: due)
        XCTAssertEqual(model.reminderActionResult?.outcome, .succeeded)
        guard let id = model.reminders.first?.id else { return XCTFail("Expected dedicated reminder") }
        await model.updateReminder(id: id, title: "Appointment", dueAt: nil)
        XCTAssertEqual(model.reminders.first?.title, "Appointment")
        await model.completeReminder(id: id, completed: true)
        XCTAssertEqual(model.reminders.first?.isCompleted, true)
        await model.completeReminder(id: id, completed: false)
        XCTAssertEqual(model.reminders.first?.isCompleted, false)
        XCTAssertFalse(model.isBusy)
    }

    func testPausedActionsDoNotReachService() async {
        let service = ReminderModelFixture()
        let model = AppModel(bridgeService: service)
        await model.refresh()
        await model.togglePause()
        await model.enableReminders()
        await model.createReminder(title: "Blocked", dueAt: Date().addingTimeInterval(3600))
        let enableCount = await service.enableCount
        let actionCount = await service.actionCount
        XCTAssertEqual(enableCount, 0)
        XCTAssertEqual(actionCount, 0)
    }

    func testSnapshotFailureDoesNotPresentStaleSuccess() async {
        let service = ReminderModelFixture()
        let model = AppModel(bridgeService: service)
        await model.enableReminders()
        await model.createReminder(title: "First", dueAt: Date().addingTimeInterval(3600))
        XCTAssertEqual(model.reminderActionResult?.outcome, .succeeded)
        await service.setSnapshotFailure(true)
        await model.createReminder(title: "Second", dueAt: Date().addingTimeInterval(3600))
        XCTAssertNil(model.reminderActionResult)
        XCTAssertNotNil(model.reminderError)
        XCTAssertTrue(model.lastErrorMessage?.contains("不要重复创建") == true)
    }
}

private actor ReminderModelFixture: BridgeService {
    private var enabled = false
    private var paused = false
    private var failsSnapshot = false
    private var records: [LocalReminderRecord] = []
    private(set) var enableCount = 0
    private(set) var actionCount = 0

    func snapshot() async throws -> BridgeSnapshot {
        if failsSnapshot { throw BridgeServiceError.notConfigured }
        return BridgeSnapshot(
            status: paused ? .paused : .localReady,
            permissions: [PermissionStatus(kind: .reminders, state: enabled ? .granted : .notRequested)],
            recentActions: [], reminders: enabled ? records : [], reminderReady: enabled
        )
    }

    func setPaused(_ value: Bool) async throws { paused = value }
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
    func setSnapshotFailure(_ value: Bool) { failsSnapshot = value }
    func enableReminders() async throws { enableCount += 1; enabled = true }

    func createReminder(id: String, title: String, dueAt: Date) async throws -> ReminderActionReadback {
        actionCount += 1
        records.append(LocalReminderRecord(id: id, title: title, dueAt: dueAt, isCompleted: false))
        return success()
    }

    func updateReminder(id: String, title: String?, dueAt: Date?) async throws -> ReminderActionReadback {
        actionCount += 1
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw BridgeServiceError.notConfigured }
        let previous = records[index]
        records[index] = LocalReminderRecord(id: id, title: title ?? previous.title,
                                            dueAt: dueAt ?? previous.dueAt, isCompleted: previous.isCompleted)
        return success()
    }

    func completeReminder(id: String, completed: Bool) async throws -> ReminderActionReadback {
        actionCount += 1
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw BridgeServiceError.notConfigured }
        let previous = records[index]
        records[index] = LocalReminderRecord(id: id, title: previous.title,
                                            dueAt: previous.dueAt, isCompleted: completed)
        return success()
    }

    private func success() -> ReminderActionReadback {
        ReminderActionReadback(outcome: .succeeded, stableError: nil, completedAt: Date())
    }
}
