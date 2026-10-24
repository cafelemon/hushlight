import Foundation
import BridgeCore
import CryptoKit
import Darwin

protocol MailDraftNativeDriving: Sendable {
    func create(scope: MailScopeKey, input: MailDraftInput) async throws -> MailDraftContent
    func read(scope: MailScopeKey, id: String) async throws -> MailDraftContent
    func send(scope: MailScopeKey, draft: MailDraftContent) async throws -> MailSendNativeOutcome
}

struct MailDraftEntry: Codable, Identifiable, Sendable {
    let id: String
    let owner: String
    let scopeID: String
    let inputHash: String
    var nativeID: String?
    var revision: String?
    var state: String
    var requestedAt: Date?
    var error: String?
}

/// Durable entries contain identifiers, hashes and states only. Native Mail owns message text.
actor MailDraftWorkflow: MailDraftBackend {
    nonisolated let isSimulation: Bool
    private let scope: AppleMailScopeBackend
    private let driver: any MailDraftNativeDriving
    private let storageURL: URL
    private var entries: [MailDraftEntry] = []
    private var corrupt = false
    private var paused: Bool

    init(scope: AppleMailScopeBackend, driver: any MailDraftNativeDriving = AppleMailDraftBackend(),
         storageURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hushlight/Bridge/mail-drafts.json"), isSimulation: Bool = false, paused: Bool = false) {
        self.scope = scope; self.driver = driver; self.storageURL = storageURL; self.isSimulation = isSimulation
        self.paused = paused
        if FileManager.default.fileExists(atPath: storageURL.path) {
            do {
                entries = try JSONDecoder().decode([MailDraftEntry].self, from: Data(contentsOf: storageURL))
                for index in entries.indices where ["creating", "dispatching"].contains(entries[index].state) {
                    entries[index].state = "unknown"
                    entries[index].error = "result_unverifiable"
                }
            } catch { corrupt = true }
        }
    }

    func list() throws -> [MailDraftEntry] {
        guard !corrupt else { throw StableErrorCode.capabilityDisabled }
        return entries
    }
    func setPaused(_ value: Bool) { paused = value }

    private func currentScope() async throws -> MailScopeKey {
        guard !paused else { throw StableErrorCode.bridgePaused }
        guard !corrupt, let key = try await scope.selectedScope() else { throw StableErrorCode.capabilityDisabled }
        guard !paused else { throw StableErrorCode.bridgePaused }
        guard BridgeExecutionContext.mailScopeID == nil || BridgeExecutionContext.mailScopeID == key.scopeID else { throw StableErrorCode.permissionRequired }
        return key
    }

    private func index(_ id: String, scopeID: String) throws -> Int {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].scopeID == scopeID,
              BridgeExecutionContext.callerID == "local_ui" || entries[index].owner == BridgeExecutionContext.callerID else {
            throw StableErrorCode.permissionRequired
        }
        return index
    }

    func createDraft(id: String, input: MailDraftInput) async throws -> MailDraftContent {
        try input.validate()
        let key = try await currentScope()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let digest = SHA256.hash(data: try encoder.encode(input)).map { String(format: "%02x", $0) }.joined()
        if entries.contains(where: { $0.id == id }) {
            let i = try index(id, scopeID: key.scopeID)
            guard entries[i].inputHash == digest else { throw StableErrorCode.replayDetected }
            guard entries[i].state == "draft" else { throw StableErrorCode.resultUnverifiable }
            return try await readDraft(id: id)
        }
        guard entries.count < 1_000 else { throw StableErrorCode.capabilityDisabled }
        entries.append(.init(id: id, owner: BridgeExecutionContext.callerID, scopeID: key.scopeID,
                             inputHash: digest, state: "creating"))
        try persist()
        let i = entries.count - 1
        do {
            let native = try await driver.create(scope: key, input: input)
            guard native.scopeID == key.scopeID, native.input == input else { throw StableErrorCode.resultUnverifiable }
            entries[i].nativeID = native.id; entries[i].revision = native.revision; entries[i].state = "draft"
            try persist()
            guard try await currentScope() == key else { throw StableErrorCode.permissionRequired }
            return Self.publicDraft(native, id: id)
        } catch {
            if entries[i].state == "creating" { entries[i].state = "unknown"; entries[i].error = "result_unverifiable"; try? persist() }
            throw error
        }
    }

    func readDraft(id: String) async throws -> MailDraftContent {
        let key = try await currentScope()
        let i = try index(id, scopeID: key.scopeID)
        guard ["draft", "awaiting_confirmation"].contains(entries[i].state), let nativeID = entries[i].nativeID else { throw StableErrorCode.resultUnverifiable }
        let value = try await driver.read(scope: key, id: nativeID)
        guard try await currentScope() == key, value.id == nativeID, value.scopeID == key.scopeID else { throw StableErrorCode.permissionRequired }
        return Self.publicDraft(value, id: id)
    }

    func requestSend(id: String, revision: String) async throws {
        let value = try await readDraft(id: id)
        let i = try index(id, scopeID: value.scopeID)
        guard value.revision == revision, entries[i].state == "draft" || entries[i].state == "awaiting_confirmation" else { throw StableErrorCode.invalidSchema }
        if entries[i].state == "awaiting_confirmation", entries[i].revision == revision,
           BridgeExecutionContext.callerID != "local_ui" { return }
        entries[i].revision = revision
        entries[i].state = "awaiting_confirmation"
        entries[i].requestedAt = Date()
        try persist()
    }

    func draftStatus(id: String) async throws -> String {
        let key = try await currentScope()
        return entries[try index(id, scopeID: key.scopeID)].state
    }

    /// Only App UI calls this after presenting the exact native draft snapshot.
    func confirmSend(id: String, preview: MailDraftContent, authorize: @escaping @Sendable () async -> Bool) async throws -> String {
        guard BridgeExecutionContext.callerID == "local_ui", preview.id == id else { throw StableErrorCode.permissionRequired }
        let key = try await currentScope()
        let i = try index(id, scopeID: key.scopeID)
        guard entries[i].state == "awaiting_confirmation", entries[i].revision == preview.revision,
              let requestedAt = entries[i].requestedAt, Date().timeIntervalSince(requestedAt) < 600,
              let nativeID = entries[i].nativeID else { throw StableErrorCode.confirmationExpired }
        let current = try await driver.read(scope: key, id: nativeID)
        guard entries[i].state == "awaiting_confirmation", Self.publicDraft(current, id: id) == preview,
              try await currentScope() == key else { throw StableErrorCode.confirmationRequired }
        // Host serializes the final authorization decision against revoke/grant changes.
        // This permit is the send admission point; no further awaits precede the durable claim.
        guard await authorize() else { throw StableErrorCode.permissionRequired }
        // Persist admission before the external send: restarts and uncertain outcomes never replay it.
        guard entries[i].state == "awaiting_confirmation" else { throw StableErrorCode.confirmationUsed }
        guard !paused else { throw StableErrorCode.bridgePaused }
        guard entries[i].revision == preview.revision, let requested = entries[i].requestedAt,
              Date().timeIntervalSince(requested) < 600 else { throw StableErrorCode.confirmationExpired }
        entries[i].state = "dispatching"
        try persist()
        do {
            let result = try await driver.send(scope: key, draft: current)
            entries[i].state = result.rawValue
            entries[i].error = result == .unknown ? "result_unverifiable" : nil
            do { try persist() } catch { entries[i].state = "unknown"; throw StableErrorCode.resultUnverifiable }
            return entries[i].state
        } catch {
            entries[i].state = "unknown"; entries[i].error = "result_unverifiable"; try? persist()
            throw StableErrorCode.resultUnverifiable
        }
    }

    private static func publicDraft(_ native: MailDraftContent, id: String) -> MailDraftContent {
        .init(id: id, scopeID: native.scopeID, sender: native.sender, to: native.to, cc: native.cc, bcc: native.bcc,
              subject: native.subject, text: native.text, revision: native.revision)
    }
    private func persist() throws {
        guard !corrupt else { throw StableErrorCode.capabilityDisabled }
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(entries)
        let temporary = directory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard rename(temporary.path, storageURL.path) == 0 else { throw StableErrorCode.internalError }
        let directoryFD = open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else { throw StableErrorCode.internalError }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw StableErrorCode.internalError }
    }
}
