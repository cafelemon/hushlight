import Foundation

// The caller must obtain this value from an explicit user instruction, never from group content.
enum ChatStartIntent: Sendable {
    case explicitUserAuthorization
}

struct ChatTarget: Sendable, Hashable {
    let accountID: String
    let groupID: String
}

struct ChatStartRequest: Sendable {
    let intent: ChatStartIntent
    let callerID: String
    let target: ChatTarget
}

struct ChatIncomingMessage: Sendable {
    let messageRequestID: String
    let callerID: String
    let target: ChatTarget
    let body: String
}

struct ChatSendRequest: Sendable {
    let messageRequestID: String
    let target: ChatTarget
    let body: String
}

enum ChatSendOutcome: Sendable, Equatable {
    case sent
    case rejected
    case unknown
}

enum ChatProcessOutcome: Sendable, Equatable {
    case sent
    case noReply
    case stopped
    case wrongTarget
    case busy
    case duplicate
    case analysisFailed
    case sendRejected
    case deliveryUnknown
}

enum ChatSessionError: Error, Equatable {
    case invalidRequest
    case targetMismatch
}

protocol ChatTargetVerifying: Sendable {
    // Resolve the stable identity currently selected by the real account/group adapter.
    func verifiedTarget() async throws -> ChatTarget
}

protocol ChatAnalyzing: Sendable {
    func reply(to message: ChatIncomingMessage) async throws -> String?
}

protocol ChatSending: Sendable {
    // Immediately before the native send, call authorization with the freshly observed
    // destination. A false result prohibits sending. Preserve messageRequestID on an
    // unknown result; the coordinator will not retry that request.
    func send(_ request: ChatSendRequest,
              authorization: @escaping @Sendable (ChatTarget) async -> Bool) async -> ChatSendOutcome
}

private final class ChatLeaseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var leaseID: UUID?
    private var target: ChatTarget?
    private let isSharedPaused: @Sendable () async -> Bool

    init(isSharedPaused: @escaping @Sendable () async -> Bool) {
        self.isSharedPaused = isSharedPaused
    }

    func activate(_ id: UUID, target: ChatTarget) {
        lock.lock()
        leaseID = id
        self.target = target
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        leaseID = nil
        target = nil
        lock.unlock()
    }

    func permits(_ id: UUID, actualTarget: ChatTarget) async -> Bool {
        let paused = await isSharedPaused()
        return lock.withLock { !paused && leaseID == id && target == actualTarget }
    }
}

actor ChatSessionCoordinator {
    private struct Session {
        let leaseID: UUID
        let callerID: String
        let target: ChatTarget
    }

    private struct MessageKey: Hashable {
        let target: ChatTarget
        let callerID: String
        let messageRequestID: String
    }

    private let verifier: any ChatTargetVerifying
    private let analyzer: any ChatAnalyzing
    private let sender: any ChatSending
    private let gate: ChatLeaseGate
    private var session: Session?
    private var currentTask: Task<ChatProcessOutcome, Never>?
    private var currentTaskToken: UUID?
    private var seenRequestIDs = Set<MessageKey>()
    private var generation = 0

    init(verifier: any ChatTargetVerifying,
         analyzer: any ChatAnalyzing,
         sender: any ChatSending,
         isSharedPaused: @escaping @Sendable () async -> Bool) {
        self.verifier = verifier
        self.analyzer = analyzer
        self.sender = sender
        self.gate = ChatLeaseGate(isSharedPaused: isSharedPaused)
        // Deliberately no persisted session: a new process starts stopped.
    }

    func start(_ request: ChatStartRequest) async throws {
        invalidate()
        let expectedGeneration = generation
        guard case .explicitUserAuthorization = request.intent,
              !request.callerID.isEmpty,
              !request.target.accountID.isEmpty,
              !request.target.groupID.isEmpty else {
            throw ChatSessionError.invalidRequest
        }
        guard try await verifier.verifiedTarget() == request.target else {
            throw ChatSessionError.targetMismatch
        }
        guard generation == expectedGeneration else { throw ChatSessionError.invalidRequest }
        let leaseID = UUID()
        session = Session(leaseID: leaseID, callerID: request.callerID, target: request.target)
        gate.activate(leaseID, target: request.target)
    }

    func stop() { invalidate() }
    func pause() { invalidate() }
    func revoke() { invalidate() }

    func targetChanged() { invalidate() }

    func isActive() -> Bool { session != nil }

    func handle(_ message: ChatIncomingMessage) async -> ChatProcessOutcome {
        guard let session, await gate.permits(session.leaseID, actualTarget: session.target) else {
            return .stopped
        }
        guard message.callerID == session.callerID, message.target == session.target else {
            return .wrongTarget
        }
        guard !message.messageRequestID.isEmpty else { return .wrongTarget }
        let key = MessageKey(target: session.target, callerID: session.callerID,
                             messageRequestID: message.messageRequestID)
        guard !seenRequestIDs.contains(key) else { return .duplicate }
        guard currentTask == nil else { return .busy }

        seenRequestIDs.insert(key)
        let taskToken = UUID()
        let task = Task { await self.execute(message, under: session) }
        currentTask = task
        currentTaskToken = taskToken
        let outcome = await task.value
        if currentTaskToken == taskToken {
            currentTask = nil
            currentTaskToken = nil
        }
        return outcome
    }

    private func execute(_ message: ChatIncomingMessage, under session: Session) async -> ChatProcessOutcome {
        do {
            guard try await verifier.verifiedTarget() == session.target else {
                invalidateIfCurrent(session)
                return .wrongTarget
            }
            guard await gate.permits(session.leaseID, actualTarget: session.target), !Task.isCancelled else {
                return .stopped
            }
            let reply = try await analyzer.reply(to: message)
            guard await gate.permits(session.leaseID, actualTarget: session.target), !Task.isCancelled else {
                return .stopped
            }
            guard let reply, !reply.isEmpty else { return .noReply }
            guard try await verifier.verifiedTarget() == session.target else {
                invalidateIfCurrent(session)
                return .wrongTarget
            }
            guard await gate.permits(session.leaseID, actualTarget: session.target), !Task.isCancelled else {
                return .stopped
            }
            let leaseID = session.leaseID
            let gate = self.gate
            let result = await sender.send(
                ChatSendRequest(messageRequestID: message.messageRequestID, target: session.target, body: reply),
                authorization: { actualTarget in await gate.permits(leaseID, actualTarget: actualTarget) }
            )
            switch result {
            case .sent: return .sent // A completed send cannot be retracted by a later stop.
            case .rejected: return .sendRejected
            case .unknown: return .deliveryUnknown
            }
        } catch {
            return await gate.permits(session.leaseID, actualTarget: session.target) ? .analysisFailed : .stopped
        }
    }

    private func invalidateIfCurrent(_ candidate: Session) {
        if session?.leaseID == candidate.leaseID { invalidate() }
    }

    private func invalidate() {
        generation &+= 1
        gate.invalidate() // Synchronous, before task cancellation or any suspension.
        session = nil
        currentTask?.cancel()
        currentTask = nil
        currentTaskToken = nil
    }
}
