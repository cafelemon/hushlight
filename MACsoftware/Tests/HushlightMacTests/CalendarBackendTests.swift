import EventKit
import Foundation
import XCTest
@testable import HushlightMac

final class CalendarBackendTests: XCTestCase {
    func testAutomationStableCalendarIDAccepted() throws {
        try EventKitCalendarBackend.valid(id: "automation_" + String(repeating: "a", count: 64), title: "Meeting",
            start: Date(), end: Date().addingTimeInterval(3600), sourceURL: nil)
    }
    func testNoAppStatusNeverPromptsOrCreatesCalendar() async throws {
        let suite = "calendar-no-app-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-\(UUID())/ledger.json")
        let backend = EventKitCalendarBackend(defaultsSuiteName: suite, ledgerURL: file, store: nil)
        let scope = await backend.scopeIdentifier()
        XCTAssertNil(scope)
        do { _ = try await backend.requestAuthorization(); XCTFail("No app") }
        catch CalendarAccessError.requiresApp {}
        do { _ = try await backend.enableDedicatedCalendar(); XCTFail("No app") }
        catch CalendarAccessError.requiresApp {}
    }

    func testPrewriteLedgerSurvivesRestartAndBlocksUnknownReplay() async throws {
        let suite = "calendar-ledger-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-ledger-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("writes.json")
        let first = EventKitCalendarBackend(defaultsSuiteName: suite, ledgerURL: file, store: nil)
        try await first.beginWrite(id: "event-1", operation: "create", fingerprint: "hash", nativeID: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let restarted = EventKitCalendarBackend(defaultsSuiteName: suite, ledgerURL: file, store: nil)
        do {
            try await restarted.beginWrite(id: "event-1", operation: "create", fingerprint: "hash", nativeID: nil)
            XCTFail("Pending write must not replay")
        } catch CalendarAccessError.uncertainWrite {}
        try await first.markUnknown(id: "event-1")
        let afterUnknown = EventKitCalendarBackend(defaultsSuiteName: suite, ledgerURL: file, store: nil)
        do {
            try await afterUnknown.beginWrite(id: "event-1", operation: "create", fingerprint: "hash", nativeID: nil)
            XCTFail("Unknown write must not replay")
        } catch CalendarAccessError.uncertainWrite {}
    }

    func testCorruptLedgerFailsClosed() async throws {
        let suite = "calendar-corrupt-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-corrupt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("writes.json")
        try Data("broken".utf8).write(to: file)
        let backend = EventKitCalendarBackend(defaultsSuiteName: suite, ledgerURL: file, store: nil)
        do {
            try await backend.beginWrite(id: "event-1", operation: "create", fingerprint: "hash", nativeID: nil)
            XCTFail("Corrupt ledger must not be replaced")
        } catch CalendarAccessError.corruptLedger {}
        XCTAssertEqual(try Data(contentsOf: file), Data("broken".utf8))
    }

    func testSavedScopeWithoutLedgerFailsClosed() async throws {
        let suite = "calendar-missing-ledger-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("previous-calendar", forKey: "bridge.events.calendarIdentifier")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-missing-\(UUID())/writes.json")
        let backend = EventKitCalendarBackend(defaultsSuiteName: suite, ledgerURL: file, store: nil)
        let scope = await backend.scopeIdentifier()
        XCTAssertNil(scope)
        do {
            try await backend.beginWrite(id: "event-1", operation: "create", fingerprint: "hash", nativeID: nil)
            XCTFail("Missing ownership ledger must fail closed")
        } catch CalendarAccessError.corruptLedger {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testSourceURLAcceptsBoundedMailEvidenceAndRejectsLocalFiles() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3600)
        try EventKitCalendarBackend.valid(id: "event-1", title: "Meeting", start: start, end: end,
            sourceURL: URL(string: "workbench-source://mail/mail.\(String(repeating: "a", count: 64)).42"))
        do {
            try EventKitCalendarBackend.valid(id: "event-1", title: "Meeting", start: start, end: end,
                sourceURL: URL(fileURLWithPath: "/tmp/private"))
            XCTFail("Local file source must be rejected")
        } catch CalendarAccessError.invalidInput {}
    }
}
