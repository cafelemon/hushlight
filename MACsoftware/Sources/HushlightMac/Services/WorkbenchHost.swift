import Foundation
import Darwin
import BridgeCore
import WorkbenchKit
import CryptoKit

private typealias JSONValue = WorkbenchKit.JSONValue

enum WorkbenchGrant: String, Codable, CaseIterable, Sendable, Hashable {
    case automationWorker = "automation.worker"
    case automationRead = "automation.read"
    case musicRead = "music.read", musicPlaybackRead = "music.playback.read", musicWrite = "music.write"
    case volumeRead = "volume.read", timerRead = "timer.read", timerWrite = "timer.write"
    case reminderRead = "reminder.read", reminderWrite = "reminder.write"
    case calendarRead = "calendar.read", calendarWrite = "calendar.write"
    case noteRead = "note.read", noteWrite = "note.write"
    case weatherRead = "weather.read", locationRead = "location.read"
    case mailRead = "mail.read", mailWrite = "mail.write", mailSendRequest = "mail.send.request"
}

struct WorkbenchClientCredential: Sendable {
    let id: String
    let name: String
    let credential: String
}

struct WorkbenchClientRecord: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    var grants: Set<WorkbenchGrant>
    var revoked: Bool
    let createdAt: Date
    var mailScopeID: String? = nil
    var calendarScopeID: String? = nil
}

struct WorkbenchHistoryEntry: Codable, Sendable, Identifiable {
    let id: String
    let clientID: String
    let action: String
    var status: String
    var error: String?
    let occurredAt: Date
}

private struct WorkbenchJournalEntry: Codable {
    let requestID: String
    let clientID: String
    let action: String
    let fingerprint: String
    var isSimulation: Bool? = nil
    var status: String
    var error: String?
    let occurredAt: Date
}

private struct WorkbenchDiskState: Codable {
    var clients: [WorkbenchClientRecord] = []
    var journal: [WorkbenchJournalEntry] = []
    var archive: [WorkbenchHistoryEntry] = []

    private enum CodingKeys: String, CodingKey { case clients, journal, archive }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clients = try container.decode([WorkbenchClientRecord].self, forKey: .clients)
        journal = try container.decode([WorkbenchJournalEntry].self, forKey: .journal)
        archive = try container.decodeIfPresent([WorkbenchHistoryEntry].self, forKey: .archive) ?? []
    }
}

enum WorkbenchHostError: Error { case invalidName, missingClient, storage, alreadyRunning, socket, mailScopeMissing, calendarScopeMissing }

