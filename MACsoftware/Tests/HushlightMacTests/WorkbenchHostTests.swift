import XCTest
import Foundation
import Darwin
import BridgeCore
import WorkbenchKit
@testable import HushlightMac

private actor WorkbenchFakeBridge: BridgeService {
    var paused = false
    var creates = 0
    var delayNanos: UInt64 = 0
    var reminderListNotEnabled = false
    var locationSupported = false
    var statusGate: CheckedContinuation<Void, Never>?
    var holdStatus = false
    var statusStarted = false
    func holdPermissionStatus() { holdStatus = true }
    func didStartStatus() -> Bool { statusStarted }
    func releaseStatus() { statusGate?.resume(); statusGate = nil }
    func systemAuthorizationStates() async -> [String: String] {
        if holdStatus {
            statusStarted = true
            await withCheckedContinuation { statusGate = $0 }
        }
        return ["notifications": "authorized", "notes": "notDetermined", "mail": "denied", "reminders": "authorized", "calendar": "unknown", "private_other": "must_not_leak"]
    }

    func snapshot() async throws -> BridgeSnapshot {
        BridgeSnapshot(status: paused ? .paused : .localReady, permissions: [], recentActions: [])
    }
    func workbenchState() async throws -> WorkbenchServiceState {
        .init(status: paused ? "paused" : "localReady",
              supportedActions: ["system.volume.get", "timer.create", "reminder.complete"] + (locationSupported ? ["location.get"] : []),
              isSimulation: false, locationAuthorization: locationSupported ? .authorized : nil)
    }
    func workbenchReminders() async throws -> [LocalReminderRecord] {
        if reminderListNotEnabled { throw ReminderAccessError.listNotEnabled }
        return []
    }
    func setPaused(_ value: Bool) async throws { paused = value }
    func readSystemVolume() async throws -> VolumeReadback {
        .init(outcome: .succeeded, stableError: nil, value: 40, muted: false, readAt: Date())
    }
    func createTimer(id: String, fireAt: Date, label: String) async throws -> TimerActionReadback {
        creates += 1
        if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
        return .init(outcome: .succeeded, stableError: nil, completedAt: Date())
    }
    func count() -> Int { creates }
    func setDelay(_ value: UInt64) { delayNanos = value }
    func setReminderListNotEnabled(_ value: Bool) { reminderListNotEnabled = value }
    func setLocationSupported(_ value: Bool) { locationSupported = value }
}

