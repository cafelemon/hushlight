import BridgeCore
import Foundation
import XCTest
@testable import HushlightMac

final class AppleNotesBackendTests: XCTestCase {
    func testExplicitScopeCreateAppendAndRestartWithoutContentInLedger() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = NotesRunnerFake()
        let url = root.appendingPathComponent("notes.json")
        let backend = try AppleNotesBackend(storageURL: url, runner: runner)
        do { _ = try await backend.list(query: ""); XCTFail("Must explicitly enable") } catch {}
        let beforeEnable = await runner.operations
        XCTAssertTrue(beforeEnable.isEmpty)
        try await backend.enable()
        let title = "Title \" quote"
        let text = "<script> & '\n中文"
        let created = try await backend.create(id: "test-id", title: title, text: text)
        XCTAssertEqual(created.text, title + "\n" + text)
        XCTAssertTrue(created.canAppend)
        let appended = try await backend.append(id: "test-id", text: "More", expectedRevision: created.revision)
        XCTAssertEqual(appended.text, created.text + "\nMore")
        let ledger = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(ledger.contains(title))
        XCTAssertFalse(ledger.contains("中文"))
        let ledgerMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        let directoryMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(ledgerMode.intValue & 0o777, 0o600)
        XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
        let restarted = try AppleNotesBackend(storageURL: url, runner: runner)
        let initiallyEnabled = await restarted.isEnabled()
        XCTAssertTrue(initiallyEnabled)
        let savedScope = await restarted.scopeIdentifier()
        XCTAssertEqual(savedScope, "folder-own")
        let restored = try await restarted.read(id: "test-id")
        XCTAssertEqual(restored, appended)
        let operations = await runner.operations
        XCTAssertTrue(operations.dropFirst().allSatisfy { $0.accountID == "account-own" && $0.folderID == "folder-own" })
        let create = try XCTUnwrap(operations.first { $0.operation == "create" })
        XCTAssertTrue(create.html.contains("&lt;script&gt; &amp; &#39;"))
        XCTAssertFalse(create.html.contains("<script>"))
    }

    func testExternalChangesAttachmentsAndUnownedNotesAreReadOnly() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = NotesRunnerFake()
        let url = root.appendingPathComponent("notes.json")
        let backend = try AppleNotesBackend(storageURL: url, runner: runner)
        try await backend.enable()
        let value = try await backend.create(id: "owned", title: "Title", text: "Text")
        await runner.changeHTML(value: "<div>Title</div><div>External</div>")
        let changed = try await backend.read(id: "owned")
        XCTAssertFalse(changed.canAppend)
        do {
            _ = try await backend.append(id: "owned", text: "Blocked", expectedRevision: value.revision)
            XCTFail("External changes must not be overwritten")
        } catch StableErrorCode.invalidSchema {}
        await runner.setAttachments(1)
        let attached = try await backend.read(id: "owned")
        XCTAssertFalse(attached.canAppend)
        await runner.addUnowned()
        let unowned = try await backend.read(id: "native-unowned")
        XCTAssertFalse(unowned.canAppend)
        do {
            _ = try await backend.append(id: unowned.id, text: "Blocked", expectedRevision: unowned.revision)
            XCTFail("Unowned notes must remain read-only")
        } catch StableErrorCode.invalidSchema {}
        let mutations = await runner.operations.filter { $0.operation == "append" }
        XCTAssertTrue(mutations.isEmpty)
    }

    func testUncertainCreateJournalBlocksRetryAndReconnectOnlyReconciles() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = NotesRunnerFake()
        let url = root.appendingPathComponent("notes.json")
        let backend = try AppleNotesBackend(storageURL: url, runner: runner)
        try await backend.enable()
        await runner.failAfterCreate()
        do {
            _ = try await backend.create(id: "unknown", title: "Title", text: "Text")
            XCTFail("Applied but unacknowledged write must be unknown")
        } catch StableErrorCode.resultUnverifiable {}
        do {
            _ = try await backend.create(id: "new-id", title: "Title", text: "Text")
            XCTFail("Do not duplicate an uncertain write")
        } catch NotesAccessError.pendingWrite {}
        let restarted = try AppleNotesBackend(storageURL: url, runner: runner)
        let ready = await restarted.isEnabled()
        XCTAssertTrue(ready)
        let recovered = try await restarted.read(id: "unknown")
        XCTAssertTrue(recovered.canAppend)
        let creates = await runner.operations.filter { $0.operation == "create" }
        XCTAssertEqual(creates.count, 1)
    }

    func testStyleOnlyChangeAfterWriteIsNotAdoptedDuringReadbackOrReconnect() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = NotesRunnerFake()
        let backend = try AppleNotesBackend(storageURL: root.appendingPathComponent("notes.json"), runner: runner)
        try await backend.enable()
        let initial = try await backend.create(id: "style", title: "Title", text: "Text")
        await runner.styleAfterWrite()
        do {
            _ = try await backend.append(id: "style", text: "More", expectedRevision: initial.revision)
            XCTFail("Same plain text does not prove unchanged formatting")
        } catch StableErrorCode.resultUnverifiable {}
        let observed = try await backend.read(id: "style")
        XCTAssertEqual(observed.text, "Title\nText\nMore")
        XCTAssertFalse(observed.canAppend)
        do { try await backend.enable(); XCTFail("Must not adopt changed HTML") }
        catch NotesAccessError.pendingWrite {}
    }

    func testProvablePreflightRejectionDoesNotLeaveBlockedJournal() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = NotesRunnerFake()
        let backend = try AppleNotesBackend(storageURL: root.appendingPathComponent("notes.json"), runner: runner)
        try await backend.enable()
        await runner.rejectBeforeCreate()
        do {
            _ = try await backend.create(id: "rejected", title: "Title", text: "Text")
            XCTFail("Capacity must reject")
        } catch StableErrorCode.capabilityDisabled {}
        let retry = try await backend.create(id: "after-rejection", title: "Title", text: "Text")
        XCTAssertTrue(retry.canAppend)
    }

    func testCorruptLedgerPreservedAndUnbundledRunnerNeverExecutes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("notes.json")
        let invalid = Data("broken".utf8)
        try invalid.write(to: url)
        XCTAssertThrowsError(try AppleNotesBackend(storageURL: url, runner: NotesRunnerFake()))
        XCTAssertEqual(try Data(contentsOf: url), invalid)
        do {
            _ = try await AppleNotesScriptRunner().run(NotesScriptRequest(operation: "enable"))
            XCTFail("Tests must not run real Notes automation")
        } catch NotesAccessError.requiresApp {}
    }

    func testRestartVerificationFailsClosedWhenSavedScopeIsMissing() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = NotesRunnerFake()
        let url = root.appendingPathComponent("notes.json")
        try await AppleNotesBackend(storageURL: url, runner: runner).enable()
        await runner.removeScope()
        let restarted = try AppleNotesBackend(storageURL: url, runner: runner)
        let enabled = await restarted.isEnabled()
        XCTAssertFalse(enabled)
        let scope = await restarted.scopeIdentifier()
        XCTAssertNil(scope)
        let operations = await runner.operations
        XCTAssertEqual(operations.map(\.operation), ["enable", "verify", "verify"])
    }

    func testPaginatedFolderBeyondHundredKeepsOwnedNotesAndRejectsExternalEdit() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = NotesRunnerFake()
        let backend = try AppleNotesBackend(storageURL: root.appendingPathComponent("notes.json"), runner: runner)
        try await backend.enable()
        await runner.addUnowned(count: 230)
        let created = try await backend.create(id: "daily-1", title: "Day", text: "Summary")
        let listed = try await backend.list(query: "")
        XCTAssertEqual(listed.count, 231)
        let pages = await runner.operations.filter { $0.operation == "list" }
        XCTAssertTrue(pages.contains { $0.offset >= 200 })
        await runner.changeHTML(id: "native-230", value: "<div>Day</div><div>External</div>")
        let changed = try await backend.read(id: "daily-1")
        XCTAssertFalse(changed.canAppend)
        do {
            _ = try await backend.append(id: "daily-1", text: "No overwrite", expectedRevision: created.revision)
            XCTFail("External edit must block append")
        } catch StableErrorCode.invalidSchema {}
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("notes-test-\(UUID())")
    }
}

