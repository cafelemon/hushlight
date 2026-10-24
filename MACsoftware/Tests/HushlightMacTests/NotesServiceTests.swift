import BridgeCore
import Foundation
import XCTest
@testable import HushlightMac

final class NotesServiceTests: XCTestCase {
    func testServiceScopeEnableCommandsAndPause() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-service-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try AppleNotesBackend(storageURL: root.appendingPathComponent("notes.json"), runner: NotesRunnerFake())
        let service = LocalBridgeService(preferences: NotesServicePauseStore(), timerStorageURL: root.appendingPathComponent("timers.json"), notesBackend: backend)
        let initial = try await service.snapshot()
        XCTAssertFalse(initial.notesEnabled)
        try await service.enableNotes()
        let enabled = try await service.snapshot()
        XCTAssertTrue(enabled.notesEnabled)
        let created = try await service.createNote(id: "service", title: "Service", text: "Text")
        XCTAssertEqual(created.status, "succeeded")
        let selected = try await service.readNote(id: "service")
        let note = try XCTUnwrap(selected.note)
        let appended = try await service.appendNote(id: "service", text: "More", expectedRevision: note.revision)
        XCTAssertEqual(appended.status, "succeeded")
        let listed = try await service.listNotes(query: "Service")
        XCTAssertEqual(listed.notes.map(\.id), ["service"])
        try await service.setPaused(true)
        let paused = try await service.listNotes(query: "")
        XCTAssertEqual(paused.stableError, "bridge_paused")
        try await service.setPaused(false)
    }
}

private final class NotesServicePauseStore: PausePreferenceStore, @unchecked Sendable {
    func loadPaused() -> Bool { false }
    func savePaused(_ paused: Bool) {}
}
