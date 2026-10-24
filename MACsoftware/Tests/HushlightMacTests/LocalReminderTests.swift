import Foundation
import XCTest
@testable import BridgeCore

final class LocalReminderTests: XCTestCase {
    func testLifecycleUsesOnlyDedicatedListAndReadback() async throws {
        let backend = ReminderBackendFake()
        await backend.enable()
        let runtime = try await BridgeLocalRuntime(reminderCoordinator: LocalReminderCoordinator(backend: backend))
        let due = Date().addingTimeInterval(3_600)
        let created = await runtime.createReminder(id: "r1", title: "Private title", dueAt: due)
        XCTAssertEqual(created.status, "succeeded")
        let ids = try await runtime.reminderSnapshot().map(\.id)
        XCTAssertEqual(ids, ["r1"])
        let updated = await runtime.updateReminder(id: "r1", title: "Changed")
        XCTAssertEqual(updated.status, "succeeded")
        let completed = await runtime.completeReminder(id: "r1", completed: true)
        XCTAssertEqual(completed.status, "succeeded")
        let completedState = try await runtime.reminderSnapshot().first?.isCompleted
        XCTAssertEqual(completedState, true)
        let reopened = await runtime.completeReminder(id: "r1", completed: false)
        XCTAssertEqual(reopened.status, "succeeded")
        let cancelledAgain = await runtime.cancelReminder(id: "r1")
        XCTAssertEqual(cancelledAgain.status, "succeeded")
        let cancelled = await runtime.cancelReminder(id: "r1")
        XCTAssertEqual(cancelled.status, "succeeded")
        let empty = try await runtime.reminderSnapshot().isEmpty
        XCTAssertTrue(empty)
        let history = await runtime.snapshot().recentActions
        XCTAssertFalse(String(describing: history).contains("Private title"))
        XCTAssertFalse(String(describing: history).contains("Changed"))
    }

    func testNoImplicitAuthorizationOrListCreation() async throws {
        let backend = ReminderBackendFake()
        let runtime = try await BridgeLocalRuntime(reminderCoordinator: LocalReminderCoordinator(backend: backend))
        let result = await runtime.createReminder(id: "r1", title: "Private", dueAt: Date().addingTimeInterval(600))
        XCTAssertEqual(result.stableError, "permission_required")
        let requestCountAfter = await backend.authorizationRequests()
        XCTAssertEqual(requestCountAfter, 0)
        await backend.authorize()
        let unavailable = await runtime.createReminder(id: "r1", title: "Private", dueAt: Date().addingTimeInterval(600))
        XCTAssertEqual(unavailable.stableError, "capability_disabled")
        let requestCount = await backend.authorizationRequests()
        XCTAssertEqual(requestCount, 0)
    }

    func testSimulationRejectsRealBackendBeforeAccess() async throws {
        let backend = ReminderBackendFake()
        do {
            _ = try await BridgeLocalRuntime(simulate: true, reminderCoordinator: LocalReminderCoordinator(backend: backend))
            XCTFail("Expected conflict")
        } catch BridgeLocalCLIConfigurationError.conflictingModes {
            let accessCount = await backend.accessCount()
            XCTAssertEqual(accessCount, 0)
        }
    }

    func testPauseAndReadbackFailure() async throws {
        let backend = ReminderBackendFake()
        await backend.enable()
        let runtime = try await BridgeLocalRuntime(paused: true, reminderCoordinator: LocalReminderCoordinator(backend: backend))
        let blocked = await runtime.createReminder(id: "r1", title: "T", dueAt: Date().addingTimeInterval(600))
        XCTAssertEqual(blocked.stableError, "bridge_paused")
        let accessCount = await backend.accessCount()
        XCTAssertEqual(accessCount, 0)
        await runtime.setPaused(false)
        await backend.failNextReadback()
        let unknown = await runtime.createReminder(id: "r1", title: "T", dueAt: Date().addingTimeInterval(600))
        XCTAssertEqual(unknown.status, "unknown")
        XCTAssertEqual(unknown.stableError, "result_unverifiable")
    }
}

private actor ReminderBackendFake: ReminderBackend {
    private var authorized = false
    private var enabled = false
    private var items: [String: LocalReminderRecord] = [:]
    private var reads = 0
    private var requests = 0
    private var failReadback = false
    func authorizationStatus() async -> ReminderAuthorization { reads += 1; return authorized ? .authorized : .notDetermined }
    func requestAuthorization() async throws -> Bool { requests += 1; return false }
    func enableDedicatedList() async throws { enabled = true }
    func enable() { authorized = true; enabled = true }
    func authorize() { authorized = true }
    func authorizationRequests() -> Int { requests }
    func accessCount() -> Int { reads }
    func failNextReadback() { failReadback = true }
    func list() async throws -> [LocalReminderRecord] {
        guard enabled else { throw StableErrorCode.capabilityDisabled }
        if failReadback && !items.isEmpty { failReadback = false; throw StableErrorCode.resultUnverifiable }
        return Array(items.values)
    }
    func create(id: String, title: String, dueAt: Date) async throws -> LocalReminderRecord {
        let record = LocalReminderRecord(id: id, title: title, dueAt: dueAt, isCompleted: false)
        items[id] = record
        return record
    }
    func update(id: String, title: String?, dueAt: Date?) async throws -> LocalReminderRecord {
        guard let old = items[id] else { throw StableErrorCode.invalidSchema }
        let record = LocalReminderRecord(id: id, title: title ?? old.title, dueAt: dueAt ?? old.dueAt, isCompleted: old.isCompleted)
        items[id] = record
        return record
    }
    func setCompleted(id: String, completed: Bool) async throws -> LocalReminderRecord {
        guard let old = items[id] else { throw StableErrorCode.invalidSchema }
        let record = LocalReminderRecord(id: id, title: old.title, dueAt: old.dueAt, isCompleted: completed)
        items[id] = record
        return record
    }
    func cancel(id: String) async throws { items[id] = nil }
}