actor NotesRunnerFake: NotesScriptRunning {
    let isSimulation = true
    private(set) var operations: [NotesScriptRequest] = []
    private var notes: [String: (title: String, html: String, attachments: Int)] = [:]
    private var failCreate = false
    private var rejectCreate = false
    private var styleWrite = false
    private var scopeAvailable = true
    func removeScope() { scopeAvailable = false }
    func rejectBeforeCreate() { rejectCreate = true }
    func styleAfterWrite() { styleWrite = true }
    func failAfterCreate() { failCreate = true }
    func changeHTML(value: String) { if let id = notes.keys.first { notes[id]?.html = value } }
    func changeHTML(id: String, value: String) { notes[id]?.html = value }
    func setAttachments(_ value: Int) { if let id = notes.keys.first { notes[id]?.attachments = value } }
    func addUnowned() { notes["native-unowned"] = ("Unowned", "<div>Unowned</div><div>Text</div>", 0) }
    func addUnowned(count: Int) {
        for i in 0..<count { notes["unowned-\(i)"] = ("Unowned \(i)", "<div>Unowned</div>", 0) }
    }
    func run(_ request: NotesScriptRequest) async throws -> [[String]] {
        operations.append(request)
        if request.operation == "enable" && request.accountID.isEmpty {
            return [["account-own", "folder-own"]]
        }
        guard scopeAvailable, request.accountID == "account-own", request.folderID == "folder-own" else {
            throw NotesAccessError.unavailable
        }
        switch request.operation {
        case "enable", "verify": return [["account-own", "folder-own"]]
        case "list":
            let sorted = notes.sorted { $0.key < $1.key }
            guard request.offset <= sorted.count else { throw NotesAccessError.unavailable }
            return [["page", String(sorted.count)]] + sorted.dropFirst(request.offset).prefix(request.limit).map { [$0.key, $0.value.title] }
        case "create":
            if rejectCreate { rejectCreate = false; throw NotesScriptRejection.capacity }
            let id = "native-\(notes.count)"
            let title = Self.plain(request.html).components(separatedBy: "\n").first!
            notes[id] = (title, request.html, 0)
            if failCreate { failCreate = false; throw NotesAccessError.unavailable }
            return [[id]]
        case "read":
            guard let value = notes[request.noteID] else { throw NotesAccessError.unavailable }
            return [[request.noteID, value.title, Self.plain(value.html), value.html, String(value.attachments)]]
        case "append":
            guard let value = notes[request.noteID], value.html == request.expectedHTML else { throw StableErrorCode.invalidSchema }
            let html = styleWrite ? request.html.replacingOccurrences(of: "<div>", with: "<div style=\"font-weight:bold\">") : request.html
            styleWrite = false
            notes[request.noteID] = (value.title, html, value.attachments)
            return [[request.noteID]]
        default: throw NotesAccessError.unavailable
        }
    }
    private static func plain(_ html: String) -> String {
        let text = html.replacingOccurrences(of: "</div>", with: "\n")
            .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
        return LocalNotesText.canonical(text)
    }
}
