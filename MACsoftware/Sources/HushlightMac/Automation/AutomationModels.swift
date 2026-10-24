import Foundation
import CryptoKit

enum AutomationAction: String, Codable, CaseIterable, Sendable {
    case notify, createDraft, appendDailyNote, createCalendar, createReminder
}

enum AutomationTrigger: Codable, Equatable, Sendable {
    case morningWeather(cityID: String, timeZoneID: String)
    case mailPoll(scopeID: String, intervalSeconds: Int)
}

struct AutomationRule: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let trigger: AutomationTrigger
    let agentID: String
    /// Captured at creation; enabling and editing cannot broaden this grant.
    let grantedActions: Set<AutomationAction>
    /// Concrete destination per write action, chosen by the user at rule creation.
    let resourceIDs: [AutomationAction: String]
    var enabled: Bool
    let createdAt: Date
    var cursor: String?
    var lastPolledAt: Date?
    var lastAttemptAt: Date?
    var lastAnalysisFailureAt: Date?
    var lastErrorCode: String? = nil
    var moreInputPending = false

    init(id: String, title: String, trigger: AutomationTrigger, grantedActions: Set<AutomationAction>,
         resourceIDs: [AutomationAction: String] = [:],
         enabled: Bool = false, createdAt: Date = Date(), cursor: String? = nil, lastPolledAt: Date? = nil,
         lastAttemptAt: Date? = nil,
         agentID: String = "codex.exec.v1") {
        self.id = id; self.title = title; self.trigger = trigger; self.agentID = agentID
        self.grantedActions = grantedActions
        self.resourceIDs = resourceIDs
        self.enabled = enabled; self.createdAt = createdAt; self.cursor = cursor
        self.lastPolledAt = lastPolledAt; self.lastAttemptAt = lastAttemptAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, trigger, agentID, grantedActions, resourceIDs, enabled, createdAt, cursor, lastPolledAt, lastAttemptAt, lastAnalysisFailureAt, lastErrorCode, moreInputPending
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        id = try value.decode(String.self, forKey: .id)
        title = try value.decode(String.self, forKey: .title)
        trigger = try value.decode(AutomationTrigger.self, forKey: .trigger)
        agentID = try value.decodeIfPresent(String.self, forKey: .agentID) ?? "codex.exec.v1"
        grantedActions = try value.decode(Set<AutomationAction>.self, forKey: .grantedActions)
        resourceIDs = try value.decode([AutomationAction: String].self, forKey: .resourceIDs)
        enabled = try value.decode(Bool.self, forKey: .enabled)
        createdAt = try value.decode(Date.self, forKey: .createdAt)
        cursor = try value.decodeIfPresent(String.self, forKey: .cursor)
        lastPolledAt = try value.decodeIfPresent(Date.self, forKey: .lastPolledAt)
        lastAttemptAt = try value.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        lastAnalysisFailureAt = try value.decodeIfPresent(Date.self, forKey: .lastAnalysisFailureAt)
        lastErrorCode = try value.decodeIfPresent(String.self, forKey: .lastErrorCode)
        moreInputPending = try value.decodeIfPresent(Bool.self, forKey: .moreInputPending) ?? false
    }
}

struct AutomationInputItem: Codable, Sendable, Equatable {
    let sourceID: String
    let occurredAt: Date
    let text: String
    let metadata: [String: String]

    init(sourceID: String, occurredAt: Date, text: String, metadata: [String: String] = [:]) {
        self.sourceID = sourceID; self.occurredAt = occurredAt; self.text = text; self.metadata = metadata
    }
}

struct AutomationInputBatch: Sendable {
    let items: [AutomationInputItem]
    /// Opaque source cursor. It is committed only after every item has a durable run.
    let nextCursor: String?
    var hasMore = false
}

struct AutomationAgentDecision: Codable, Equatable, Sendable {
    let action: AutomationAction
    let title: String
    let body: String
    let confidence: Double
    let classification: String
    let sourceExcerpt: String?
    let eventAt: Date?
    let eventEndAt: Date?
    let timeZoneID: String?
    let requiresApproval: Bool

