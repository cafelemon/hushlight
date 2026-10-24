import Foundation
import XCTest
@testable import BridgeCore

private actor FakeNotesBackend: NotesBackend {
    nonisolated let isSimulation = true
    var enabled = true
    var note: LocalNoteContent?
    var distortReadback = false
    var throwAfterWrite = false
    var throwOnRead = false
    var throwOnReadAfterWrites: Int?
    var writeCount = 0
    var enableCount = 0
    var accessCount = 0

    func isEnabled() async -> Bool { accessCount += 1; return enabled }
    func enable() async throws { accessCount += 1; enableCount += 1; enabled = true }
    func list(query: String) async throws -> [LocalNoteSummary] {
        accessCount += 1
        guard let note, query.isEmpty || note.title.contains(query) else { return [] }
        return [LocalNoteSummary(id: note.id, title: note.title)]
    }
    func read(id: String) async throws -> LocalNoteContent {
        accessCount += 1
        if throwOnRead || (throwOnReadAfterWrites.map { writeCount >= $0 } ?? false) {
            throw StableErrorCode.permissionRequired
        }
        guard let note, note.id == id else { throw StableErrorCode.invalidSchema }
        if distortReadback {
            return LocalNoteContent(id: id, title: note.title, text: "unexpected", revision: note.revision, canAppend: true)
        }
        return note
    }
    func create(id: String, title: String, text: String) async throws -> LocalNoteContent {
        accessCount += 1
        writeCount += 1
        let created = LocalNoteContent(id: id, title: title,
                                       text: LocalNotesText.canonical(title + "\n" + text),
                                       revision: String(repeating: "a", count: 64), canAppend: true)
        note = created
        if throwAfterWrite { throw StableErrorCode.resultUnverifiable }
        return created
    }
    func append(id: String, text: String, expectedRevision: String) async throws -> LocalNoteContent {
        accessCount += 1
        guard let previous = note, previous.id == id, previous.revision == expectedRevision else {
            throw StableErrorCode.invalidSchema
        }
        writeCount += 1
        let updated = LocalNoteContent(id: id, title: previous.title,
                                       text: LocalNotesText.canonical(previous.text + "\n" + text),
                                       revision: String(repeating: "b", count: 64), canAppend: true)
        note = updated
        if throwAfterWrite { throw StableErrorCode.resultUnverifiable }
        return updated
    }
    func setDistortReadback(_ value: Bool) { distortReadback = value }
    func setEnabled(_ value: Bool) { enabled = value }
    func setThrowAfterWrite(_ value: Bool) { throwAfterWrite = value }
    func setThrowOnRead(_ value: Bool) { throwOnRead = value }
    func setThrowOnReadAfterWrites(_ value: Int?) { throwOnReadAfterWrites = value }
    func count() -> Int { writeCount }
    func counts() -> (access: Int, enable: Int, write: Int) { (accessCount, enableCount, writeCount) }
}

private actor RealCountingNotesBackend: NotesBackend {
    private var accesses = 0
    func isEnabled() async -> Bool { accesses += 1; return true }
    func enable() async throws { accesses += 1 }
    func list(query: String) async throws -> [LocalNoteSummary] { accesses += 1; return [] }
    func read(id: String) async throws -> LocalNoteContent { accesses += 1; throw StableErrorCode.invalidSchema }
    func create(id: String, title: String, text: String) async throws -> LocalNoteContent { accesses += 1; throw StableErrorCode.invalidSchema }
    func append(id: String, text: String, expectedRevision: String) async throws -> LocalNoteContent { accesses += 1; throw StableErrorCode.invalidSchema }
    func count() -> Int { accesses }
}

