import BridgeCore
import Foundation
import XCTest
@testable import HushlightMac

final class ReminderServiceTests: XCTestCase {
    func testExplicitEnableCreateUpdateCompleteAndPause() async throws {
        let backend = ServiceReminderFake()
        let service = LocalBridgeService(preferences: ReminderPauseStore(), reminderBackend: backend)
        let initial = try await service.snapshot()
        XCTAssertFalse(initial.reminderReady)
        let initialPrompts = await backend.prompts
        XCTAssertEqual(initialPrompts, 0)
        try await service.enableReminders()
        let enabled = try await service.snapshot()
        XCTAssertTrue(enabled.reminderReady)
        XCTAssertEqual(enabled.permissions.first { $0.kind == .reminders }?.state, .granted)
        let due = Date().addingTimeInterval(3600)
        let created = try await service.createReminder(id: "service-test", title: "Test", dueAt: due)
        XCTAssertEqual(created.outcome, .succeeded)
        let updated = try await service.updateReminder(id: "service-test", title: "Changed", dueAt: nil)
        XCTAssertEqual(updated.outcome, .succeeded)
        let completed = try await service.completeReminder(id: "service-test", completed: true)
        XCTAssertEqual(completed.outcome, .succeeded)
        let after = try await service.snapshot()
        XCTAssertEqual(after.reminders.first?.title, "Changed")
        XCTAssertEqual(after.reminders.first?.isCompleted, true)
        XCTAssertFalse(String(describing: after.recentActions).contains("Changed"))
        try await service.setPaused(true)
        let paused = try await service.completeReminder(id: "service-test", completed: false)
        XCTAssertEqual(paused.stableError, "bridge_paused")
        do { try await service.enableReminders(); XCTFail("Paused setup must reject") } catch {}
        let prompts = await backend.prompts
        XCTAssertEqual(prompts, 1)
        try await service.setPaused(false)
        let resumed = try await service.completeReminder(id: "service-test", completed: false)
        XCTAssertEqual(resumed.outcome, .succeeded)
    }

    func testDeniedAndUnbundledAccessNeverCreatesList() async throws {
        let backend = ServiceReminderFake(grant: false)
        let service = LocalBridgeService(preferences: ReminderPauseStore(), reminderBackend: backend)
        do { try await service.enableReminders(); XCTFail("Denied access must reject") } catch {}
        let state = try await service.snapshot()
        XCTAssertFalse(state.reminderReady)
        XCTAssertNotNil(state.reminderError)
        let enables = await backend.enables
        XCTAssertEqual(enables, 0)
        let native = EventKitReminderBackend()
        let savedScope = await native.scopeIdentifier()
        XCTAssertNil(savedScope)
        do { _ = try await native.requestAuthorization(); XCTFail("Unbundled tests must never prompt") }
        catch ReminderAccessError.requiresApp {}
    }

    func testRejectedSimulationDoesNotPromptOrReadReminderBackend() async throws {
        let backend = ServiceReminderFake()
        let service = LocalBridgeService(preferences: ReminderPauseStore(), reminderBackend: backend,
            runtimeFactory: { paused, _, reminder in
                try await BridgeLocalRuntime(simulate: true, paused: paused, reminderCoordinator: reminder)
            })
        do { try await service.enableReminders(); XCTFail("Must reject real backend in simulation") } catch {}
        let prompts = await backend.prompts
        let reads = await backend.reads
        XCTAssertEqual(prompts, 0)
        XCTAssertEqual(reads, 0)
    }
}

private final class ReminderPauseStore: PausePreferenceStore, @unchecked Sendable {
    func loadPaused() -> Bool { false }
    func savePaused(_ paused: Bool) {}
}

private actor ServiceReminderFake: ReminderBackend {
    var prompts = 0
    var enables = 0
    var reads = 0
    private let grant: Bool
    private var authorized = false
    private var denied = false
    private var items: [String: LocalReminderRecord] = [:]
    init(grant: Bool = true) { self.grant = grant }
    func authorizationStatus() async -> ReminderAuthorization {
        reads += 1
        return authorized ? .authorized : denied ? .denied : .notDetermined
    }
    func requestAuthorization() async throws -> Bool {
        prompts += 1; authorized = grant; denied = !grant; return grant
    }
    func enableDedicatedList() async throws { enables += 1 }
    func list() async throws -> [LocalReminderRecord] {
        guard enables > 0 else { throw StableErrorCode.capabilityDisabled }
        return Array(items.values)
    }
    func create(id: String, title: String, dueAt: Date) async throws -> LocalReminderRecord {
        let value = LocalReminderRecord(id: id, title: title, dueAt: dueAt, isCompleted: false)
        items[id] = value; return value
    }
    func update(id: String, title: String?, dueAt: Date?) async throws -> LocalReminderRecord {
        let old = items[id]!
        let value = LocalReminderRecord(id: id, title: title ?? old.title, dueAt: dueAt ?? old.dueAt, isCompleted: old.isCompleted)
        items[id] = value; return value
    }
    func setCompleted(id: String, completed: Bool) async throws -> LocalReminderRecord {
        let old = items[id]!
        let value = LocalReminderRecord(id: id, title: old.title, dueAt: old.dueAt, isCompleted: completed)
        items[id] = value; return value
    }
    func cancel(id: String) async throws { items[id] = nil }
}