    init(action: AutomationAction, title: String, body: String, confidence: Double,
         classification: String = "summary", sourceExcerpt: String? = nil,
         eventAt: Date? = nil, eventEndAt: Date? = nil,
         timeZoneID: String? = nil, requiresApproval: Bool = false) {
        self.action = action; self.title = title; self.body = body; self.confidence = confidence
        self.classification = classification; self.sourceExcerpt = sourceExcerpt
        self.eventAt = eventAt; self.eventEndAt = eventEndAt; self.timeZoneID = timeZoneID
        self.requiresApproval = requiresApproval
    }
}

enum AutomationRunStatus: String, Codable, Sendable {
    case analyzing, pendingApproval, applying, succeeded, rejected, failed, unknown
}

struct AutomationRun: Codable, Identifiable, Sendable {
    let id: String
    let ruleID: String
    let sourceID: String
    let startedAt: Date
    var updatedAt: Date
    var status: AutomationRunStatus
    var action: AutomationAction?
    var decisionClassification: String?
    var decisionConfidence: Double?
    var scheduleNote: String?
    var failureCode: String?
}

enum AutomationEffectStatus: String, Codable, Sendable { case reserved, succeeded, rejected, unknown }

struct AutomationEffectRecord: Codable, Identifiable, Sendable {
    let id: String // SHA256(rule ID, source ID, action)
    let runID: String
    let action: AutomationAction
    let reservedAt: Date
    var status: AutomationEffectStatus
    var completedAt: Date?
    var externalID: String?
}

struct AutomationSnapshot: Sendable {
    let rules: [AutomationRule]
    let runs: [AutomationRun]
    let effects: [AutomationEffectRecord]
    var queuedInputCounts: [String: Int] = [:]
    var retryInputCounts: [String: Int] = [:]
}

struct AutomationPendingReview: Sendable {
    let runID: String
    let ruleID: String
    let decision: AutomationAgentDecision
    let expiresAt: Date
}

enum AutomationError: Error, Equatable {
    case invalidRule, ruleExists, ruleMissing, grantExpansion, corruptState, unavailableKey
    case noPendingApproval, expiredApproval, unauthorized, duplicate, unavailableInput, invalidDecision, intakeFull, simulatedResult, runInProgress, staleInput
}

protocol AutomationInputProviding: Sendable {
    func collect(rule: AutomationRule, cursor: String?) async throws -> AutomationInputBatch
    /// Recheck source access before consuming an item saved on an earlier tick.
    func authorize(rule: AutomationRule) async throws
}

extension AutomationInputProviding {
    func authorize(rule: AutomationRule) async throws {}
}

protocol AutomationAnalyzing: Sendable {
    func analyze(rule: AutomationRule, item: AutomationInputItem) async throws -> [AutomationAgentDecision]
}

struct AutomationEffectAuthorization: Sendable {
    let leaseID: UUID
    let validate: @Sendable () async -> Bool
}

protocol AutomationEffectDriving: Sendable {
    func requiresReview(_ decision: AutomationAgentDecision, resourceID: String?,
                        sourceMetadata: [String: String]) async throws -> Bool
    /// Must call authorization.validate() immediately before any external write.
    func apply(_ decision: AutomationAgentDecision, idempotencyKey: String,
               resourceID: String?, sourceMetadata: [String: String],
               authorization: AutomationEffectAuthorization) async throws -> String?
}

extension AutomationEffectDriving {
    func requiresReview(_ decision: AutomationAgentDecision, resourceID: String?,
                        sourceMetadata: [String: String]) async throws -> Bool { false }
}

enum AutomationIdentity {
    static func effect(ruleID: String, sourceID: String, action: AutomationAction) -> String {
        let values = [ruleID, sourceID, action.rawValue]
        let canonical = values.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
