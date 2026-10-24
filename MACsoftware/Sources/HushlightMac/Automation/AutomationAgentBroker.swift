import Foundation

struct AutomationAgentJob: Codable, Sendable {
    let version: Int
    let id: String
    let leaseID: String
    let clientID: String
    let expiresAt: Date
    let ruleID: String
    let allowedActions: Set<AutomationAction>
    let item: AutomationInputItem
}

/// Short-lived analysis jobs only. App remains the exclusive action executor.
/// Plaintext exists in memory during this lease; engine retry inputs are encrypted at rest.
actor AutomationAgentBroker {
    private struct Entry {
        let job: AutomationAgentJob
        var claimed = false
        let continuation: CheckedContinuation<[AutomationAgentDecision], Error>
    }
    private var entries: [String: Entry] = [:]
    private let now: @Sendable () -> Date
    private let timeout: TimeInterval
    init(timeout: TimeInterval = 60, now: @escaping @Sendable () -> Date = Date.init) {
        self.timeout = timeout; self.now = now
    }

    func analyze(clientID: String, rule: AutomationRule, item: AutomationInputItem) async throws -> [AutomationAgentDecision] {
        let job = AutomationAgentJob(version: 1, id: UUID().uuidString, leaseID: UUID().uuidString,
            clientID: clientID, expiresAt: now().addingTimeInterval(timeout), ruleID: rule.id,
            allowedActions: rule.grantedActions, item: item)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                entries[job.id] = Entry(job: job, continuation: continuation)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(self?.timeout ?? 60))
                    await self?.expire(job.id)
                }
            }
        } onCancel: { Task { await self.cancel(job.id) } }
    }

    func claim(clientID: String) -> AutomationAgentJob? {
        let available = entries.values.filter { $0.job.clientID == clientID && !$0.claimed && $0.job.expiresAt > now() }
            .sorted { $0.job.expiresAt < $1.job.expiresAt }
        guard let entry = available.first else { return nil }
        entries[entry.job.id]?.claimed = true
        return entry.job
    }

    func submit(clientID: String, jobID: String, leaseID: String, decisions: [AutomationAgentDecision]) throws {
        guard let entry = entries[jobID], entry.claimed, entry.job.clientID == clientID,
              entry.job.leaseID == leaseID, entry.job.expiresAt > now(),
              !decisions.isEmpty, decisions.count <= 5,
              decisions.allSatisfy({ entry.job.allowedActions.contains($0.action) }) else { throw AutomationError.unauthorized }
        entries.removeValue(forKey: jobID)
        entry.continuation.resume(returning: decisions)
    }

    func revoke(clientID: String) {
        for id in entries.values.filter({ $0.job.clientID == clientID }).map({ $0.job.id }) { cancel(id) }
    }
    func invalidateAll() { for id in Array(entries.keys) { cancel(id) } }
    private func expire(_ id: String) { cancel(id) }
    private func cancel(_ id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.continuation.resume(throwing: AutomationError.unauthorized)
    }
}

struct AutomationAgentRouter: AutomationAnalyzing {
    let codex: any AutomationAnalyzing
    let broker: AutomationAgentBroker
    func analyze(rule: AutomationRule, item: AutomationInputItem) async throws -> [AutomationAgentDecision] {
        if rule.agentID == "codex.exec.v1" { return try await codex.analyze(rule: rule, item: item) }
        guard rule.agentID.hasPrefix("connection:"), UUID(uuidString: String(rule.agentID.dropFirst(11))) != nil else { throw AutomationError.unauthorized }
        return try await broker.analyze(clientID: String(rule.agentID.dropFirst(11)), rule: rule, item: item)
    }
}
