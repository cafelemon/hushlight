import Foundation
import CryptoKit
import BridgeCore

struct MailScopeKey: Codable, Equatable, Sendable {
    let accountID: String
    let mailboxPath: [String]

    var scopeID: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let bytes = try! encoder.encode(self)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct MailScopeOption: Equatable, Identifiable, Sendable {
    let key: MailScopeKey
    let accountName: String
    let accountAddresses: [String]

    var id: String { ([key.accountID] + key.mailboxPath).joined(separator: "\u{0}") }
    var displayName: String {
        let address = accountAddresses.first.map { " (" + $0 + ")" } ?? ""
        return accountName + address + " / " + key.mailboxPath.joined(separator: " / ")
    }
}

enum MailScopeError: LocalizedError {
    case requiresApp, unavailable, permissionRequired, invalidScope, tooManyMailboxes, corruptState
    case capacityExceeded, messageUnavailable, invalidMessageID, invalidResponse

    var errorDescription: String? {
        switch self {
        case .requiresApp: "请在 Orbit 智轨 App 中连接 Apple Mail。"
        case .unavailable: "无法核对 Apple Mail 账户与邮箱，请检查 Mail 和自动化权限。"
        case .permissionRequired: "请允许 Orbit 智轨控制 Apple Mail。"
        case .invalidScope: "所选邮箱已不存在、名称改变或不再唯一，请重新选择。"
        case .tooManyMailboxes: "邮箱数量或层级超过本版支持范围，无法完整核对，未选择任何新邮箱。"
        case .corruptState: "邮箱范围记录损坏，已停止连接；原文件已保留。"
        case .capacityExceeded: "邮箱邮件数量或搜索结果超过本版支持范围，请缩小邮箱或查询范围。"
        case .messageUnavailable: "该邮件已不存在或不在当前所选邮箱中。"
        case .invalidMessageID: "邮件标识与当前所选邮箱不匹配。"
        case .invalidResponse: "Apple Mail 返回的数据无法核对。"
        }
    }

    var stableCode: StableErrorCode {
        switch self {
        case .permissionRequired: .permissionRequired
        case .invalidScope, .corruptState, .requiresApp, .capacityExceeded, .tooManyMailboxes: .capabilityDisabled
        case .invalidMessageID, .messageUnavailable: .invalidSchema
        case .unavailable, .invalidResponse: .resultUnverifiable
        }
    }
}

protocol MailScopeScriptRunning: Sendable {
    func run(operation: String, scope: MailScopeKey?) async throws -> [[String]]
    func run(operation: String, scope: MailScopeKey, query: String, unreadOnly: Bool, messageID: String) async throws -> [[String]]
    func incremental(scope: MailScopeKey, since: Date, until: Date, afterID: UInt64) async throws -> [[String]]
}

extension MailScopeScriptRunning {
    func run(operation: String, scope: MailScopeKey, query: String, unreadOnly: Bool, messageID: String) async throws -> [[String]] {
        throw MailScopeError.unavailable
    }
    func incremental(scope: MailScopeKey, since: Date, until: Date, afterID: UInt64) async throws -> [[String]] {
        throw MailScopeError.unavailable
    }
}

struct MailIncrementalWindow: Codable, Equatable, Sendable {
    let since: Date
    let until: Date
    let afterID: UInt64
}

/// The caller persists this only after it has durably accepted every message in a poll.
struct MailIncrementalSeen: Codable, Equatable, Sendable {
    let id: String
    let receivedAt: Date
}

struct MailIncrementalCursor: Codable, Equatable, Sendable {
    let scopeID: String
    let baselineAt: Date
    let watermark: Date
    let recent: [MailIncrementalSeen]
    var pending: MailIncrementalWindow? = nil
}

struct MailIncrementalPoll: Sendable {
    let messages: [LocalMailSummary]
    let nextCursor: MailIncrementalCursor
    let hasMore: Bool
}

/// Fixed bundled script, with values passed as JSON on stdin. It never receives executable source.
struct AppleMailScopeScriptRunner: MailScopeScriptRunning {
    func run(operation: String, scope: MailScopeKey?) async throws -> [[String]] {
        try await execute(operation: operation, scope: scope, query: "", unreadOnly: false, messageID: "")
    }

    func run(operation: String, scope: MailScopeKey, query: String, unreadOnly: Bool, messageID: String) async throws -> [[String]] {
        try await execute(operation: operation, scope: scope, query: query, unreadOnly: unreadOnly, messageID: messageID)
    }

