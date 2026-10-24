import BridgeCore
import CryptoKit
import Foundation

/// One invocation of the fixed, bundled Mail script. Values are JSON on stdin.
struct MailDraftScriptRequest: Encodable, Sendable {
    let operation: String
    let accountID: String
    let mailboxPath: [String]
    let nativeID: String
    let sender: String
    let to: [String]
    let cc: [String]
    let bcc: [String]
    let subject: String
    let text: String
}

protocol MailDraftScriptRunning: Sendable {
    func run(_ request: MailDraftScriptRequest) async throws -> [[String]]
}

struct AppleMailDraftScriptRunner: MailDraftScriptRunning {
    func run(_ request: MailDraftScriptRequest) async throws -> [[String]] {
        guard Bundle.main.bundleIdentifier == "com.hushlight.bridge.mac",
              let script = Bundle.module.url(forResource: "MailDraftBridge", withExtension: "applescript") else {
            throw StableErrorCode.capabilityDisabled
        }
        if (BridgeExecutionContext.backgroundAutomation || BridgeExecutionContext.callerID != "local_ui"), AppleEventPermission.status(bundleID: "com.apple.mail") != .granted { throw StableErrorCode.permissionRequired }
        let input = try JSONEncoder().encode(request)
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [script.path]
            let stdin = Pipe(), stdout = Pipe()
            guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw StableErrorCode.resultUnverifiable
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
            do { try process.run() }
            catch { throw StableErrorCode.resultUnverifiable }
            timeout.resume()
            defer { timeout.cancel() }
            do { try stdin.fileHandleForWriting.write(contentsOf: input) }
            catch { process.terminate(); throw StableErrorCode.resultUnverifiable }
            try? stdin.fileHandleForWriting.close()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, data.count <= 128_000,
                  let rows = try? JSONDecoder().decode([[String]].self, from: data), rows.count == 1 else {
                throw StableErrorCode.resultUnverifiable
            }
            if rows[0].first == "error" {
                // Script errors carry only a numeric code and whether the operation was certainly not applied.
                guard rows[0].count == 3, rows[0][2] == "not_applied" else {
                    throw StableErrorCode.resultUnverifiable
                }
                switch rows[0][1] {
                case "-1743": throw StableErrorCode.permissionRequired
                case "-27120", "-27121", "-27122": throw StableErrorCode.invalidSchema
                case "-27123": throw StableErrorCode.capabilityDisabled
                default: throw StableErrorCode.resultUnverifiable
                }
            }
            return rows
        }.value
    }
}

/// No retries here: the caller owns the durable at-most-once send ledger.
struct AppleMailDraftBackend: MailDraftNativeDriving {
    private let runner: any MailDraftScriptRunning

    init(runner: any MailDraftScriptRunning = AppleMailDraftScriptRunner()) {
        self.runner = runner
    }

    func create(scope: MailScopeKey, input: MailDraftInput) async throws -> MailDraftContent {
        try Self.validate(scope: scope, input: input)
        let rows = try await runner.run(Self.request("create", scope: scope, nativeID: "", input: input))
        return try Self.parse(rows, scope: scope, expected: input)
    }

    func read(scope: MailScopeKey, id: String) async throws -> MailDraftContent {
        let nativeID = try Self.nativeID(id, scope: scope)
        let rows = try await runner.run(Self.request("read", scope: scope, nativeID: nativeID,
                                                     input: .init(sender: "", to: [], cc: [], bcc: [], subject: "", text: "")))
        return try Self.parse(rows, scope: scope)
    }