final class LocalNotesTests: XCTestCase {
    func testLocalRuntimeRoundTripAndMetadataHistory() async throws {
        let backend = FakeNotesBackend()
        let runtime = try await BridgeLocalRuntime(simulate: true, notesCoordinator: LocalNotesCoordinator(backend: backend))
        let created = await runtime.createNote(id: "n1", title: "Title", text: "body\r\n")
        XCTAssertEqual(created.status, "succeeded")
        XCTAssertEqual(created.note?.text, "Title\nbody")
        XCTAssertEqual(created.notes, [.init(id: "n1", title: "Title")])
        let listed = await runtime.listNotes()
        XCTAssertEqual(listed.notes, [.init(id: "n1", title: "Title")])
        let read = await runtime.readNote(id: "n1")
        XCTAssertEqual(read.note, created.note)
        let appended = await runtime.appendNote(id: "n1", text: "more", expectedRevision: created.note!.revision)
        XCTAssertEqual(appended.status, "succeeded")
        XCTAssertEqual(appended.note?.text, "Title\nbody\nmore")
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.recentActions.count, 4)
        XCTAssertFalse(String(describing: snapshot).contains("body"))
        XCTAssertTrue(snapshot.isSimulation)
    }

    func testConflictRejectsBeforeWriteAndReadbackFailureIsUnknown() async throws {
        let backend = FakeNotesBackend()
        let runtime = try await BridgeLocalRuntime(simulate: true, notesCoordinator: LocalNotesCoordinator(backend: backend))
        let created = await runtime.createNote(id: "n1", title: "Title", text: "body")
        XCTAssertEqual(created.status, "succeeded")
        let conflict = await runtime.appendNote(id: "n1", text: "more", expectedRevision: String(repeating: "0", count: 64))
        XCTAssertEqual(conflict.status, "rejected")
        XCTAssertEqual(conflict.stableError, "invalid_schema")
        let writes = await backend.count()
        XCTAssertEqual(writes, 1)
        await backend.setDistortReadback(true)
        let unverified = await runtime.createNote(id: "n2", title: "Another", text: "body")
        XCTAssertEqual(unverified.status, "unknown")
        XCTAssertEqual(unverified.stableError, "result_unverifiable")
    }

    func testCanonicalKeepsTrailingSpaces() {
        XCTAssertEqual(LocalNotesText.canonical("a  \r\nb  \r\n"), "a  \nb  ")
    }

    func testSimulationRejectsRealBackendBeforeAnyAccess() async throws {
        let backend = RealCountingNotesBackend()
        do {
            _ = try await BridgeLocalRuntime(simulate: true, notesCoordinator: LocalNotesCoordinator(backend: backend))
            XCTFail("A real backend must not enter simulation mode")
        } catch {
            guard case BridgeLocalCLIConfigurationError.conflictingModes = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let accesses = await backend.count()
        XCTAssertEqual(accesses, 0)
    }

    func testPauseRejectsEveryNotesActionWithoutBackendAccess() async throws {
        let backend = FakeNotesBackend()
        let runtime = try await BridgeLocalRuntime(simulate: true, paused: true,
                                                   notesCoordinator: LocalNotesCoordinator(backend: backend))
        let results = [
            await runtime.listNotes(),
            await runtime.readNote(id: "n1"),
            await runtime.createNote(id: "n1", title: "Title", text: "body"),
            await runtime.appendNote(id: "n1", text: "body", expectedRevision: String(repeating: "a", count: 64))
        ]
        XCTAssertEqual(results.map(\.status), Array(repeating: "rejected", count: 4))
        XCTAssertEqual(results.map(\.stableError), Array(repeating: "bridge_paused", count: 4))
        let counts = await backend.counts()
        XCTAssertEqual(counts.access, 0)
    }

    func testDisabledBackendRejectsWithoutImplicitEnable() async throws {
        let backend = FakeNotesBackend()
        await backend.setEnabled(false)
        let runtime = try await BridgeLocalRuntime(simulate: true, notesCoordinator: LocalNotesCoordinator(backend: backend))
        let results = [
            await runtime.listNotes(),
            await runtime.readNote(id: "n1"),
            await runtime.createNote(id: "n1", title: "Title", text: "body"),
            await runtime.appendNote(id: "n1", text: "body", expectedRevision: String(repeating: "a", count: 64))
        ]
        XCTAssertEqual(results.map(\.stableError), Array(repeating: "capability_disabled", count: 4))
        let counts = await backend.counts()
        XCTAssertEqual(counts.enable, 0)
        XCTAssertEqual(counts.write, 0)
    }

    func testWriteThenThrowOrReadbackThrowIsUnknown() async throws {
        let createBackend = FakeNotesBackend()
        await createBackend.setThrowAfterWrite(true)
        let createRuntime = try await BridgeLocalRuntime(simulate: true,
                                                         notesCoordinator: LocalNotesCoordinator(backend: createBackend))
        let create = await createRuntime.createNote(id: "n1", title: "Title", text: "body")
        XCTAssertEqual(create.status, "unknown")
        XCTAssertEqual(create.stableError, "result_unverifiable")
        let createWrites = await createBackend.count()
        XCTAssertEqual(createWrites, 1)

        let readbackBackend = FakeNotesBackend()
        await readbackBackend.setThrowOnReadAfterWrites(1)
        let readbackRuntime = try await BridgeLocalRuntime(simulate: true,
                                                           notesCoordinator: LocalNotesCoordinator(backend: readbackBackend))
        let readback = await readbackRuntime.createNote(id: "n1", title: "Title", text: "body")
        XCTAssertEqual(readback.status, "unknown")
        XCTAssertEqual(readback.stableError, "result_unverifiable")

        let appendBackend = FakeNotesBackend()
        let appendRuntime = try await BridgeLocalRuntime(simulate: true,
                                                         notesCoordinator: LocalNotesCoordinator(backend: appendBackend))
        let seed = await appendRuntime.createNote(id: "n1", title: "Title", text: "body")
        await appendBackend.setThrowAfterWrite(true)
        let append = await appendRuntime.appendNote(id: "n1", text: "later", expectedRevision: seed.note!.revision)
        XCTAssertEqual(append.status, "unknown")
        XCTAssertEqual(append.stableError, "result_unverifiable")
        let appendWrites = await appendBackend.count()
        XCTAssertEqual(appendWrites, 2)

        let appendReadbackBackend = FakeNotesBackend()
        let appendReadbackRuntime = try await BridgeLocalRuntime(simulate: true,
                                                                 notesCoordinator: LocalNotesCoordinator(backend: appendReadbackBackend))
        let initial = await appendReadbackRuntime.createNote(id: "n1", title: "Title", text: "body")
        await appendReadbackBackend.setThrowOnReadAfterWrites(2)
        let appendReadback = await appendReadbackRuntime.appendNote(id: "n1", text: "later",
                                                                    expectedRevision: initial.note!.revision)
        XCTAssertEqual(appendReadback.status, "unknown")
        XCTAssertEqual(appendReadback.stableError, "result_unverifiable")
    }
}
