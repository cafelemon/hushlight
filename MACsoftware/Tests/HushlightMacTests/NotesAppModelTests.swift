import BridgeCore
import Foundation
import XCTest
@testable import HushlightMac

@MainActor
final class NotesAppModelTests: XCTestCase {
    func testExplicitConnectionListsReadsCreatesAndAppends() async {
        let service = NotesModelFixture()
        let model = AppModel(bridgeService: service)
        await model.refresh()
        XCTAssertFalse(model.notesEnabled)
        await model.listNotes(query: "")
        let beforeEnableLists = await service.listCount
        XCTAssertEqual(beforeEnableLists, 0)

        await model.enableNotes()
        XCTAssertTrue(model.notesEnabled)
        let afterEnableLists = await service.listCount
        XCTAssertEqual(afterEnableLists, 1)
        XCTAssertEqual(model.notes.first?.title, "第一条")

        await model.readNote(id: "note-1")
        XCTAssertEqual(model.selectedNote?.text, "第一条\n正文")
        await model.appendNote(text: "追加")
        let submittedRevision = await service.lastExpectedRevision
        XCTAssertEqual(submittedRevision, "rev-1")
        XCTAssertEqual(model.selectedNote?.revision, "rev-2")
        await model.createNote(title: "新条目", text: "内容")
        XCTAssertEqual(model.selectedNote?.title, "新条目")
        XCTAssertEqual(model.notes.count, 2)
        XCTAssertFalse(model.isBusy)
    }

    func testFailedReadClearsOldContentAndSuccess() async {
        let service = NotesModelFixture()
        let model = AppModel(bridgeService: service)
        await model.enableNotes()
        await model.readNote(id: "note-1")
        XCTAssertNotNil(model.selectedNote)
        await model.readNote(id: "missing")
        XCTAssertNil(model.selectedNote)
        XCTAssertEqual(model.notesResult?.status, "failed")
        XCTAssertNotNil(model.notesError)
    }

    func testPausedActionsNeverReachService() async {
        let service = NotesModelFixture()
        let model = AppModel(bridgeService: service)
        await model.refresh()
        await model.togglePause()
        await model.enableNotes()
        await model.listNotes(query: "x")
        await model.createNote(title: "blocked", text: "")
        let enableCount = await service.enableCount
        let listCount = await service.listCount
        let createCount = await service.createCount
        XCTAssertEqual(enableCount, 0)
        XCTAssertEqual(listCount, 0)
        XCTAssertEqual(createCount, 0)
    }

    func testBusyDuplicateClickDoesNotSubmitAnotherAction() async {
        let service = NotesModelFixture(suspendList: true)
        let model = AppModel(bridgeService: service)
        let first = Task { await model.enableNotes() }
        await service.waitForListStart()
        XCTAssertTrue(model.isBusy)
        await model.enableNotes()
        await model.listNotes(query: "repeat")
        await model.createNote(title: "repeat", text: "")
        let enableCount = await service.enableCount
        let listCount = await service.listCount
        let createCount = await service.createCount
        XCTAssertEqual(enableCount, 1)
        XCTAssertEqual(listCount, 1)
        XCTAssertEqual(createCount, 0)
        await service.releaseList()
        await first.value
        XCTAssertFalse(model.isBusy)
    }
}

private actor NotesModelFixture: BridgeService {
    private var enabled = false
    private var paused = false
    private let suspendList: Bool
    private var listContinuation: CheckedContinuation<Void, Never>?
    private var listWaiters: [CheckedContinuation<Void, Never>] = []
    private var records = [LocalNoteSummary(id: "note-1", title: "第一条")]
    private(set) var enableCount = 0
    private(set) var listCount = 0
    private(set) var createCount = 0
    private(set) var lastExpectedRevision: String?

    init(suspendList: Bool = false) { self.suspendList = suspendList }

    func snapshot() async throws -> BridgeSnapshot {
        BridgeSnapshot(status: paused ? .paused : .localReady, permissions: [], recentActions: [],
                       notesEnabled: enabled)
    }

    func setPaused(_ value: Bool) async throws { paused = value }
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
    func enableNotes() async throws { enableCount += 1; enabled = true }

    func listNotes(query: String) async throws -> LocalNotesCommandResult {
        listCount += 1
        listWaiters.forEach { $0.resume() }
        listWaiters.removeAll()
        if suspendList { await withCheckedContinuation { listContinuation = $0 } }
        return result(notes: records.filter { query.isEmpty || $0.title.contains(query) })
    }

    func readNote(id: String) async throws -> LocalNotesCommandResult {
        guard records.contains(where: { $0.id == id }) else {
            return LocalNotesCommandResult(status: "failed", stableError: "invalid_schema", completedAt: Date())
        }
        return result(note: LocalNoteContent(id: id, title: "第一条", text: "第一条\n正文",
                                             revision: "rev-1", canAppend: true))
    }

    func createNote(id: String, title: String, text: String) async throws -> LocalNotesCommandResult {
        createCount += 1
        records.append(LocalNoteSummary(id: id, title: title))
        return result(notes: records, note: LocalNoteContent(id: id, title: title, text: "\(title)\n\(text)",
                                                             revision: "rev-new", canAppend: true))
    }

    func appendNote(id: String, text: String, expectedRevision: String) async throws -> LocalNotesCommandResult {
        lastExpectedRevision = expectedRevision
        return result(notes: records, note: LocalNoteContent(id: id, title: "第一条",
                                                             text: "第一条\n正文\n\(text)",
                                                             revision: "rev-2", canAppend: true))
    }

    func waitForListStart() async {
        if listCount > 0 { return }
        await withCheckedContinuation { listWaiters.append($0) }
    }

    func releaseList() { listContinuation?.resume(); listContinuation = nil }

    private func result(notes: [LocalNoteSummary] = [], note: LocalNoteContent? = nil) -> LocalNotesCommandResult {
        LocalNotesCommandResult(status: "succeeded", stableError: nil, completedAt: Date(),
                                notes: notes, note: note)
    }
}