    func incremental(scope: MailScopeKey, since: Date, until: Date, afterID: UInt64) async throws -> [[String]] {
        try await execute(operation: "incremental", scope: scope, query: "", unreadOnly: false,
                          messageID: "", sinceEpoch: since.timeIntervalSince1970,
                          untilEpoch: until.timeIntervalSince1970, afterID: afterID)
    }

    private func execute(operation: String, scope: MailScopeKey?, query: String, unreadOnly: Bool,
                         messageID: String, sinceEpoch: TimeInterval = 0,
                         untilEpoch: TimeInterval = 0, afterID: UInt64 = 0) async throws -> [[String]] {
        guard Bundle.main.bundleIdentifier == "com.hushlight.bridge.mac",
              let script = Bundle.module.url(forResource: "MailScopeBridge", withExtension: "applescript") else {
            throw MailScopeError.requiresApp
        }
        struct Input: Encodable {
            let operation: String
            let accountID: String
            let mailboxPath: [String]
            let query: String
            let unreadOnly: Bool
            let messageID: String
            let sinceEpoch: TimeInterval
            let untilEpoch: TimeInterval
            let afterID: String
        }
        if (BridgeExecutionContext.backgroundAutomation || BridgeExecutionContext.callerID != "local_ui"), AppleEventPermission.status(bundleID: "com.apple.mail") != .granted { throw MailScopeError.permissionRequired }
        let input = try JSONEncoder().encode(Input(operation: operation, accountID: scope?.accountID ?? "",
                                                   mailboxPath: scope?.mailboxPath ?? [], query: query,
                                                   unreadOnly: unreadOnly, messageID: messageID,
                                                   sinceEpoch: sinceEpoch, untilEpoch: untilEpoch,
                                                   afterID: String(afterID)))
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [script.path]
            let stdin = Pipe(), stdout = Pipe()
            guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw MailScopeError.unavailable
            }
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + 25)
            timer.setEventHandler {
                if process.isRunning {
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
            try process.run()
            timer.resume()
            defer { timer.cancel() }
            do { try stdin.fileHandleForWriting.write(contentsOf: input) }
            catch { process.terminate(); throw MailScopeError.unavailable }
            try? stdin.fileHandleForWriting.close()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, data.count <= 256_000,
                  let rows = try? JSONDecoder().decode([[String]].self, from: data) else {
                throw MailScopeError.unavailable
            }
            if let first = rows.first, first.first == "error" {
                switch first.dropFirst().first {
                case "-1743": throw MailScopeError.permissionRequired
                case "-27102": throw MailScopeError.invalidScope
                case "-27104": throw MailScopeError.tooManyMailboxes
                case "-27105": throw MailScopeError.capacityExceeded
                case "-27106": throw MailScopeError.messageUnavailable
                default: throw MailScopeError.unavailable
                }
            }
            return rows
        }.value
    }
}