/// Owns the only local Workbench socket. The app supplies its existing BridgeService instance.
actor WorkbenchHost {
    private let agentBroker: AutomationAgentBroker?
    private let bridge: any BridgeService
    private let directory: URL
    private let socketURL: URL
    private let stateURL: URL
    private let lockFD: Int32
    private let journalCapacity: Int
    private var state: WorkbenchDiskState
    private var recentReads: [WorkbenchHistoryEntry] = []
    private var listener: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private static let maximumBytes = 65_536
    private static let actions: [String: WorkbenchGrant] = [
        "music.qq.status": .musicRead, "music.qq.playback": .musicPlaybackRead,
        "music.qq.searchPlay": .musicWrite, "music.qq.play": .musicWrite, "music.qq.pause": .musicWrite, "music.qq.next": .musicWrite, "music.qq.previous": .musicWrite,
        "automation.status": .automationRead, "automation.runs": .automationRead,
        "system.volume.get": .volumeRead,
        "timer.list": .timerRead, "timer.create": .timerWrite, "timer.update": .timerWrite, "timer.cancel": .timerWrite,
        "reminder.list": .reminderRead, "reminder.create": .reminderWrite, "reminder.update": .reminderWrite, "reminder.complete": .reminderWrite,
        "calendar.list": .calendarRead, "calendar.create": .calendarWrite, "calendar.update": .calendarWrite, "calendar.cancel": .calendarWrite,
        "note.list": .noteRead, "note.read": .noteRead, "note.create": .noteWrite, "note.append": .noteWrite,
        "weather.get": .weatherRead, "location.get": .locationRead,
        "mail.search": .mailRead, "mail.read": .mailRead, "mail.draft.read": .mailRead,
        "mail.draft.create": .mailWrite, "mail.send.request": .mailSendRequest, "mail.draft.status": .mailSendRequest
    ]

    init(bridge: any BridgeService, directory: URL = WorkbenchPaths.defaultDirectory,
         journalCapacity: Int = 10_000, agentBroker: AutomationAgentBroker? = nil) throws {
        self.agentBroker = agentBroker
        self.bridge = bridge
        self.directory = directory
        self.socketURL = directory.appendingPathComponent("workbench.sock")
        self.stateURL = directory.appendingPathComponent("state.json")
        self.journalCapacity = max(1, journalCapacity)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else { throw WorkbenchHostError.storage }
        let lockPath = directory.appendingPathComponent("host.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw WorkbenchHostError.storage }
        guard fchmod(fd, 0o600) == 0 else { close(fd); throw WorkbenchHostError.storage }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw WorkbenchHostError.alreadyRunning }
        self.lockFD = fd
        do {
            if FileManager.default.fileExists(atPath: stateURL.path) {
                self.state = try JSONDecoder().decode(WorkbenchDiskState.self, from: Data(contentsOf: stateURL))
            } else { self.state = .init() }
            // A crash after dispatch cannot prove whether a side effect happened.
            for i in state.journal.indices where state.journal[i].status == "pending" {
                state.journal[i].status = "unknown"
                state.journal[i].error = "result_unverifiable"
            }
            try Self.save(state, to: stateURL)
        } catch {
            flock(fd, LOCK_UN); close(fd)
            throw error
        }
    }

    deinit { flock(lockFD, LOCK_UN); close(lockFD) }

    func start() throws {
        guard listener < 0 else { return }
        guard socketURL.path.utf8CString.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw WorkbenchHostError.socket
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WorkbenchHostError.socket }
        do {
            // A stale socket is safe to replace only when no process accepts it.
            if FileManager.default.fileExists(atPath: socketURL.path) {
                let probe = socket(AF_UNIX, SOCK_STREAM, 0)
                if probe >= 0 {
                    var old = Self.address(socketURL.path)
                    let active = withUnsafePointer(to: &old) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                        }
                    }
                    close(probe)
                    if active { throw WorkbenchHostError.alreadyRunning }
                }
                try FileManager.default.removeItem(at: socketURL)
            }
            var address = Self.address(socketURL.path)
            let bound = withUnsafePointer(to: &address) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, chmod(socketURL.path, 0o600) == 0, listen(fd, 16) == 0 else {
                throw WorkbenchHostError.socket
            }
            listener = fd
            acceptTask = Task.detached { [weak self] in
                while !Task.isCancelled {
                    let clientFD = accept(fd, nil, nil)
                    if clientFD < 0 { break }
                    Task.detached { [weak self] in await self?.serve(clientFD) }
                }
            }
        } catch {
            close(fd)
            throw error
        }
    }

    func stop() {
        guard listener >= 0 else { return }
        acceptTask?.cancel()
        shutdown(listener, SHUT_RDWR)
        close(listener)
        listener = -1
        try? FileManager.default.removeItem(at: socketURL)
    }

    func createClient(name: String) throws -> WorkbenchClientCredential {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { throw WorkbenchHostError.invalidName }
        let id = UUID().uuidString.lowercased()
        let token = (0..<32).map { _ in UInt8.random(in: 0...255) }.map { String(format: "%02x", $0) }.joined()
        let tokenURL = credentialURL(id)
        try Self.save(Data(token.utf8), to: tokenURL)
        let prior = state
        state.clients.append(.init(id: id, name: trimmed, grants: [], revoked: false, createdAt: Date()))
        do { try persist() } catch { state = prior; try? FileManager.default.removeItem(at: tokenURL); throw error }
        return .init(id: id, name: trimmed, credential: token)
    }

    func setGrants(clientID: String, grants: Set<WorkbenchGrant>) async throws {
        let serviceState = try await bridge.workbenchState()
        let mailScope: String?
        if grants.contains(where: { $0.rawValue.hasPrefix("mail.") }) {
            guard let scope = serviceState.mailScopeID else { throw WorkbenchHostError.mailScopeMissing }
            mailScope = scope
        } else { mailScope = nil }
        let calendarScope: String?
        if grants.contains(where: { $0.rawValue.hasPrefix("calendar.") }) {
            guard let scope = serviceState.calendarScopeID else { throw WorkbenchHostError.calendarScopeMissing }
            calendarScope = scope
        } else { calendarScope = nil }
        let latest = try await bridge.workbenchState()
        guard latest.mailScopeID == serviceState.mailScopeID,
              latest.calendarScopeID == serviceState.calendarScopeID else { throw WorkbenchHostError.storage }
        guard let index = state.clients.firstIndex(where: { $0.id == clientID && !$0.revoked }) else { throw WorkbenchHostError.missingClient }
        let old = state
        if let agentBroker { Task { await agentBroker.revoke(clientID: clientID) } }
        state.clients[index].grants = grants
        state.clients[index].mailScopeID = mailScope
        state.clients[index].calendarScopeID = calendarScope
        do { try persist() } catch { state = old; throw error }
    }

    func revoke(clientID: String) throws {
        guard let index = state.clients.firstIndex(where: { $0.id == clientID }) else { throw WorkbenchHostError.missingClient }
        let old = state
        if let agentBroker { Task { await agentBroker.revoke(clientID: clientID) } }
        state.clients[index].revoked = true
        state.clients[index].grants = []
        state.clients[index].mailScopeID = nil
        state.clients[index].calendarScopeID = nil
        // The revoked token can never submit another request. Reclaim only its
        // journal entries so active clients keep their idempotency history.
        // Keep sanitized audit metadata independently of the deduplication ledger.
        state.archive += state.journal.filter { $0.clientID == clientID }.map {
            .init(id: $0.requestID, clientID: $0.clientID, action: $0.action,
                  status: $0.status == "pending" ? "unknown" : $0.status,
                  error: $0.status == "pending" ? "result_unverifiable" : $0.error,
                  occurredAt: $0.occurredAt)
        }
        if state.archive.count > 1_000 {
            state.archive.removeFirst(state.archive.count - 1_000)
        }
        state.journal.removeAll { $0.clientID == clientID }
        do { try persist() } catch { state = old; throw error }
        try? FileManager.default.removeItem(at: credentialURL(clientID))
    }

    func workerAuthorized(clientID: String) -> Bool { state.clients.contains { $0.id == clientID && !$0.revoked && $0.grants.contains(.automationWorker) } }
    func clients() -> [WorkbenchClientRecord] { state.clients }
    func selectedMailScope() async throws -> MailScopeKey? { try await bridge.selectedMailScope() }
    func selectedCalendarScope() async -> String? { await bridge.calendarScope() }
    /// UI only. External wire dispatch has no operation that calls this method.
    func confirmMailSend(id: String, preview: MailDraftContent) async throws -> String {
        let drafts = try await bridge.mailDrafts()
        let serviceState = try await bridge.workbenchState()
        guard serviceState.status != "paused", let entry = drafts.first(where: { $0.id == id }),
              serviceState.mailScopeID == entry.scopeID else { throw StableErrorCode.permissionRequired }
        if entry.owner != "local_ui" && entry.owner != "automation" {
            guard let client = state.clients.first(where: { $0.id == entry.owner && !$0.revoked }),
                  client.grants.contains(.mailSendRequest), client.mailScopeID == entry.scopeID else { throw StableErrorCode.permissionRequired }
        }
        let result = try await bridge.confirmMailSend(id: id, preview: preview, authorize: { [weak self] in
            await self?.admitMailSend(owner: entry.owner, scopeID: entry.scopeID) ?? false
        })
        recentReads.append(.init(id: UUID().uuidString, clientID: "local_ui", action: "mail.send.confirm",
                                 status: result, error: result == "unknown" ? "result_unverifiable" : nil, occurredAt: Date()))
        if recentReads.count > 100 { recentReads.removeFirst(recentReads.count - 100) }
        return result
    }
    private func admitMailSend(owner: String, scopeID: String) async -> Bool {
        guard let latest = try? await bridge.workbenchState(), latest.status != "paused", latest.mailScopeID == scopeID else { return false }
        if owner == "local_ui" || owner == "automation" { return true }
        return state.clients.contains { $0.id == owner && !$0.revoked && $0.grants.contains(.mailSendRequest) && $0.mailScopeID == scopeID }
    }
    func history() async -> [WorkbenchHistoryEntry] {
        var records: [WorkbenchHistoryEntry] = state.journal.suffix(100).map {
            .init(id: $0.requestID, clientID: $0.clientID, action: $0.action,
                  status: $0.status, error: $0.error, occurredAt: $0.occurredAt)
        }
        records += state.archive.suffix(100)
        records += recentReads
        if let runtime = try? await bridge.workbenchState() {
            let trackedIDs = Set(records.map { $0.clientID + ":" + $0.id.lowercased() })
            records += runtime.recentActions.filter { record in
                !trackedIDs.contains(record.callerID + ":" + (record.correlationID ?? record.id.uuidString).lowercased())
            }.map {
                .init(id: $0.correlationID ?? $0.id.uuidString, clientID: $0.callerID, action: $0.name,
                      status: $0.outcome.rawValue, error: $0.stableError, occurredAt: $0.occurredAt)
            }
        }
        var seen: Set<String> = []
        return Array(records.sorted { $0.occurredAt > $1.occurredAt }.filter {
            seen.insert($0.clientID + ":" + $0.id.lowercased()).inserted
        }.prefix(100))
    }

    nonisolated private func serve(_ fd: Int32) async {
        defer { close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 45, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == getuid() else { return }
        var input = Data()
        var byte: UInt8 = 0
        while input.count <= Self.maximumBytes {
            let n = Darwin.read(fd, &byte, 1)
            guard n == 1 else { return }
            if byte == 10 { break }
            input.append(byte)
        }
        guard input.count <= Self.maximumBytes else { return }
        let response: WorkbenchResponse
        if let request = try? JSONDecoder().decode(WorkbenchRequest.self, from: input) {
            response = await process(request)
        } else {
            response = .init(requestID: "", status: "rejected", error: "invalid_schema")
        }
        guard var output = try? JSONEncoder().encode(response) else { return }
        output.append(10)
        output.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    func process(_ request: WorkbenchRequest) async -> WorkbenchResponse {
        guard request.version == 1, UUID(uuidString: request.requestID) != nil else {
            return .init(requestID: request.requestID, status: "rejected", error: "invalid_schema")
        }
        guard let client = authenticated(request.credential) else {
            return .init(requestID: request.requestID, status: "rejected", error: "unauthenticated")
        }
        switch request.operation {
        case "automation.claim", "automation.submit":
            guard let agentBroker, client.grants.contains(.automationWorker),
                  request.action == nil, case .object(let fields) = request.parameters else { return invalid(request) }
            guard let service = try? await bridge.workbenchState(), service.status != "paused",
                  authenticated(request.credential)?.grants.contains(.automationWorker) == true else {
                return .init(requestID: request.requestID, status: "rejected", error: "permission_required")
            }
            if request.operation == "automation.claim" {
                guard fields.isEmpty else { return invalid(request) }
                let job = await agentBroker.claim(clientID: client.id)
                guard authenticated(request.credential)?.grants.contains(.automationWorker) == true else {
                    await agentBroker.revoke(clientID: client.id)
                    return .init(requestID: request.requestID, status: "rejected", error: "permission_required")
                }
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                let result = job.flatMap { try? encoder.encode($0) }.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .null
                return .init(requestID: request.requestID, status: "succeeded", result: .object(["version": .number(1), "job": result]))
            }
            guard Set(fields.keys) == ["job_id", "lease_id", "decisions_json"],
                  case .string(let jobID)? = fields["job_id"], case .string(let leaseID)? = fields["lease_id"],
                  case .string(let text)? = fields["decisions_json"], text.utf8.count <= 32_000 else { return invalid(request) }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            guard let decisions = try? decoder.decode([AutomationAgentDecision].self, from: Data(text.utf8)) else { return invalid(request) }
            do {
                try await agentBroker.submit(clientID: client.id, jobID: jobID, leaseID: leaseID, decisions: decisions)
                return .init(requestID: request.requestID, status: "succeeded", result: .object(["accepted": .bool(true), "execution": .string("app_validation_pending")]))
            } catch { return .init(requestID: request.requestID, status: "rejected", error: "lease_expired_or_unauthorized") }
        case "status":
            guard request.action == nil, case .object(let p) = request.parameters, p.isEmpty else { return invalid(request) }
            guard let serviceState = try? await bridge.workbenchState() else {
                return .init(requestID: request.requestID, status: "failed", error: "internal_error")
            }
            guard authenticated(request.credential) != nil else {
                return .init(requestID: request.requestID, status: "rejected", error: "unauthenticated")
            }
            var status: [String: JSONValue] = ["paused": .bool(serviceState.status == "paused"), "host": .string("ready")]
            if authenticated(request.credential)?.grants.contains(.locationRead) == true,
               let authorization = serviceState.locationAuthorization {
                status["location_authorization"] = .string(authorization.rawValue)
            }
            let permissionStates = await bridge.systemAuthorizationStates()
            // Re-authenticate after awaiting the service; never disclose unrelated capability states.
            guard let latestClient = authenticated(request.credential) else {
                return .init(requestID: request.requestID, status: "rejected", error: "unauthenticated")
            }
            if !latestClient.grants.contains(.locationRead) { status.removeValue(forKey: "location_authorization") }
            let visible: [String: Set<WorkbenchGrant>] = [
                "accessibility": [.musicPlaybackRead, .musicWrite],
                "notifications": [.timerRead, .timerWrite], "reminders": [.reminderRead, .reminderWrite],
                "notes": [.noteRead, .noteWrite], "mail": [.mailRead, .mailWrite, .mailSendRequest],
                "calendar": [.calendarRead, .calendarWrite]
            ]
            status["system_permissions"] = .object(permissionStates.reduce(into: [String: JSONValue]()) { output, entry in
                if let grants = visible[entry.key], !latestClient.grants.isDisjoint(with: grants) {
                    output[entry.key] = .string(entry.value)
                }
            })
            return .init(requestID: request.requestID, status: "succeeded", result: .object(status))
        case "capabilities":
            guard request.action == nil, case .object(let p) = request.parameters, p.isEmpty else { return invalid(request) }
            guard let serviceState = try? await bridge.workbenchState() else {
                return .init(requestID: request.requestID, status: "failed", error: "internal_error")
            }
            guard let currentClient = authenticated(request.credential) else {
                return .init(requestID: request.requestID, status: "rejected", error: "unauthenticated")
            }
            let grants = currentClient.grants.map(\.rawValue).sorted()
            let supported = Set(serviceState.supportedActions)
            var actions = Self.actions.filter { name, grant in
                currentClient.grants.contains(grant) &&
                (!grant.rawValue.hasPrefix("mail.") || (currentClient.mailScopeID != nil && currentClient.mailScopeID == serviceState.mailScopeID)) && (supported.contains(name) ||
                    (name == "calendar.list" && currentClient.calendarScopeID != nil && currentClient.calendarScopeID == serviceState.calendarScopeID && supported.contains("calendar.create")) ||
                    (name == "timer.list" && supported.contains("timer.create")) ||
                    (name == "reminder.list" && supported.contains("reminder.complete"))) &&
                (!grant.rawValue.hasPrefix("calendar.") || (currentClient.calendarScopeID != nil && currentClient.calendarScopeID == serviceState.calendarScopeID))
            }.keys.sorted()
            if agentBroker != nil, currentClient.grants.contains(.automationWorker) { actions += ["automation.claim", "automation.submit"] }
            return .init(requestID: request.requestID, status: "succeeded",
                         result: .object(["grants": .array(grants.map(JSONValue.string)),
                                          "actions": .array(actions.map(JSONValue.string)),
                                          "weather_cities": .array(client.grants.contains(.weatherRead) ? WeatherCities.all.map { .object(["id": .string($0.id), "name": .string($0.name)]) } : [])]))
        case "result":
            guard request.action == nil, case .object(let p) = request.parameters, p.count == 1,
                  case .string(let targetID)? = p["request_id"], UUID(uuidString: targetID) != nil else { return invalid(request) }
            guard let entry = state.journal.first(where: { $0.clientID == client.id && $0.requestID.caseInsensitiveCompare(targetID) == .orderedSame }) else {
                return .init(requestID: request.requestID, status: "failed", error: "not_found")
            }
            return .init(requestID: request.requestID, status: "succeeded",
                         result: .object(["request_id": .string(targetID), "action": .string(entry.action),
                                          "status": .string(entry.status == "pending" ? "unknown" : entry.status),
                                          "error": entry.error.map(JSONValue.string) ?? .null,
                                          "simulation": .bool(entry.isSimulation ?? false)]))
        case "action":
            guard let action = request.action, let grant = Self.actions[action] else {
                return .init(requestID: request.requestID, status: "rejected", error: "capability_disabled")
            }
            if Self.writeActions.contains(action), let cached = cachedWrite(request, clientID: client.id) { return cached }
            guard client.grants.contains(grant) else {
                return .init(requestID: request.requestID, status: "rejected", error: "permission_required")
            }
            guard let parameters = validate(action: action, parameters: request.parameters) else { return invalid(request) }
            guard let serviceState = try? await bridge.workbenchState() else {
                return .init(requestID: request.requestID, status: "failed", error: "internal_error")
            }
            guard serviceState.status != "paused" else {
                return .init(requestID: request.requestID, status: "rejected", error: "bridge_paused")
            }
            guard Self.supports(action, in: serviceState) else {
                return .init(requestID: request.requestID, status: "rejected", error: "capability_disabled")
            }
            guard authenticated(request.credential)?.grants.contains(grant) == true else {
                return .init(requestID: request.requestID, status: "rejected", error: "permission_required")
            }
            let mailScope = authenticated(request.credential)?.mailScopeID
            let calendarScope = authenticated(request.credential)?.calendarScopeID
            if grant.rawValue.hasPrefix("mail."), mailScope == nil || mailScope != serviceState.mailScopeID {
                return .init(requestID: request.requestID, status: "rejected", error: "permission_required")
            }
            if grant.rawValue.hasPrefix("calendar."), calendarScope == nil || calendarScope != serviceState.calendarScopeID {
                return .init(requestID: request.requestID, status: "rejected", error: "permission_required")
            }
            if !Self.writeActions.contains(action) {
                let response = await BridgeExecutionContext.$callerID.withValue(client.id) {
                    await BridgeExecutionContext.$correlationID.withValue(request.requestID) {
                        await BridgeExecutionContext.$mailScopeID.withValue(mailScope) {
                            await dispatch(action: action, parameters: parameters, requestID: request.requestID, isSimulation: serviceState.isSimulation)
                        }
                    }
                }
                recentReads.append(.init(id: request.requestID, clientID: client.id, action: action,
                                         status: response.status, error: response.error, occurredAt: Date()))
                if recentReads.count > 100 { recentReads.removeFirst(recentReads.count - 100) }
                if grant.rawValue.hasPrefix("mail.") {
                    let latest = try? await bridge.workbenchState()
                    guard let current = authenticated(request.credential), current.grants.contains(grant),
                          current.mailScopeID == mailScope, latest?.mailScopeID == mailScope else {
                        return .init(requestID: request.requestID, status: "rejected", error: "permission_required")
                    }
                }
                if grant.rawValue.hasPrefix("calendar.") {
                    let latest = try? await bridge.workbenchState()
                    guard let current = authenticated(request.credential), current.grants.contains(grant),
                          current.calendarScopeID == calendarScope, latest?.calendarScopeID == calendarScope else {
                        return .init(requestID: request.requestID, status: "rejected", error: "permission_required")
                    }
                }
                guard authenticated(request.credential)?.grants.contains(grant) == true else {
                    return .init(requestID: request.requestID, status: "rejected", error: "permission_required")
                }
                return response
            }
            if let cached = cachedWrite(request, clientID: client.id) { return cached }
            guard state.journal.count < journalCapacity else {
                return .init(requestID: request.requestID, status: "failed", error: "journal_capacity")
            }
            let entry = WorkbenchJournalEntry(requestID: request.requestID, clientID: client.id, action: action,
                                             fingerprint: Self.fingerprint(action: action, parameters: request.parameters),
                                             isSimulation: serviceState.isSimulation, status: "pending", error: nil, occurredAt: Date())
            state.journal.append(entry)
            do { try persist() } catch { state.journal.removeLast(); return .init(requestID: request.requestID, status: "failed", error: "internal_error") }
            let response: WorkbenchResponse
            let dispatched = await BridgeExecutionContext.$callerID.withValue(client.id) {
                await BridgeExecutionContext.$correlationID.withValue(request.requestID) {
                    await BridgeExecutionContext.$mailScopeID.withValue(mailScope) {
                        await dispatch(action: action, parameters: parameters, requestID: request.requestID, isSimulation: serviceState.isSimulation, musicAuthorization: { [weak self] in
                            await self?.musicWriteAuthorized(clientID: client.id) ?? false
                        })
                    }
                }
            }
            if grant.rawValue.hasPrefix("calendar.") {
                let latest = try? await bridge.workbenchState()
                if let current = authenticated(request.credential), current.grants.contains(grant),
                   current.calendarScopeID == calendarScope, latest?.calendarScopeID == calendarScope {
                    response = dispatched
                } else {
                    response = .init(requestID: request.requestID, status: "unknown", error: "result_unverifiable")
                }
            } else if grant == .musicWrite, !(await musicWriteAuthorized(clientID: client.id)) {
                response = .init(requestID: request.requestID, status: "unknown", error: "late_or_revoked_result")
            } else { response = dispatched }
            if let i = state.journal.firstIndex(where: { $0.clientID == client.id && $0.requestID == request.requestID }) {
                state.journal[i].status = response.status
                state.journal[i].error = response.error
                // Persistence failure leaves pending on disk and becomes unknown on restart.
                try? persist()
            }
            return response
        default: return invalid(request)
        }
    }

    private func musicWriteAuthorized(clientID: String) async -> Bool {
        guard let state = try? await bridge.workbenchState(), state.status != "paused" else { return false }
        return self.state.clients.contains { $0.id == clientID && !$0.revoked && $0.grants.contains(.musicWrite) }
    }

    private func cachedWrite(_ request: WorkbenchRequest, clientID: String) -> WorkbenchResponse? {
        guard let existing = state.journal.first(where: { $0.clientID == clientID && $0.requestID.caseInsensitiveCompare(request.requestID) == .orderedSame }) else { return nil }
        guard existing.fingerprint == Self.fingerprint(action: request.action ?? "", parameters: request.parameters) else {
            return .init(requestID: request.requestID, status: "rejected", error: "replay_detected")
        }
        return .init(requestID: request.requestID, status: existing.status == "pending" ? "unknown" : existing.status,
                     error: existing.status == "pending" ? "result_unverifiable" : existing.error,
                     result: .object(["simulation": .bool(existing.isSimulation ?? false)]))
    }

    private func authenticated(_ token: String) -> WorkbenchClientRecord? {
        guard token.utf8.count == 64 else { return nil }
        for client in state.clients where !client.revoked {
            guard let saved = try? Data(contentsOf: credentialURL(client.id)) else { continue }
            let candidate = Array(token.utf8), expected = Array(saved)
            guard candidate.count == expected.count else { continue }
            var difference: UInt8 = 0
            for i in candidate.indices { difference |= candidate[i] ^ expected[i] }
            if difference == 0 { return client }
        }
        return nil
    }

    private func persist() throws { try Self.save(state, to: stateURL) }
    private func credentialURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".credential") }
    private static func save<T: Encodable>(_ value: T, to url: URL) throws { try save(JSONEncoder().encode(value), to: url) }
    private static func save(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw WorkbenchHostError.storage }
        var isOpen = true
        do {
            try data.withUnsafeBytes { raw in
                var written = 0
                while written < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
                    guard n > 0 else { throw WorkbenchHostError.storage }
                    written += n
                }
            }
            guard fsync(fd) == 0 else { throw WorkbenchHostError.storage }
            close(fd)
            isOpen = false
            guard rename(temp.path, url.path) == 0 else { throw WorkbenchHostError.storage }
            let dirFD = open(url.deletingLastPathComponent().path, O_RDONLY)
            if dirFD >= 0 { _ = fsync(dirFD); close(dirFD) }
        } catch {
            if isOpen { close(fd) }
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
    private static func address(_ path: String) -> sockaddr_un {
        var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &a.sun_path) { $0.copyBytes(from: path.utf8CString.map { UInt8(bitPattern: $0) }) }
        return a
    }
    private func invalid(_ request: WorkbenchRequest) -> WorkbenchResponse {
        .init(requestID: request.requestID, status: "rejected", error: "invalid_schema")
    }
    private static let writeActions: Set<String> = ["music.qq.searchPlay", "music.qq.play", "music.qq.pause", "music.qq.next", "music.qq.previous", "timer.create", "timer.update", "timer.cancel",
                                                    "reminder.create", "reminder.update", "reminder.complete",
                                                    "calendar.create", "calendar.update", "calendar.cancel",
                                                    "note.create", "note.append", "mail.draft.create", "mail.send.request"]
    private static func supports(_ action: String, in state: WorkbenchServiceState) -> Bool {
        let supported = Set(state.supportedActions)
        return supported.contains(action) ||
            (action == "timer.list" && supported.contains("timer.create")) ||
            (action == "reminder.list" && supported.contains("reminder.complete")) ||
            (action == "calendar.list" && supported.contains("calendar.create"))
    }
    private static func fingerprint(action: String, parameters: JSONValue) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = (try? encoder.encode(parameters)) ?? Data()
        let digest = SHA256.hash(data: Data(action.utf8) + bytes)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension WorkbenchHost {
    func validate(action: String, parameters: JSONValue) -> [String: JSONValue]? {
        guard case .object(let p) = parameters else { return nil }
        let required: Set<String>
        let optional: Set<String>
        switch action {
        case "music.qq.playback", "music.qq.play", "music.qq.pause", "music.qq.next", "music.qq.previous", "music.qq.status", "automation.status", "automation.runs", "system.volume.get", "timer.list", "reminder.list", "location.get": required = []; optional = []
        case "music.qq.searchPlay": required = ["title"]; optional = ["artist", "version"]
        case "calendar.list": required = ["start_at", "end_at"]; optional = []
        case "calendar.create": required = ["event_id", "title", "start_at", "end_at"]; optional = ["source_url"]
        case "calendar.update": required = ["event_id"]; optional = ["title", "start_at", "end_at"]
        case "calendar.cancel": required = ["event_id"]; optional = []
        case "timer.create": required = ["timer_id", "fire_at", "label"]; optional = []
        case "timer.update": required = ["timer_id"]; optional = ["fire_at", "label"]
        case "timer.cancel": required = ["timer_id"]; optional = []
        case "reminder.create": required = ["reminder_id", "title", "due_at"]; optional = []
        case "reminder.update": required = ["reminder_id"]; optional = ["title", "due_at"]
        case "reminder.complete": required = ["reminder_id", "is_completed"]; optional = []
        case "note.list": required = []; optional = ["query"]
        case "note.read": required = ["note_id"]; optional = []
        case "note.create": required = ["note_id", "title", "text"]; optional = []
        case "note.append": required = ["note_id", "text", "expected_revision"]; optional = []
        case "mail.draft.create": required = ["draft_id", "sender", "to", "subject", "text"]; optional = ["cc", "bcc"]
        case "mail.draft.read", "mail.draft.status": required = ["draft_id"]; optional = []
        case "mail.send.request": required = ["draft_id", "expected_revision"]; optional = []
        case "weather.get": required = ["city_id"]; optional = []
        case "mail.search": required = []; optional = ["query", "unread_only"]
        case "mail.read": required = ["message_id"]; optional = []
        default: return nil
        }
        guard required.isSubset(of: Set(p.keys)), Set(p.keys).isSubset(of: required.union(optional)) else { return nil }
        for (key, value) in p {
            switch key {
            case "artist", "version", "timer_id", "reminder_id", "note_id", "message_id", "draft_id", "sender", "subject", "title", "label", "query", "text", "expected_revision", "city_id", "event_id":
                guard case .string(let s) = value, s.utf8.count <= (key == "text" ? (action == "mail.draft.create" ? 24_000 : 8_000) : key == "note_id" ? 2_048 : key == "subject" ? 512 : 256) else { return nil }
                if ["timer_id", "reminder_id", "title", "label", "city_id"].contains(key) && s.isEmpty { return nil }
                if key == "event_id" && (s.isEmpty || s.count > 128 || !s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) })) { return nil }
                if key == "expected_revision" && (s.count != 64 || !s.allSatisfy({ $0.isHexDigit })) { return nil }
                if key == "city_id" && WeatherCities.byID(s) == nil { return nil }
            case "fire_at", "due_at", "start_at", "end_at":
                guard case .string(let s) = value, ISO8601DateFormatter().date(from: s) != nil else { return nil }
            case "source_url":
                guard case .string(let s) = value, s.count <= 2048,
                      let url = URL(string: s), url.scheme == "https", url.host != nil,
                      url.user == nil, url.password == nil else { return nil }
            case "is_completed":
                guard case .bool = value else { return nil }
            case "to", "cc", "bcc":
                guard case .array(let list) = value, list.count <= 20, list.allSatisfy({ if case .string(let a) = $0 { return a.utf8.count <= 254 }; return false }) else { return nil }
            case "unread_only":
                guard case .bool = value else { return nil }
            default: return nil
            }
        }
        if action == "music.qq.searchPlay" {
            func text(_ key: String) -> String? { if case .string(let s)? = p[key] { return s }; return nil }
            guard let title = text("title"), let version = QQSongVersion(rawValue: text("version") ?? "original"),
                  (try? QQSongRequest(title: title, artist: text("artist"), version: version).validate()) != nil else { return nil }
        }
        if action == "mail.draft.create" {
            func addresses(_ key: String) -> [String] { if case .array(let v)? = p[key] { return v.compactMap { if case .string(let s) = $0 { return s }; return nil } }; return [] }
            func string(_ key: String) -> String { if case .string(let s)? = p[key] { return s }; return "" }
            guard (try? MailDraftInput(sender: string("sender"), to: addresses("to"), cc: addresses("cc"), bcc: addresses("bcc"), subject: string("subject"), text: string("text")).validate()) != nil else { return nil }
        }
        if ["timer.update", "reminder.update", "calendar.update"].contains(action) && p.count < 2 { return nil }
        if ["calendar.list", "calendar.create"].contains(action),
           let startValue = p["start_at"], let endValue = p["end_at"],
           case .string(let startText) = startValue, case .string(let endText) = endValue,
           let start = ISO8601DateFormatter().date(from: startText),
           let end = ISO8601DateFormatter().date(from: endText),
           !(start < end && end.timeIntervalSince(start) <= 31 * 86_400) { return nil }
        return p
    }

    func dispatch(action: String, parameters p: [String: JSONValue], requestID: String, isSimulation: Bool,
                  musicAuthorization: @escaping @Sendable () async -> Bool = { false }) async -> WorkbenchResponse {
        func string(_ key: String) -> String { if case .string(let s)? = p[key] { return s }; return "" }
        func optionalString(_ key: String) -> String? { if case .string(let s)? = p[key] { return s }; return nil }
        func date(_ key: String) -> Date? { optionalString(key).flatMap { ISO8601DateFormatter().date(from: $0) } }
        func reply(_ status: String, _ error: String? = nil, _ result: JSONValue = .object([:])) -> WorkbenchResponse {
            var payload: [String: JSONValue] = [:]
            if case .object(let values) = result { payload = values }
            payload["simulation"] = .bool(isSimulation)
            return .init(requestID: requestID, status: status, error: error, result: .object(payload))
        }
        do {
            switch action {
            case "music.qq.searchPlay":
                guard let version = QQSongVersion(rawValue: optionalString("version") ?? "original") else { return reply("rejected", "invalid_schema") }
                let result = try await bridge.searchAndPlayQQMusic(id: requestID, request: .init(title: string("title"), artist: optionalString("artist"), version: version), authorize: musicAuthorization)
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                return reply(result.status, result.error, try JSONDecoder().decode(JSONValue.self, from: encoder.encode(result)))
            case "music.qq.playback", "music.qq.play", "music.qq.pause", "music.qq.next", "music.qq.previous":
                let value: QQMusicPlayback
                do {
                    if action == "music.qq.playback" { value = try await bridge.qqMusicPlayback() }
                    else {
                        guard let command = QQMusicPlaybackAction(rawValue: String(action.dropFirst("music.qq.".count))) else { return reply("rejected", "invalid_schema") }
                        value = try await bridge.performQQMusic(command, authorize: musicAuthorization)
                    }
                } catch let error as QQMusicPlaybackError {
                    switch error {
                    case .unknownOutcome: return reply("unknown", "result_unverifiable")
                    case .permissionRequired: return reply("rejected", "permission_required")
                    case .notRunning: return reply("failed", "app_not_running")
                    case .unverifiable: return reply("failed", "result_unverifiable")
                    }
                }
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                return reply("succeeded", nil, try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value)))
            case "music.qq.status":
                let value = try await bridge.qqMusicStatus()
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                let payload = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
                return reply("succeeded", nil, payload)
            case "automation.status", "automation.runs":
                guard let snapshot = await bridge.automationSnapshot() else { return reply("failed", "capability_disabled") }
                if action == "automation.status" {
                    return reply("succeeded", nil, .object(["version": .number(1), "rules": .number(Double(snapshot.rules.count)), "enabled": .number(Double(snapshot.rules.filter { $0.enabled }.count)), "pending": .number(Double(snapshot.runs.filter { $0.status == .pendingApproval }.count))]))
                }
                return reply("succeeded", nil, .object(["version": .number(1), "runs": .array(snapshot.runs.suffix(100).map { run in
                    .object(["id": .string(run.id), "action": run.action.map { .string($0.rawValue) } ?? .null,
                             "status": .string(run.status.rawValue), "time": .string(ISO8601DateFormatter().string(from: run.startedAt)),
                             "error": run.failureCode.map(JSONValue.string) ?? .null])
                })]))
            case "system.volume.get":
                let r = try await bridge.readSystemVolume()
                var v: [String: JSONValue] = ["read_at": .string(Self.iso(r.readAt)), "simulation": .bool(r.isSimulation)]
                if let value = r.value { v["value"] = .number(value) }
                if let muted = r.muted { v["muted"] = .bool(muted) }
                return reply(r.outcome.rawValue, r.stableError, .object(v))
            case "timer.list":
                let timers = try await bridge.workbenchTimers()
                return reply("succeeded", nil, .object(["timers": .array(timers.map { t in
                    .object(["id": .string(t.id), "fire_at": .string(Self.iso(t.fireAt)), "label": .string(t.label)])
                })]))
            case "timer.create":
                let r = try await bridge.createTimer(id: string("timer_id"), fireAt: date("fire_at")!, label: string("label"))
                return reply(r.outcome.rawValue, r.stableError)
            case "timer.update":
                let r = try await bridge.updateTimer(id: string("timer_id"), fireAt: date("fire_at"), label: optionalString("label"))
                return reply(r.outcome.rawValue, r.stableError)
            case "timer.cancel":
                let r = try await bridge.cancelTimer(id: string("timer_id"))
                return reply(r.outcome.rawValue, r.stableError)
            case "reminder.list":
                let reminders = try await bridge.workbenchReminders()
                return reply("succeeded", nil, .object(["reminders": .array(reminders.map { r in
                    .object(["id": .string(r.id), "title": .string(r.title), "due_at": .string(Self.iso(r.dueAt)), "is_completed": .bool(r.isCompleted)])
                })]))
            case "reminder.create":
                let r = try await bridge.createReminder(id: string("reminder_id"), title: string("title"), dueAt: date("due_at")!)
                return reply(r.outcome.rawValue, r.stableError)
            case "reminder.update":
                let r = try await bridge.updateReminder(id: string("reminder_id"), title: optionalString("title"), dueAt: date("due_at"))
                return reply(r.outcome.rawValue, r.stableError)
            case "reminder.complete":
                let completed: Bool = { if case .bool(let b)? = p["is_completed"] { return b }; return false }()
                let r = try await bridge.completeReminder(id: string("reminder_id"), completed: completed)
                return reply(r.outcome.rawValue, r.stableError)
            case "calendar.list":
                let events = try await bridge.listCalendar(start: date("start_at")!, end: date("end_at")!)
                return reply("succeeded", nil, .object(["events": try Self.json(events)]))
            case "calendar.create":
                let source = optionalString("source_url").flatMap(URL.init(string:))
                let event = try await bridge.createCalendarEvent(id: string("event_id"), title: string("title"),
                    start: date("start_at")!, end: date("end_at")!, sourceURL: source)
                return reply("succeeded", nil, .object(["event": try Self.json(event)]))
            case "calendar.update":
                let event = try await bridge.updateCalendarEvent(id: string("event_id"), title: optionalString("title"),
                    start: date("start_at"), end: date("end_at"))
                return reply("succeeded", nil, .object(["event": try Self.json(event)]))
            case "calendar.cancel":
                try await bridge.cancelCalendarEvent(id: string("event_id"))
                return reply("succeeded")
            case "note.list":
                let r = try await bridge.listNotes(query: optionalString("query") ?? "")
                return reply(r.status, r.stableError, .object(["notes": .array(r.notes.map { .object(["id": .string($0.id), "title": .string($0.title)]) })]))
            case "note.read":
                let r = try await bridge.readNote(id: string("note_id"))
                return reply(r.status, r.stableError, Self.noteResult(r, includeContent: action == "note.read"))
            case "note.create":
                let r = try await bridge.createNote(id: string("note_id"), title: string("title"), text: string("text"))
                return reply(r.status, r.stableError, Self.noteResult(r, includeContent: action == "note.read"))
            case "note.append":
                let r = try await bridge.appendNote(id: string("note_id"), text: string("text"), expectedRevision: string("expected_revision"))
                return reply(r.status, r.stableError, Self.noteResult(r, includeContent: action == "note.read"))
            case "weather.get":
                let r = try await bridge.readWeather(cityID: string("city_id"))
                let value = r.report.flatMap { try? Self.json($0) } ?? .object([:])
                return reply(r.status, r.stableError, .object(["report": value]))
            case "location.get":
                let r = try await bridge.readLocation()
                let value = r.location.flatMap { try? Self.json($0) } ?? .object([:])
                return reply(r.status, r.stableError, .object(["location": value]))
            case "mail.draft.create":
                func addresses(_ key: String) -> [String] { if case .array(let v)? = p[key] { return v.compactMap { if case .string(let s) = $0 { return s }; return nil } }; return [] }
                let input = MailDraftInput(sender: string("sender"), to: addresses("to"), cc: addresses("cc"), bcc: addresses("bcc"), subject: string("subject"), text: string("text"))
                let r = try await bridge.createMailDraft(id: string("draft_id"), input: input)
                return reply(r.status, r.stableError, .object(["draft_id": r.draftID.map(JSONValue.string) ?? .null, "revision": r.revision.map(JSONValue.string) ?? .null]))
            case "mail.draft.read":
                let r = try await bridge.readMailDraft(id: string("draft_id"))
                return reply(r.status, r.stableError, .object(["draft": try r.draft.map(Self.json) ?? .null]))
            case "mail.send.request":
                let r = try await bridge.requestMailSend(id: string("draft_id"), revision: string("expected_revision"))
                return reply(r.status, r.stableError, .object(["send_state": r.sendState.map(JSONValue.string) ?? .null, "draft_id": .string(string("draft_id")), "remediation": .string("等待用户在 Orbit 智轨核对并确认发送；请求成功不代表发送。")]))
            case "mail.draft.status":
                let r = try await bridge.mailDraftStatus(id: string("draft_id"))
                return reply(r.status, r.stableError, .object(["draft_id": .string(string("draft_id")), "send_state": r.sendState.map(JSONValue.string) ?? .null]))
            case "mail.search":
                let unread: Bool = { if case .bool(let b)? = p["unread_only"] { return b }; return false }()
                let r = try await bridge.searchMail(query: optionalString("query") ?? "", unreadOnly: unread)
                return reply(r.status, r.stableError, .object(["messages": try Self.json(r.messages)]))
            case "mail.read":
                let r = try await bridge.readMail(id: string("message_id"))
                return reply(r.status, r.stableError, .object(["mail": try r.mail.map(Self.json) ?? .null]))
            default: return reply("rejected", "capability_disabled")
            }
        } catch let e as StableErrorCode { return reply("rejected", e.rawValue) }
        catch let e as CalendarAccessError {
            switch e {
            case .uncertainWrite: return reply("unknown", "result_unverifiable", Self.remediation(e))
            case .permissionRequired: return reply("rejected", "permission_required", Self.remediation(e))
            case .invalidInput, .notOwned: return reply("rejected", "invalid_schema", Self.remediation(e))
            case .requiresApp, .calendarNotEnabled, .noWritableSource, .corruptLedger:
                return reply("rejected", "capability_disabled", Self.remediation(e))
            case .unavailable: return reply("failed", "result_unverifiable", Self.remediation(e))
            }
        }
        catch let e as ReminderAccessError {
            switch e {
            case .requiresApp, .listNotEnabled, .noWritableSource:
                return reply("rejected", "capability_disabled", Self.remediation(e))
            case .unavailable:
                return reply("failed", "result_unverifiable", Self.remediation(e))
            }
        } catch let e as NotesAccessError {
            switch e {
            case .requiresApp, .notEnabled, .folderConflict, .corruptState:
                return reply("rejected", "capability_disabled", Self.remediation(e))
            case .pendingWrite:
                return reply("unknown", "result_unverifiable", Self.remediation(e))
            case .unavailable:
                return reply("failed", "result_unverifiable", Self.remediation(e))
            }
        } catch let e as UserNotificationSchedulerError {
            switch e {
            case .permissionRequired: return reply("rejected", "permission_required", Self.remediation(e))
            case .requiresAppBundle: return reply("rejected", "capability_disabled", Self.remediation(e))
            case .pastTime: return reply("rejected", "invalid_schema", Self.remediation(e))
            case .readbackFailed: return reply("unknown", "result_unverifiable", Self.remediation(e))
            }
        } catch is BridgeServiceError {
            return reply("rejected", "capability_disabled",
                         .object(["remediation": .string("请在 Orbit 智轨中启用对应的本地能力。")]))
        } catch { return reply("failed", "internal_error") }
    }

    static func remediation(_ error: LocalizedError) -> JSONValue {
        .object(["remediation": .string("请在 Orbit 智轨打开对应能力并检查系统权限或专用列表。\(error.errorDescription ?? "")")])
    }

    static func noteResult(_ r: LocalNotesCommandResult, includeContent: Bool) -> JSONValue {
        guard let n = r.note else { return .object([:]) }
        var metadata: [String: JSONValue] = ["id": .string(n.id), "revision": .string(n.revision), "can_append": .bool(n.canAppend)]
        if includeContent { metadata["title"] = .string(n.title); metadata["text"] = .string(n.text) }
        return .object(["note": .object(metadata)])
    }
    static func json<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
