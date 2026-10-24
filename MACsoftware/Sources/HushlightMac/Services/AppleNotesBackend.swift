import BridgeCore
import CryptoKit
import Foundation

enum NotesAccessError: LocalizedError {
    case requiresApp, notEnabled, unavailable, folderConflict, pendingWrite, corruptState
    var errorDescription: String? {
        switch self {
        case .requiresApp: "请在开发版 App 中连接备忘录。"
        case .notEnabled: "请先连接备忘录并启用专用文件夹。"
        case .unavailable: "无法核对专用备忘录，请检查 Notes 账户、自动化权限和文件夹。"
        case .folderConflict: "默认账户已有同名“Agent 工作台”文件夹；不会接管它。请先重命名该文件夹，再连接。"
        case .pendingWrite: "有一笔写入待核对。请先在系统备忘录检查，再重新连接；核实前不会重复写入。"
        case .corruptState: "备忘录范围记录损坏，原文件已保留，已停止写入。"
        }
    }
}

enum NotesScriptRejection: Error {
    case permissionRequired, invalidTarget, unsafeNote, capacity, revisionConflict
    var stableCode: StableErrorCode {
        switch self {
        case .permissionRequired: .permissionRequired
        case .invalidTarget, .revisionConflict: .invalidSchema
        case .unsafeNote, .capacity: .capabilityDisabled
        }
    }
}

struct NotesScriptRequest: Codable, Sendable {
    let operation: String
    var accountID = ""
    var folderID = ""
    var noteID = ""
    var expectedHTML = ""
    var html = ""
    var offset = 0
    var limit = 100
}

protocol NotesScriptRunning: Sendable {
    var isSimulation: Bool { get }
    func run(_ request: NotesScriptRequest) async throws -> [[String]]
}

/// Uses Apple's Notes scripting API, never GUI scripting. No content in argv or error logs.
struct AppleNotesScriptRunner: NotesScriptRunning {
    let isSimulation = false
    func run(_ request: NotesScriptRequest) async throws -> [[String]] {
        guard Bundle.main.bundleIdentifier == "com.hushlight.bridge.mac",
              let scriptURL = Bundle.module.url(forResource: "NotesBridge", withExtension: "applescript") else {
            throw NotesAccessError.requiresApp
        }
        if (BridgeExecutionContext.backgroundAutomation || BridgeExecutionContext.callerID != "local_ui"), AppleEventPermission.status(bundleID: "com.apple.Notes") != .granted { throw NotesScriptRejection.permissionRequired }
        let input = try JSONEncoder().encode(request)
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [scriptURL.path]
            let stdin = Pipe(), stdout = Pipe()
            // A compiler/launch failure may close stdin early; return an error instead of SIGPIPE.
            guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw NotesAccessError.unavailable
            }
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            let timeout = DispatchSource.makeTimerSource()
            timeout.schedule(deadline: .now() + 30)
            timeout.setEventHandler {
                if process.isRunning {
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
            try process.run()
            timeout.resume()
            defer { timeout.cancel() }
            do { try stdin.fileHandleForWriting.write(contentsOf: input) }
            catch { process.terminate(); throw NotesAccessError.unavailable }
            try? stdin.fileHandleForWriting.close()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, data.count <= 1_000_000,
                  let rows = try? JSONDecoder().decode([[String]].self, from: data) else {
                throw NotesAccessError.unavailable
            }
            if let row = rows.first, row.first == "error" {
                guard row.count == 3, row[2] == "not_applied" else { throw NotesAccessError.unavailable }
                switch row.dropFirst().first {
                case "-1743": throw NotesScriptRejection.permissionRequired
                case "-27001": throw NotesAccessError.folderConflict
                case "-27002": throw NotesScriptRejection.invalidTarget
                case "-27003": throw NotesScriptRejection.unsafeNote
                case "-27004": throw NotesScriptRejection.capacity
                case "-27005": throw NotesScriptRejection.revisionConflict
                default: throw NotesAccessError.unavailable
                }
            }
            return rows
        }.value
    }
}