/// Persists only the account identifier and complete mailbox path, never messages or addresses.
actor AppleMailScopeBackend: MailReadingBackend {
    nonisolated let isSimulation = false
    private let runner: any MailScopeScriptRunning
    private let storageURL: URL
    private var selected: MailScopeKey?
    private var corrupt = false

    init(storageURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hushlight/Bridge/mail-scope.json"),
         runner: any MailScopeScriptRunning = AppleMailScopeScriptRunner()) {
        self.runner = runner
        self.storageURL = storageURL
        if FileManager.default.fileExists(atPath: storageURL.path) {
            do {
                let key = try JSONDecoder().decode(MailScopeKey.self, from: Data(contentsOf: storageURL))
                guard Self.valid(key) else { throw MailScopeError.corruptState }
                selected = key
            }
            catch { corrupt = true }
        }
    }

    func selectedScope() throws -> MailScopeKey? {
        guard !corrupt else { throw MailScopeError.corruptState }
        return selected
    }

    func scopeID() throws -> String? {
        do { return try selectedScope()?.scopeID }
        catch let error as MailScopeError { throw error.stableCode }
        catch { throw StableErrorCode.resultUnverifiable }
    }

    func search(query: String, unreadOnly: Bool) async throws -> [LocalMailSummary] {
        do { return try await searchSelectedScope(query: query, unreadOnly: unreadOnly) }
        catch let error as MailScopeError { throw error.stableCode }
        catch let error as StableErrorCode { throw error }
        catch { throw StableErrorCode.resultUnverifiable }
    }

    private func searchSelectedScope(query: String, unreadOnly: Bool) async throws -> [LocalMailSummary] {
        guard query.count <= 256 else { throw MailScopeError.invalidResponse }
        let key = try activeReadScope()
        let rows = try await runner.run(operation: "search", scope: key, query: query,
                                        unreadOnly: unreadOnly, messageID: "")
        try checkReadScope(key)
        guard rows.count <= 50 else { throw MailScopeError.capacityExceeded }
        var seen = Set<String>()
        return try rows.map { row in
            let item = try Self.parseMessage(row, scope: key)
            guard seen.insert(item.id).inserted else { throw MailScopeError.invalidResponse }
            return item
        }
    }

    func read(id: String) async throws -> LocalMailContent {
        do { return try await readSelectedScope(id: id) }
        catch let error as MailScopeError { throw error.stableCode }
        catch let error as StableErrorCode { throw error }
        catch { throw StableErrorCode.resultUnverifiable }
    }

    /// Called when a monitor rule is enabled. A fresh rule starts at this instant.
    func makeIncrementalBaseline(now: Date = Date()) throws -> MailIncrementalCursor {
        let key = try activeReadScope()
        guard now.timeIntervalSince1970.isFinite else { throw MailScopeError.invalidResponse }
        return MailIncrementalCursor(scopeID: key.scopeID, baselineAt: now,
                                     watermark: now, recent: [])
    }

    /// Pure read. The caller owns durable acknowledgement of nextCursor.
    func pollIncremental(after cursor: MailIncrementalCursor, now: Date = Date()) async throws -> MailIncrementalPoll {
        let key = try activeReadScope()
        guard cursor.scopeID == key.scopeID,
              cursor.baselineAt <= cursor.watermark,
              cursor.recent.count <= 20_000,
              Set(cursor.recent.map(\.id)).count == cursor.recent.count,
              cursor.recent.allSatisfy({ $0.receivedAt > cursor.baselineAt }),
              cursor.pending.map({ $0.since >= cursor.baselineAt.addingTimeInterval(-120) &&
                  $0.until >= cursor.watermark && $0.until >= $0.since }) ?? true else {
            throw MailScopeError.invalidScope
        }
        let started = now
        guard started >= cursor.baselineAt else { throw MailScopeError.invalidResponse }
        let window = cursor.pending ?? MailIncrementalWindow(
            since: max(cursor.baselineAt.addingTimeInterval(-120), cursor.watermark.addingTimeInterval(-120)),
            until: max(cursor.watermark, started), afterID: 0)
        guard window.until <= started else { throw MailScopeError.invalidResponse }
        let response = try await runner.incremental(scope: key, since: window.since,
                                                     until: window.until, afterID: window.afterID)
        try checkReadScope(key)
        guard let marker = response.first, marker.count == 2, marker[0] == "page",
              marker[1] == "0" || marker[1] == "1" else { throw MailScopeError.invalidResponse }
        let hasMore = marker[1] == "1"
        let rows = Array(response.dropFirst())
        guard rows.count <= 10, !hasMore || rows.count == 10 else { throw MailScopeError.invalidResponse }
        var seen = Set<String>()
        let parsed = try rows.map { row -> LocalMailSummary in
            let message = try Self.parseMessage(row, scope: key)
            guard seen.insert(message.id).inserted else { throw MailScopeError.invalidResponse }
            return message
        }
        let ids = try parsed.map { message -> UInt64 in
            let id = try Self.nativeMessageID(message.id, scope: key)
            guard let value = UInt64(id), value > window.afterID else { throw MailScopeError.invalidResponse }
            return value
        }
        guard ids == ids.sorted() else { throw MailScopeError.invalidResponse }
        let previous = Set(cursor.recent.map(\.id))
        let fresh = parsed.filter { $0.receivedAt > cursor.baselineAt && !previous.contains($0.id) }
            .sorted { $0.receivedAt == $1.receivedAt ? $0.id < $1.id : $0.receivedAt < $1.receivedAt }
        let nextWatermark = hasMore ? cursor.watermark : window.until
        let nextCutoff = max(cursor.baselineAt.addingTimeInterval(-120), nextWatermark.addingTimeInterval(-120))
        var retained = cursor.recent.filter { $0.receivedAt > nextCutoff }
        for message in parsed where message.receivedAt > cursor.baselineAt &&
            message.receivedAt > nextCutoff && !previous.contains(message.id) {
            retained.append(MailIncrementalSeen(id: message.id, receivedAt: message.receivedAt))
        }
        guard retained.count <= 20_000 else { throw MailScopeError.capacityExceeded }
        var next = MailIncrementalCursor(scopeID: key.scopeID, baselineAt: cursor.baselineAt,
                                         watermark: nextWatermark, recent: retained)
        if hasMore {
            next.pending = MailIncrementalWindow(since: window.since, until: window.until,
                                                 afterID: ids.last!)
        }
        return MailIncrementalPoll(messages: fresh, nextCursor: next, hasMore: hasMore)
    }

    private func readSelectedScope(id: String) async throws -> LocalMailContent {
        let key = try activeReadScope()
        let nativeID = try Self.nativeMessageID(id, scope: key)
        let rows = try await runner.run(operation: "read", scope: key, query: "",
                                        unreadOnly: false, messageID: nativeID)
        try checkReadScope(key)
        guard rows.count == 1, rows[0].count == 6 else { throw MailScopeError.invalidResponse }
        let message = try Self.parseMessage(Array(rows[0].prefix(5)), scope: key)
        guard message.id == id, rows[0][5].count <= 24_000 else { throw MailScopeError.invalidResponse }
        return LocalMailContent(message: message, text: rows[0][5])
    }

    private func activeReadScope() throws -> MailScopeKey {
        guard let key = try selectedScope() else { throw MailScopeError.invalidScope }
        try checkReadScope(key)
        return key
    }

    private func checkReadScope(_ key: MailScopeKey) throws {
        guard !corrupt, selected == key,
              BridgeExecutionContext.mailScopeID == nil || BridgeExecutionContext.mailScopeID == key.scopeID else {
            throw MailScopeError.invalidScope
        }
    }

    private static func nativeMessageID(_ id: String, scope: MailScopeKey) throws -> String {
        let prefix = "mail." + scope.scopeID + "."
        guard id.hasPrefix(prefix) else { throw MailScopeError.invalidMessageID }
        let nativeID = String(id.dropFirst(prefix.count))
        guard let number = UInt64(nativeID), number > 0, String(number) == nativeID else {
            throw MailScopeError.invalidMessageID
        }
        return nativeID
    }

    private static func parseMessage(_ row: [String], scope: MailScopeKey) throws -> LocalMailSummary {
        guard row.count == 5,
              let number = UInt64(row[0]), number > 0, String(number) == row[0],
              row[1].count <= 512, row[2].count <= 512,
              let epoch = Double(row[3]), epoch.isFinite, epoch > 0,
              row[4] == "0" || row[4] == "1" else { throw MailScopeError.invalidResponse }
        return LocalMailSummary(id: "mail." + scope.scopeID + "." + row[0],
                                subject: row[1], sender: row[2],
                                receivedAt: Date(timeIntervalSince1970: epoch), isUnread: row[4] == "1")
    }

    func availableScopes() async throws -> [MailScopeOption] {
        guard !corrupt else { throw MailScopeError.corruptState }
        let rows = try await runner.run(operation: "list", scope: nil)
        guard rows.count <= 200 else { throw MailScopeError.tooManyMailboxes }
        let options = try rows.map(Self.parse)
        guard Set(options.map(\.id)).count == options.count else { throw MailScopeError.invalidScope }
        return options.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func choose(_ key: MailScopeKey) async throws {
        guard !corrupt else { throw MailScopeError.corruptState }
        guard Self.valid(key) else { throw MailScopeError.invalidScope }
        let options = try await availableScopes()
        guard options.contains(where: { $0.key == key }) else { throw MailScopeError.invalidScope }
        // Re-resolve the exact account and each mailbox component just before saving it.
        let verification = try await runner.run(operation: "verify", scope: key)
        guard verification.count == 1, try Self.parse(verification[0]).key == key else {
            throw MailScopeError.invalidScope
        }
        let data = try JSONEncoder().encode(key)
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: storageURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        selected = key
    }

    private static func valid(_ key: MailScopeKey) -> Bool {
        !key.accountID.isEmpty && key.accountID.count <= 512 &&
        (1...8).contains(key.mailboxPath.count) && key.mailboxPath.allSatisfy { !$0.isEmpty && $0.count <= 256 }
    }

    private static func parse(_ row: [String]) throws -> MailScopeOption {
        guard row.count >= 4, row.count <= 11,
              !row[0].isEmpty, row[0].count <= 512,
              !row[1].isEmpty, row[1].count <= 256,
              row[2].count <= 2_048,
              row.dropFirst(3).allSatisfy({ !$0.isEmpty && $0.count <= 256 }) else {
            throw MailScopeError.invalidScope
        }
        let addresses = row[2].split(separator: "\u{1f}").map(String.init)
        guard addresses.count <= 10, addresses.allSatisfy({ $0.count <= 256 }) else { throw MailScopeError.invalidScope }
        return MailScopeOption(key: .init(accountID: row[0], mailboxPath: Array(row.dropFirst(3))),
                               accountName: row[1], accountAddresses: addresses)
    }
}
