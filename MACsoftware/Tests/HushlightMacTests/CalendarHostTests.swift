import Foundation
import XCTest
import BridgeCore
import WorkbenchKit
@testable import HushlightMac

private actor CalendarHostFakeBridge: BridgeService {
    var scope: String? = nil
    var paused = false
    var creates = 0
    var events: [CalendarEventRecord] = []

    func setScope(_ value: String?) { scope = value }
    func setPaused(_ value: Bool) async throws { paused = value }
    func createCount() -> Int { creates }
    func calendarScope() async -> String? { scope }
    func workbenchState() async throws -> WorkbenchServiceState {
        .init(status: paused ? "paused" : "localReady",
              supportedActions: scope == nil ? [] : ["calendar.list", "calendar.create", "calendar.update", "calendar.cancel"],
              isSimulation: false, calendarScopeID: scope)
    }
    func snapshot() async throws -> BridgeSnapshot {
        .init(status: paused ? .paused : .localReady, permissions: [], recentActions: [])
    }
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
    func listCalendar(start: Date, end: Date) async throws -> [CalendarEventRecord] { events }
    func createCalendarEvent(id: String, title: String, start: Date, end: Date, sourceURL: URL?) async throws -> CalendarEventRecord {
        creates += 1
        let result = CalendarEventRecord(id: id, title: title, start: start, end: end, sourceURL: sourceURL)
        events.append(result)
        return result
    }
    func updateCalendarEvent(id: String, title: String?, start: Date?, end: Date?) async throws -> CalendarEventRecord {
        guard let index = events.firstIndex(where: { $0.id == id }) else { throw CalendarAccessError.notOwned }
        let current = events[index]
        let result = CalendarEventRecord(id: id, title: title ?? current.title, start: start ?? current.start,
                                          end: end ?? current.end, sourceURL: current.sourceURL)
        events[index] = result
        return result
    }
    func cancelCalendarEvent(id: String) async throws { events.removeAll { $0.id == id } }
}

final class CalendarHostTests: XCTestCase {
    private func request(_ client: WorkbenchClientCredential, _ action: String, _ parameters: [String: JSONValue], id: String = UUID().uuidString) -> WorkbenchRequest {
        .init(requestID: id, operation: "action", action: action, parameters: .object(parameters), credential: client.credential)
    }

    func testCalendarGrantFreezesScopeAndWriteRequestDeduplicates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-host-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = CalendarHostFakeBridge()
        let host = try WorkbenchHost(bridge: bridge, directory: directory)
        let client = try await host.createClient(name: "Calendar")
        do { try await host.setGrants(clientID: client.id, grants: [.calendarRead]); XCTFail("Scope missing") }
        catch WorkbenchHostError.calendarScopeMissing {}
        await bridge.setScope("calendar-1")
        try await host.setGrants(clientID: client.id, grants: [.calendarRead, .calendarWrite])
        let saved = await host.clients().first { $0.id == client.id }
        XCTAssertEqual(saved?.calendarScopeID, "calendar-1")
        let params: [String: JSONValue] = ["event_id": .string("stable-1"), "title": .string("Meeting"),
            "start_at": .string("2030-01-01T10:00:00Z"), "end_at": .string("2030-01-01T11:00:00Z")]
        let id = UUID().uuidString
        let first = await host.process(request(client, "calendar.create", params, id: id))
        XCTAssertEqual(first.status, "succeeded")
        let repeated = await host.process(request(client, "calendar.create", params, id: id))
        XCTAssertEqual(repeated.status, "succeeded")
        let count = await bridge.createCount()
        XCTAssertEqual(count, 1)
        await bridge.setScope("calendar-2")
        let denied = await host.process(request(client, "calendar.list", ["start_at": .string("2030-01-01T00:00:00Z"), "end_at": .string("2030-01-02T00:00:00Z")]))
        XCTAssertEqual(denied.error, "permission_required")
        let capabilities = await host.process(.init(requestID: UUID().uuidString, operation: "capabilities", credential: client.credential))
        XCTAssertFalse(String(describing: capabilities.result).contains("calendar.create"))
    }

    func testCalendarRejectsArbitraryURLAndPauseBeforeDispatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-host-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = CalendarHostFakeBridge()
        await bridge.setScope("calendar-1")
        let host = try WorkbenchHost(bridge: bridge, directory: directory)
        let client = try await host.createClient(name: "Calendar")
        try await host.setGrants(clientID: client.id, grants: [.calendarWrite])
        var params: [String: JSONValue] = ["event_id": .string("stable-1"), "title": .string("Meeting"),
            "start_at": .string("2030-01-01T10:00:00Z"), "end_at": .string("2030-01-01T11:00:00Z"),
            "source_url": .string("file:///tmp/private")]
        let rejected = await host.process(request(client, "calendar.create", params))
        XCTAssertEqual(rejected.error, "invalid_schema")
        params["source_url"] = .string("https://example.com/source")
        try await bridge.setPaused(true)
        let paused = await host.process(request(client, "calendar.create", params))
        XCTAssertEqual(paused.error, "bridge_paused")
        let count = await bridge.createCount()
        XCTAssertEqual(count, 0)
    }
}