/// Local scope/ownership ledger contains identifiers and hashes only, never note text or HTML.
actor AppleNotesBackend: NotesBackend {
    private static let maximumNotes = 4096
    private static let pageSize = 100
    nonisolated let isSimulation: Bool
    private let runner: any NotesScriptRunning
    private let storageURL: URL
    private var state: State
    private var connected = false
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private struct Entry: Codable {
        let nativeID: String
        let revision: String
    }
    private struct Pending: Codable {
        let bridgeID: String
        var nativeID: String?
        let expectedTextHash: String
        let expectedHTMLHash: String
        let priorIDs: [String]
    }
    private struct Scope: Codable { let accountID: String; let folderID: String }
    private struct State: Codable {
        var version = 1
        var scope: Scope?
        var entries: [String: Entry] = [:]
        var pending: Pending?
    }
    private struct RawNote {
        let nativeID: String
        let title: String
        let text: String
        let html: String
        let attachmentCount: Int
    }

    init(storageURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
         .appendingPathComponent("Hushlight/Bridge/notes.json"),
         runner: any NotesScriptRunning = AppleNotesScriptRunner()) throws {
        self.runner = runner
        self.isSimulation = runner.isSimulation
        self.storageURL = storageURL
        if FileManager.default.fileExists(atPath: storageURL.path) {
            guard let value = try? JSONDecoder().decode(State.self, from: Data(contentsOf: storageURL)),
                  value.version == 1, value.entries.count <= Self.maximumNotes,
                  value.entries.values.allSatisfy({ !$0.nativeID.isEmpty && $0.revision.count == 64 }),
                  value.scope == nil || (!value.scope!.accountID.isEmpty && !value.scope!.folderID.isEmpty),
                  value.pending == nil || (value.pending!.expectedTextHash.count == 64 && value.pending!.expectedHTMLHash.count == 64 && value.pending!.priorIDs.count <= Self.maximumNotes) else {
                throw NotesAccessError.corruptState
            }
            state = value
        } else { state = State() }
    }

    func isEnabled() async -> Bool {
        await acquire(); defer { release() }
        connected = false
        guard state.scope != nil else { return false }
        if !runner.isSimulation {
            guard await AppleEventPermission.prepareRunningTarget(bundleID: "com.apple.Notes") == .granted else { return false }
        }
        guard let rows = try? await runChecked(request("verify")), rows.count == 1,
              rows[0] == [state.scope!.accountID, state.scope!.folderID] else { return false }
        connected = true
        if state.pending != nil {
            do { try await reconcilePending() } catch { connected = false; return false }
        }
        return true
    }

    /// The persisted folder ID is exposed only after a no-prompt scope verification.
    func scopeIdentifier() async -> String? {
        guard await isEnabled() else { return nil }
        return state.scope?.folderID
    }

    func enable() async throws {
        await acquire(); defer { release() }
        connected = false
        let rows = try await runChecked(request("enable"))
        guard rows.count == 1, rows[0].count == 2, !rows[0][0].isEmpty, !rows[0][1].isEmpty else {
            throw NotesAccessError.unavailable
        }
        if let scope = state.scope {
            guard rows[0] == [scope.accountID, scope.folderID] else { throw NotesAccessError.unavailable }
        } else {
            state.scope = Scope(accountID: rows[0][0], folderID: rows[0][1])
        }
        try persist()
        connected = true
        // Reconcile uncertain writes only inside the saved folder, without reissuing a write.
        if state.pending != nil { try await reconcilePending() }
    }

    func list(query: String) async throws -> [LocalNoteSummary] {
        await acquire(); defer { release() }
        try requireConnected()
        let rows = try await listRows()
        return rows.compactMap { row in
            let id = bridgeID(for: row[0]) ?? row[0]
            guard query.isEmpty || row[1].localizedCaseInsensitiveContains(query) else { return nil }
            return LocalNoteSummary(id: id, title: row[1])
        }
    }

    func read(id: String) async throws -> LocalNoteContent {
        await acquire(); defer { release() }
        try requireConnected()
        return content(try await rawNote(id: id), id: id)
    }

    func create(id: String, title: String, text: String) async throws -> LocalNoteContent {
        await acquire(); defer { release() }
        try requireWritable()
        guard state.entries[id] == nil, state.entries.count < Self.maximumNotes else { throw StableErrorCode.invalidSchema }
        let prior = try await listRows().map { $0[0] }
        let expected = LocalNotesText.canonical(title + "\n" + text)
        var operation = request("create")
        operation.html = Self.html(title + "\n" + text)
        try beginPending(Pending(bridgeID: id, nativeID: nil, expectedTextHash: Self.hash(expected),
                                 expectedHTMLHash: Self.htmlHash(operation.html), priorIDs: prior))
        do {
            let rows = try await runner.run(operation)
            guard rows.count == 1, rows[0].count == 1, !rows[0][0].isEmpty else { throw NotesAccessError.unavailable }
            state.pending?.nativeID = rows[0][0]
            try persist()
            let value = try await rawNativeNote(rows[0][0])
            guard value.title == title, value.text == expected, value.attachmentCount == 0 else {
                throw StableErrorCode.resultUnverifiable
            }
            try commitPending(value)
            return content(value, id: id)
        } catch let rejection as NotesScriptRejection {
            try rejectPending()
            throw rejection.stableCode
        } catch {
            // Once submitted, any error can follow an applied write; retain the journal.
            throw StableErrorCode.resultUnverifiable
        }
    }

    func append(id: String, text: String, expectedRevision: String) async throws -> LocalNoteContent {
        await acquire(); defer { release() }
        try requireWritable()
        guard let entry = state.entries[id] else { throw StableErrorCode.invalidSchema }
        let before = try await rawNativeNote(entry.nativeID)
        guard entry.revision == expectedRevision, Self.hash(before.html) == expectedRevision,
              before.attachmentCount == 0 else { throw StableErrorCode.invalidSchema }
        let expected = LocalNotesText.canonical(before.text + "\n" + text)
        guard expected.count <= 24000 else { throw StableErrorCode.invalidSchema }
        var operation = request("append")
        operation.noteID = entry.nativeID
        operation.expectedHTML = before.html
        operation.html = Self.appendingHTML(text, to: before.html)
        try beginPending(Pending(bridgeID: id, nativeID: entry.nativeID, expectedTextHash: Self.hash(expected),
                                 expectedHTMLHash: Self.htmlHash(operation.html), priorIDs: []))
        do {
            _ = try await runner.run(operation)
            let value = try await rawNativeNote(entry.nativeID)
            guard value.text == expected, value.title == before.title, value.attachmentCount == 0 else {
                throw StableErrorCode.resultUnverifiable
            }
            try commitPending(value)
            return content(value, id: id)
        } catch let rejection as NotesScriptRejection {
            try rejectPending()
            throw rejection.stableCode
        } catch {
            throw StableErrorCode.resultUnverifiable
        }
    }

    private func requireConnected() throws {
        guard connected, state.scope != nil else { throw NotesAccessError.notEnabled }
    }
    private func requireWritable() throws {
        try requireConnected()
        guard state.pending == nil else { throw NotesAccessError.pendingWrite }
    }
    private func request(_ operation: String) -> NotesScriptRequest {
        NotesScriptRequest(operation: operation, accountID: state.scope?.accountID ?? "",
                           folderID: state.scope?.folderID ?? "")
    }
    private func listRows() async throws -> [[String]] {
        var rows: [[String]] = []
        var total: Int?
        repeat {
            var operation = request("list")
            operation.offset = rows.count
            operation.limit = Self.pageSize
            let page = try await runChecked(operation)
            guard let header = page.first, header.count == 2, header[0] == "page",
                  let count = Int(header[1]), count >= 0, count <= Self.maximumNotes,
                  total == nil || total == count,
                  page.count - 1 <= Self.pageSize,
                  page.dropFirst().allSatisfy({ $0.count == 2 && !$0[0].isEmpty && $0[0].count <= 2048 && $0[1].count <= 256 }) else {
                throw NotesAccessError.unavailable
            }
            total = count
            rows.append(contentsOf: page.dropFirst())
            guard rows.count <= count, Set(rows.map { $0[0] }).count == rows.count,
                  page.count > 1 || rows.count == count else { throw NotesAccessError.unavailable }
        } while rows.count < total!
        return rows
    }
    private func rawNote(id: String) async throws -> RawNote {
        try await rawNativeNote(state.entries[id]?.nativeID ?? id)
    }
    private func rawNativeNote(_ nativeID: String) async throws -> RawNote {
        var operation = request("read"); operation.noteID = nativeID
        let rows = try await runChecked(operation)
        guard rows.count == 1, let row = rows.first, row.count == 5, row[0] == nativeID,
              row[1].count <= 256, row[2].count <= 24000, row[3].count <= 128000,
              let attachmentCount = Int(row[4]), attachmentCount >= 0 else { throw NotesAccessError.unavailable }
        return RawNote(nativeID: row[0], title: row[1], text: LocalNotesText.canonical(row[2]), html: row[3], attachmentCount: attachmentCount)
    }
    private func content(_ note: RawNote, id: String) -> LocalNoteContent {
        let revision = Self.hash(note.html)
        return LocalNoteContent(id: id, title: note.title, text: note.text, revision: revision,
                                canAppend: state.pending == nil && state.entries[id]?.revision == revision && note.attachmentCount == 0)
    }
    private func bridgeID(for nativeID: String) -> String? {
        state.entries.first { $0.value.nativeID == nativeID }?.key
    }
    private func commitPending(_ note: RawNote) throws {
        guard let pending = state.pending, Self.hash(note.text) == pending.expectedTextHash,
              Self.htmlHash(note.html) == pending.expectedHTMLHash else {
            throw StableErrorCode.resultUnverifiable
        }
        let previous = state
        state.entries[pending.bridgeID] = Entry(nativeID: note.nativeID, revision: Self.hash(note.html))
        state.pending = nil
        do { try persist() } catch { state = previous; throw error }
    }
    private func reconcilePending() async throws {
        guard let pending = state.pending else { return }
        let candidates: [String]
        if let nativeID = pending.nativeID { candidates = [nativeID] }
        else { candidates = try await listRows().map { $0[0] }.filter { !pending.priorIDs.contains($0) } }
        var matches: [RawNote] = []
        for nativeID in candidates {
            if let note = try? await rawNativeNote(nativeID), note.attachmentCount == 0,
               Self.hash(note.text) == pending.expectedTextHash,
               Self.htmlHash(note.html) == pending.expectedHTMLHash { matches.append(note) }
        }
        guard matches.count == 1, let note = matches.first else { throw NotesAccessError.pendingWrite }
        try commitPending(note)
    }
    private func runChecked(_ operation: NotesScriptRequest) async throws -> [[String]] {
        do { return try await runner.run(operation) }
        catch let rejection as NotesScriptRejection { throw rejection.stableCode }
    }
    private func beginPending(_ pending: Pending) throws {
        let previous = state
        state.pending = pending
        do { try persist() } catch { state = previous; throw error }
    }
    private func rejectPending() throws {
        let previous = state
        state.pending = nil
        do { try persist() } catch { state = previous; throw StableErrorCode.resultUnverifiable }
    }
    // Notes may pretty-print separators; styles, tags and attributes remain significant.
    private static func htmlHash(_ html: String) -> String {
        let normalized = html.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "</div>[\\t\\r\\n ]+(?=<div>)", with: "</div>", options: .regularExpression)
        return hash(normalized)
    }

    private func persist() throws {
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(state)
        try data.write(to: storageURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
    }
    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func html(_ text: String) -> String {
        LocalNotesText.canonical(text).components(separatedBy: "\n").map { line in
            let escaped = line.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
            return "<div>" + (escaped.isEmpty ? "<br>" : escaped) + "</div>"
        }.joined()
    }
    static func appendingHTML(_ text: String, to html: String) -> String {
        let fragment = Self.html(text)
        if let range = html.range(of: "</body>", options: .caseInsensitive) {
            return String(html[..<range.lowerBound]) + fragment + String(html[range.lowerBound...])
        }
        return html + fragment
    }
    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