    func send(scope: MailScopeKey, draft: MailDraftContent) async throws -> MailSendNativeOutcome {
        let nativeID = try Self.nativeID(draft.id, scope: scope)
        guard draft.scopeID == scope.scopeID else { throw StableErrorCode.invalidSchema }
        let input = MailDraftInput(sender: draft.sender, to: draft.to, cc: draft.cc, bcc: draft.bcc,
                                   subject: draft.subject, text: draft.text)
        try Self.validate(scope: scope, input: input)
        guard draft.revision == Self.revision(input) else { throw StableErrorCode.invalidSchema }
        let rows = try await runner.run(Self.request("send", scope: scope, nativeID: nativeID, input: input))
        guard rows.count == 1, rows[0].count == 2, rows[0][0] == "status" else {
            throw StableErrorCode.resultUnverifiable
        }
        switch rows[0][1] {
        case "submitted": return .submitted
        case "unknown": return .unknown
        default: throw StableErrorCode.resultUnverifiable
        }
    }

    private static func request(_ operation: String, scope: MailScopeKey, nativeID: String,
                                input: MailDraftInput) -> MailDraftScriptRequest {
        .init(operation: operation, accountID: scope.accountID, mailboxPath: scope.mailboxPath,
              nativeID: nativeID, sender: input.sender, to: input.to, cc: input.cc, bcc: input.bcc,
              subject: input.subject, text: input.text)
    }

    private static func nativeID(_ id: String, scope: MailScopeKey) throws -> String {
        let prefix = "mail.draft.\(scope.scopeID)."
        guard id.hasPrefix(prefix) else { throw StableErrorCode.invalidSchema }
        let raw = String(id.dropFirst(prefix.count))
        guard let value = UInt64(raw), value > 0, String(value) == raw else { throw StableErrorCode.invalidSchema }
        return raw
    }

    private static func validate(scope: MailScopeKey, input: MailDraftInput) throws {
        guard !scope.accountID.isEmpty, scope.accountID.count <= 512,
              (1...8).contains(scope.mailboxPath.count),
              scope.mailboxPath.allSatisfy({ !$0.isEmpty && $0.count <= 256 }),
              !input.sender.isEmpty, input.sender.count <= 256,
              !input.to.isEmpty, input.to.count + input.cc.count + input.bcc.count <= 20,
              input.subject.count <= 512, !input.subject.contains("\n"), !input.subject.contains("\r"),
              input.text.count <= 24_000,
              ([input.sender] + input.to + input.cc + input.bcc).allSatisfy(validAddress) else {
            throw StableErrorCode.invalidSchema
        }
    }

    private static func validAddress(_ address: String) -> Bool {
        address.count <= 254 && address.split(separator: "@", omittingEmptySubsequences: false).count == 2 &&
        address.split(separator: "@", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }) &&
        !address.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) ||
            CharacterSet.controlCharacters.contains($0) || "<>;,".unicodeScalars.contains($0) })
    }

    private static func parse(_ rows: [[String]], scope: MailScopeKey,
                              expected: MailDraftInput? = nil) throws -> MailDraftContent {
        guard rows.count == 1, rows[0].count == 8 else { throw StableErrorCode.resultUnverifiable }
        let row = rows[0]
        guard let value = UInt64(row[0]), value > 0, String(value) == row[0],
              row[7] == "0" else { throw StableErrorCode.resultUnverifiable }
        let input = MailDraftInput(sender: row[1], to: split(row[2]), cc: split(row[3]),
                                   bcc: split(row[4]), subject: row[5], text: row[6])
        do { try validate(scope: scope, input: input) }
        catch { throw StableErrorCode.resultUnverifiable }
        if let expected, input != expected { throw StableErrorCode.resultUnverifiable }
        return .init(id: "mail.draft.\(scope.scopeID).\(row[0])", scopeID: scope.scopeID,
                     sender: input.sender, to: input.to, cc: input.cc, bcc: input.bcc,
                     subject: input.subject, text: input.text, revision: revision(input))
    }

    private static func split(_ value: String) -> [String] {
        value.isEmpty ? [] : value.components(separatedBy: "\u{1f}")
    }

    static func revision(_ input: MailDraftInput) -> String {
        // JSONEncoder's sorted keys make this deterministic across processes and restarts.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try! encoder.encode(input)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