final class WorkbenchHostTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: "/tmp/hlwb-\(UUID().uuidString)")
    }

    func testGrantWithdrawalWhilePermissionStatusAwaitsDoesNotDiscloseState() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = WorkbenchFakeBridge()
        let host = try WorkbenchHost(bridge: bridge, directory: directory)
        let client = try await host.createClient(name: "Status race")
        try await host.setGrants(clientID: client.id, grants: [.noteRead, .locationRead])
        await bridge.setLocationSupported(true)
        await bridge.holdPermissionStatus()
        let task = Task { await host.process(.init(requestID: UUID().uuidString, operation: "status", credential: client.credential)) }
        for _ in 0..<100 {
            if await bridge.didStartStatus() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await bridge.didStartStatus()
        XCTAssertTrue(started)
        try await host.setGrants(clientID: client.id, grants: [])
        await bridge.releaseStatus()
        let response = await task.value
        guard case .object(let fields) = response.result else { XCTFail("Missing status"); return }
        XCTAssertEqual(fields["system_permissions"], .object([:]))
        XCTAssertNil(fields["location_authorization"])
    }

    func testSystemPermissionsAreFilteredByCurrentGrantAndDoNotGrantAccess() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try WorkbenchHost(bridge: WorkbenchFakeBridge(), directory: directory)
        let client = try await host.createClient(name: "Status only")
        func permissions() async throws -> [String: JSONValue] {
            let response = await host.process(.init(requestID: UUID().uuidString, operation: "status", credential: client.credential))
            XCTAssertEqual(response.status, "succeeded")
            guard case .object(let fields) = response.result, case .object(let permissions) = fields["system_permissions"] else {
                XCTFail("Missing permission diagnostics"); return [:]
            }
            return permissions
        }
        let initial = try await permissions()
        XCTAssertTrue(initial.isEmpty)
        try await host.setGrants(clientID: client.id, grants: [.noteRead, .reminderRead])
        let granted = try await permissions()
        XCTAssertEqual(granted, ["notes": .string("notDetermined"), "reminders": .string("authorized")])
        try await host.setGrants(clientID: client.id, grants: [])
        let withdrawn = try await permissions()
        XCTAssertTrue(withdrawn.isEmpty)
        try await host.revoke(clientID: client.id)
        let rejected = await host.process(.init(requestID: UUID().uuidString, operation: "status", credential: client.credential))
        XCTAssertEqual(rejected.status, "rejected")
    }

    func testStatusExposesLocationAuthorizationOnlyWithGrantAndSupportedAction() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = WorkbenchFakeBridge()
        let host = try WorkbenchHost(bridge: bridge, directory: directory)
        let client = try await host.createClient(name: "Location status")
        let request = WorkbenchRequest(requestID: UUID().uuidString, operation: "status", credential: client.credential)

        func statusFields() async throws -> [String: JSONValue] {
            let response = await host.process(request)
            XCTAssertEqual(response.status, "succeeded")
            guard case .object(let result) = response.result else { throw StableErrorCode.invalidSchema }
            return result
        }

        var fields = try await statusFields()
        XCTAssertNil(fields["location_authorization"])
        await bridge.setLocationSupported(true)
        fields = try await statusFields()
        XCTAssertNil(fields["location_authorization"])
        try await host.setGrants(clientID: client.id, grants: [.locationRead])
        fields = try await statusFields()
        XCTAssertEqual(fields["location_authorization"], .string("authorized"))
        await bridge.setLocationSupported(false)
        fields = try await statusFields()
        XCTAssertNil(fields["location_authorization"])
    }

    func testSocketAuthGrantRevokePauseAndPermissions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = WorkbenchFakeBridge()
        let host = try WorkbenchHost(bridge: bridge, directory: directory)
        let client = try await host.createClient(name: "Test")
        try await host.start()
        defer { Task { await host.stop() } }
        let socketPath = directory.appendingPathComponent("workbench.sock").path
        var info = stat()
        XCTAssertEqual(stat(directory.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(stat(socketPath, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(stat(directory.appendingPathComponent(client.id + ".credential").path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)

        let wire = WorkbenchClient(socketPath: socketPath)
        func request(_ token: String, _ action: String? = nil) -> WorkbenchRequest {
            .init(requestID: UUID().uuidString, operation: action == nil ? "capabilities" : "action",
                  action: action, credential: token)
        }
        let denied = try wire.request(request("invalid", "system.volume.get"))
        XCTAssertEqual(denied.error, "unauthenticated")
        let off = try wire.request(request(client.credential, "system.volume.get"))
        XCTAssertEqual(off.error, "permission_required")
        try await host.setGrants(clientID: client.id, grants: [.volumeRead])
        let capabilities = try wire.request(request(client.credential))
        XCTAssertEqual(capabilities.status, "succeeded")
        let allowed = try wire.request(request(client.credential, "system.volume.get"))
        XCTAssertEqual(allowed.status, "succeeded")
        try await bridge.setPaused(true)
        let paused = try wire.request(request(client.credential, "system.volume.get"))
        XCTAssertEqual(paused.error, "bridge_paused")
        try await host.revoke(clientID: client.id)
        let revoked = try wire.request(request(client.credential, "system.volume.get"))
        XCTAssertEqual(revoked.error, "unauthenticated")
    }

    func testWriteDedupeConcurrentAndAcrossRestart() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = WorkbenchFakeBridge()
        await bridge.setDelay(100_000_000)
        let first = try WorkbenchHost(bridge: bridge, directory: directory)
        let client = try await first.createClient(name: "Writer")
        try await first.setGrants(clientID: client.id, grants: [.timerWrite])
        let request = WorkbenchRequest(requestID: UUID().uuidString, operation: "action", action: "timer.create",
                                       parameters: .object(["timer_id": .string("test"),
                                                            "fire_at": .string("2030-01-01T00:00:00Z"),
                                                            "label": .string("test")]), credential: client.credential)
        async let one = first.process(request)
        async let two = first.process(request)
        let (a, b) = await (one, two)
        XCTAssertEqual(Set([a.status, b.status]), Set(["succeeded", "unknown"]))
        let firstCount = await bridge.count()
        XCTAssertEqual(firstCount, 1)
        let copied = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: copied) }
        try FileManager.default.copyItem(at: directory, to: copied)
        let second = try WorkbenchHost(bridge: bridge, directory: copied)
        let retry = await second.process(request)
        XCTAssertEqual(retry.status, "succeeded")
        let secondCount = await bridge.count()
        XCTAssertEqual(secondCount, 1)
        let changed = WorkbenchRequest(requestID: request.requestID, operation: "action", action: "timer.create",
                                       parameters: .object(["timer_id": .string("other"),
                                                            "fire_at": .string("2030-01-01T00:00:00Z"),
                                                            "label": .string("other")]), credential: client.credential)
        let replay = await second.process(changed)
        XCTAssertEqual(replay.error, "replay_detected")
        try await bridge.setPaused(true)
        let replayWhilePaused = await second.process(request)
        XCTAssertEqual(replayWhilePaused.status, "succeeded")
        try await bridge.setPaused(false)
        let query = WorkbenchRequest(requestID: UUID().uuidString, operation: "result",
                                     parameters: .object(["request_id": .string(request.requestID)]),
                                     credential: client.credential)
        let queried = await second.process(query)
        XCTAssertEqual(queried.status, "succeeded")
        if case .object(let result) = queried.result { XCTAssertEqual(result["status"], .string("succeeded")) }
        let invalid = WorkbenchRequest(requestID: UUID().uuidString, operation: "action", action: "timer.create",
                                       parameters: .object(["timer_id": .string("test")]), credential: client.credential)
        let rejected = await second.process(invalid)
        XCTAssertEqual(rejected.error, "invalid_schema")
    }

    func testOnlyOneHostCanOwnDirectory() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = WorkbenchFakeBridge()
        let first = try WorkbenchHost(bridge: bridge, directory: directory)
        _ = first
        XCTAssertThrowsError(try WorkbenchHost(bridge: bridge, directory: directory))
    }

    func testRevokeReclaimsOnlyItsJournalRows() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = WorkbenchFakeBridge()
        let host = try WorkbenchHost(bridge: bridge, directory: directory, journalCapacity: 2)
        let first = try await host.createClient(name: "First")
        let active = try await host.createClient(name: "Active")
        try await host.setGrants(clientID: first.id, grants: [.timerWrite])
        try await host.setGrants(clientID: active.id, grants: [.timerWrite])
        func write(_ token: String, _ id: String = UUID().uuidString) -> WorkbenchRequest {
            .init(requestID: id, operation: "action", action: "timer.create",
                  parameters: .object(["timer_id": .string("test"),
                                       "fire_at": .string("2030-01-01T00:00:00Z"),
                                       "label": .string("test")]), credential: token)
        }
        let firstRequest = write(first.credential)
        let activeRequest = write(active.credential)
        let firstResult = await host.process(firstRequest)
        let activeResult = await host.process(activeRequest)
        XCTAssertEqual(firstResult.status, "succeeded")
        XCTAssertEqual(activeResult.status, "succeeded")
        let full = await host.process(write(active.credential))
        XCTAssertEqual(full.error, "journal_capacity")
        try await host.revoke(clientID: first.id)
        let oldToken = await host.process(write(first.credential))
        XCTAssertEqual(oldToken.error, "unauthenticated")
        let replacement = try await host.createClient(name: "Replacement")
        try await host.setGrants(clientID: replacement.id, grants: [.timerWrite])
        let afterRevoke = await host.process(write(replacement.credential))
        XCTAssertEqual(afterRevoke.status, "succeeded")
        let duplicateActive = await host.process(activeRequest)
        XCTAssertEqual(duplicateActive.status, "succeeded")
        let count = await bridge.count()
        XCTAssertEqual(count, 3)
        let history = await host.history()
        XCTAssertTrue(history.contains { $0.clientID == first.id && $0.id == firstRequest.requestID })
        XCTAssertTrue(history.contains { $0.clientID == active.id && $0.id == activeRequest.requestID })
        let copied = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: copied) }
        try FileManager.default.copyItem(at: directory, to: copied)
        let restored = try WorkbenchHost(bridge: bridge, directory: copied, journalCapacity: 2)
        let restoredHistory = await restored.history()
        XCTAssertTrue(restoredHistory.contains { $0.clientID == first.id && $0.id == firstRequest.requestID })
    }

    func testReminderListNotEnabledReturnsActionableResult() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = WorkbenchFakeBridge()
        await bridge.setReminderListNotEnabled(true)
        let host = try WorkbenchHost(bridge: bridge, directory: directory)
        let client = try await host.createClient(name: "Reader")
        try await host.setGrants(clientID: client.id, grants: [.reminderRead])
        let request = WorkbenchRequest(requestID: UUID().uuidString, operation: "action",
                                       action: "reminder.list", credential: client.credential)
        let result = await host.process(request)
        XCTAssertEqual(result.status, "rejected")
        XCTAssertEqual(result.error, "capability_disabled")
        if case .object(let details) = result.result, case .string(let message)? = details["remediation"] {
            XCTAssertTrue(message.contains("Orbit 智轨"))
            XCTAssertTrue(message.contains("专用提醒列表"))
        } else { XCTFail("Missing remediation") }
    }

    func testWriteOnlyNotesGrantDoesNotDiscloseBodyOrPersistIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try WorkbenchHost(bridge: WriteOnlyNotesBridge(), directory: directory)
        let client = try await host.createClient(name: "Writer")
        try await host.setGrants(clientID: client.id, grants: [.noteWrite])
        let response = await host.process(.init(requestID: UUID().uuidString, operation: "action", action: "note.append",
                                               parameters: .object(["note_id": .string("note"), "text": .string("new text"), "expected_revision": .string(String(repeating: "a", count: 64))]), credential: client.credential))
        XCTAssertEqual(response.status, "succeeded")
        let wire = String(data: try JSONEncoder().encode(response), encoding: .utf8)!
        let disk = try String(contentsOf: directory.appendingPathComponent("state.json"), encoding: .utf8)
        XCTAssertFalse(wire.contains("private-existing-body"))
        XCTAssertFalse(wire.contains("private-title"))
        XCTAssertFalse(disk.contains("private-existing-body"))
        XCTAssertFalse(disk.contains("new text"))
        XCTAssertFalse(disk.contains(client.credential))
        let read = await host.process(.init(requestID: UUID().uuidString, operation: "action", action: "note.read", parameters: .object(["note_id": .string("note")]), credential: client.credential))
        XCTAssertEqual(read.error, "permission_required")
    }

    func testPendingJournalBecomesUnknownAfterRestart() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = WorkbenchFakeBridge()
        await bridge.setDelay(250_000_000)
        let first = try WorkbenchHost(bridge: bridge, directory: directory)
        let client = try await first.createClient(name: "Writer")
        try await first.setGrants(clientID: client.id, grants: [.timerWrite])
        let request = WorkbenchRequest(requestID: UUID().uuidString, operation: "action", action: "timer.create",
                                       parameters: .object(["timer_id": .string("test"), "fire_at": .string("2030-01-01T00:00:00Z"),
                                                            "label": .string("test")]), credential: client.credential)
        let task = Task { await first.process(request) }
        try await Task.sleep(nanoseconds: 40_000_000)
        let copied = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: copied) }
        try FileManager.default.copyItem(at: directory, to: copied)
        let second = try WorkbenchHost(bridge: bridge, directory: copied)
        let retry = await second.process(request)
        XCTAssertEqual(retry.status, "unknown")
        XCTAssertEqual(retry.error, "result_unverifiable")
        _ = await task.value
    }
}

private actor WriteOnlyNotesBridge: BridgeService {
    func snapshot() async throws -> BridgeSnapshot { .init(status: .localReady, permissions: [], recentActions: []) }
    func workbenchState() async throws -> WorkbenchServiceState { .init(status: "localReady", supportedActions: ["note.append", "note.read"], isSimulation: true) }
    func setPaused(_ paused: Bool) async throws {}
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
    func appendNote(id: String, text: String, expectedRevision: String) async throws -> LocalNotesCommandResult {
        .init(status: "succeeded", stableError: nil, completedAt: Date(), note: .init(id: id, title: "private-title", text: "private-existing-body", revision: expectedRevision, canAppend: true), isSimulation: true)
    }
}
