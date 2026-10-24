import Foundation
import BridgeCore

actor AutomationEngine {
    private static let intakeLimit = 200
    private static let analysisAttemptLimit = 3
    private let storage: AutomationStorage
    private let input: any AutomationInputProviding
    private let analyzer: any AutomationAnalyzing
    private let effects: any AutomationEffectDriving
    private let now: @Sendable () -> Date
    private let connectionAuthorization: @Sendable (String) async -> Bool
    private let localTimeZone: @Sendable () -> TimeZone
    private var state: AutomationDiskState
    private var paused = true
    private var authorizationGeneration = 0
    private var activeLease: [String: UUID] = [:]
    private var tickInProgress = false

    init(storageURL: URL, keyProvider: any AutomationKeyProviding = AutomationKeychainKeyProvider(),
         input: any AutomationInputProviding, analyzer: any AutomationAnalyzing,
         effectDriver: any AutomationEffectDriving, now: @escaping @Sendable () -> Date = Date.init,
         localTimeZone: @escaping @Sendable () -> TimeZone = { .current },
         connectionAuthorization: @escaping @Sendable (String) async -> Bool = { _ in false }) throws {
        let storage = AutomationStorage(url: storageURL, keyProvider: keyProvider)
        self.storage = storage; self.input = input; self.analyzer = analyzer
        self.effects = effectDriver; self.now = now; self.localTimeZone = localTimeZone
        self.connectionAuthorization = connectionAuthorization
        var loaded = try storage.load()
        // A crash around a write cannot prove what happened. Never replay it.
        for index in loaded.runs.indices where loaded.runs[index].status == .applying {
            loaded.runs[index].status = .unknown
        }
        for index in loaded.runs.indices where loaded.runs[index].status == .analyzing {
            loaded.runs[index].status = .failed
            loaded.runs[index].failureCode = "analysis_interrupted"
        }
        for index in loaded.effects.indices where loaded.effects[index].status == .reserved {
            loaded.effects[index].status = .unknown
        }
        for (id, bytes) in loaded.pending {
            guard let payload = try? storage.open(bytes), payload.expiresAt > now() else {
                loaded.pending.removeValue(forKey: id)
                if let i = loaded.runs.firstIndex(where: { $0.id == id && $0.status == .pendingApproval }) {
                    loaded.runs[i].status = .rejected
                    loaded.runs[i].failureCode = "pending_expired_or_unreadable"
                }
                continue
            }
        }
        for (key, bytes) in loaded.retryInputs {
            guard let payload = try? storage.openRetry(bytes), payload.expiresAt > now() else {
                loaded.retryInputs.removeValue(forKey: key)
                continue
            }
        }
        for (key, bytes) in loaded.intakeInputs {
            guard let payload = try? storage.openIntake(bytes), payload.expiresAt > now(),
                  key == Self.retryKey(ruleID: payload.ruleID, sourceID: payload.item.sourceID) else {
                loaded.intakeInputs.removeValue(forKey: key)
                continue
            }
        }
        for (key, bytes) in loaded.decisionQueues {
            guard let payload = try? storage.openQueue(bytes), payload.expiresAt > now() else {
                loaded.decisionQueues.removeValue(forKey: key)
                continue
            }
        }
        self.state = loaded
        try storage.save(loaded)
    }

    func snapshot() -> AutomationSnapshot {
        var queued: [String: Int] = [:], retry: [String: Int] = [:]
        for (key, bytes) in state.intakeInputs {
            guard let payload = try? storage.openIntake(bytes), payload.expiresAt > now(),
                  key == Self.retryKey(ruleID: payload.ruleID, sourceID: payload.item.sourceID),
                  state.rules.contains(where: { $0.id == payload.ruleID }) else { continue }
            queued[payload.ruleID, default: 0] += 1
        }
        for (key, bytes) in state.retryInputs {
            guard let payload = try? storage.openRetry(bytes), payload.expiresAt > now(),
                  let rule = state.rules.first(where: {
                      key == Self.retryKey(ruleID: $0.id, sourceID: payload.item.sourceID)
                  }) else { continue }
            retry[rule.id, default: 0] += 1
        }
        return AutomationSnapshot(rules: state.rules, runs: state.runs, effects: state.effects,
                                  queuedInputCounts: queued, retryInputCounts: retry)
    }

    func pendingReview() throws -> [AutomationPendingReview] {
        try state.runs.compactMap { run in
            guard run.status == .pendingApproval, let bytes = state.pending[run.id] else { return nil }
            let payload = try storage.open(bytes)
            guard payload.expiresAt > now() else { return nil }
            return AutomationPendingReview(runID: run.id, ruleID: run.ruleID,
                                           decision: payload.decision, expiresAt: payload.expiresAt)
        }
    }

    func install(rule: AutomationRule) throws {
        try Self.validate(rule)
        guard !state.rules.contains(where: { $0.id == rule.id }) else { throw AutomationError.ruleExists }
        guard !rule.enabled || !state.rules.contains(where: { $0.enabled && Self.sameSource($0, rule) }) else {
            throw AutomationError.duplicate
        }
        let previous = state
        state.rules.append(rule)
        do { try storage.save(state) } catch { state = previous; throw error }
    }

    func setEnabled(_ enabled: Bool, for ruleID: String) throws {
        guard let i = state.rules.firstIndex(where: { $0.id == ruleID }) else { throw AutomationError.ruleMissing }
        if enabled && state.rules.contains(where: { $0.id != ruleID && $0.enabled && Self.sameSource($0, state.rules[i]) }) {
            throw AutomationError.duplicate
        }
        let previous = state
        state.rules[i].enabled = enabled
        do { try storage.save(state) } catch { state = previous; throw error }
        authorizationGeneration += 1
        activeLease.removeAll()
    }

    func setPaused(_ value: Bool) {
        guard paused != value else { return }
        paused = value
        authorizationGeneration += 1
        activeLease.removeAll()
    }

    func tick(paused: Bool) async {
        setPaused(paused)
        expirePending()
        guard !paused, !tickInProgress else { return }
        tickInProgress = true
        defer { tickInProgress = false }
        recordMissedWeatherDays()
        for rule in state.rules.filter(\.enabled).sorted(by: { Self.priority($0) < Self.priority($1) }) {
            guard !self.paused else { return }
            if due(rule, at: now()) {
              do {
                if rule.agentID.hasPrefix("connection:") {
                    guard await connectionAuthorization(String(rule.agentID.dropFirst(11))) else { throw AutomationError.unauthorized }
                }
                if let i = state.rules.firstIndex(where: { $0.id == rule.id }) {
                    let previous = state
                    state.rules[i].lastAttemptAt = now()
                    do { try storage.save(state) } catch { state = previous; throw error }
                }
                let batch = try await input.collect(rule: rule, cursor: rule.cursor)
                guard !self.paused, currentRule(rule.id)?.enabled == true else { return }
                try await input.authorize(rule: rule)
                guard !self.paused, currentRule(rule.id)?.enabled == true else { return }
                try accept(batch: batch, ruleID: rule.id)
            } catch {
                // Scope/permission changes stop this rule only. Transient reads retain their cursor and back off.
                if let i = state.rules.firstIndex(where: { $0.id == rule.id }) {
                    let previous = state
                    let revoked = (error as? AutomationError) == .unauthorized || (error as? StableErrorCode) == .permissionRequired || (error as? MailScopeError)?.stableCode == .permissionRequired
                    state.rules[i].lastErrorCode = revoked ? "scope_or_permission_requires_repair" : "input_or_analysis_incomplete"
                    if revoked { state.rules[i].enabled = false }
                    do { try storage.save(state) } catch { state = previous }
                }
              }
            }
            guard !self.paused, currentRule(rule.id)?.enabled == true else { continue }
            do { try await analyzeNext(for: rule, respectBackoff: true) }
            catch { recordRuleError(ruleID: rule.id, error: error) }
        }
    }

    func retryPendingAnalysis() async {
        guard !paused, !tickInProgress else { return }
        tickInProgress = true
        defer { tickInProgress = false }
        for rule in state.rules.filter(\.enabled).sorted(by: { Self.priority($0) < Self.priority($1) }) {
            do { try await analyzeNext(for: rule, respectBackoff: false) }
            catch { recordRuleError(ruleID: rule.id, error: error) }
        }
    }

    /// App-only explicit invocation of an enabled rule. One per local day, separate from 06:00.
    func runWeatherNow(ruleID: String) async throws {
        guard !paused else { throw AutomationError.unauthorized }
        guard !tickInProgress else { throw AutomationError.runInProgress }
        guard let rule = currentRule(ruleID), rule.enabled,
              case .morningWeather(let cityID, _) = rule.trigger else { throw AutomationError.invalidRule }
        let requestedAt = now(), generation = authorizationGeneration
        let day = Self.localDay(requestedAt, zone: localTimeZone())
        let sourceID = "weather.manual.\(cityID).\(day)"
        let key = Self.retryKey(ruleID: ruleID, sourceID: sourceID)
        guard !state.runs.contains(where: { $0.ruleID == ruleID && $0.sourceID == sourceID }),
              state.intakeInputs[key] == nil, state.retryInputs[key] == nil,
              state.decisionQueues[key] == nil else { throw AutomationError.duplicate }
        tickInProgress = true
        defer { tickInProgress = false }
        do {
            if rule.agentID.hasPrefix("connection:") {
                guard await connectionAuthorization(String(rule.agentID.dropFirst(11))) else { throw AutomationError.unauthorized }
            }
            try await input.authorize(rule: rule)
            let batch = try await input.collect(rule: rule, cursor: nil)
            try Task.checkCancellation()
            try await input.authorize(rule: rule)
            guard generation == authorizationGeneration, !paused, currentRule(ruleID)?.enabled == true,
                  now().timeIntervalSince(requestedAt) >= 0, now().timeIntervalSince(requestedAt) < 900,
                  day == Self.localDay(now(), zone: localTimeZone()), batch.items.count == 1,
                  let original = batch.items.first else { throw AutomationError.unavailableInput }
            var metadata = original.metadata
            metadata["day"] = day
            metadata["source"] = sourceID
            metadata["manualWeatherRequestedAt"] = ISO8601DateFormatter().string(from: requestedAt)
            let item = AutomationInputItem(sourceID: sourceID, occurredAt: requestedAt,
                                           text: original.text, metadata: metadata)
            try accept(batch: .init(items: [item], nextCursor: nil), ruleID: ruleID, commitPollingState: false)
            try await process(ruleID: ruleID, item: item)
        } catch {
            // Local pause/disable invalidates this invocation, not the saved rule's authorization.
            if !paused, generation == authorizationGeneration { recordRuleError(ruleID: ruleID, error: error) }
            throw error
        }
    }

    private func recordRuleError(ruleID: String, error: Error) {
        guard let index = state.rules.firstIndex(where: { $0.id == ruleID }) else { return }
        let previous = state
        let revoked = (error as? AutomationError) == .unauthorized ||
            (error as? StableErrorCode) == .permissionRequired ||
            (error as? MailScopeError)?.stableCode == .permissionRequired
        state.rules[index].lastErrorCode = revoked ? "scope_or_permission_requires_repair" : "input_or_analysis_incomplete"
        if revoked { state.rules[index].enabled = false }
        do { try storage.save(state) } catch { state = previous }
    }

    private static func priority(_ rule: AutomationRule) -> Int {
        if case .morningWeather = rule.trigger { return 0 }
        return 1
    }

    private func accept(batch: AutomationInputBatch, ruleID: String, commitPollingState: Bool = true) throws {
        guard let index = state.rules.firstIndex(where: { $0.id == ruleID }), state.rules[index].enabled,
              !paused else { throw AutomationError.unauthorized }
        let previous = state
        var additions: [String: Data] = [:]
        for item in batch.items {
            guard !item.sourceID.isEmpty, item.sourceID.count <= 512,
                  item.text.utf8.count <= 24_000 else { throw AutomationError.unavailableInput }
            let key = Self.retryKey(ruleID: ruleID, sourceID: item.sourceID)
            if state.intakeInputs[key] != nil || state.retryInputs[key] != nil ||
                state.decisionQueues[key] != nil || additions[key] != nil ||
                state.runs.contains(where: { $0.ruleID == ruleID && $0.sourceID == item.sourceID &&
                    ($0.status != .failed || $0.failureCode == "analysis_retry_exhausted") }) { continue }
            additions[key] = try storage.sealIntake(AutomationIntakePayload(ruleID: ruleID, item: item,
                acceptedAt: now(), expiresAt: now().addingTimeInterval(7 * 24 * 3600),
                sequence: state.intakeSequence + additions.count))
        }
        guard state.intakeInputs.count + state.retryInputs.count + additions.count <= Self.intakeLimit else {
            throw AutomationError.intakeFull
        }
        state.intakeInputs.merge(additions) { old, _ in old }
        state.intakeSequence += additions.count
        if commitPollingState {
            state.rules[index].cursor = batch.nextCursor ?? state.rules[index].cursor
            state.rules[index].lastPolledAt = now()
            state.rules[index].moreInputPending = batch.hasMore
        }
        state.rules[index].lastErrorCode = nil
        do { try storage.save(state) } catch { state = previous; throw error }
    }

    private func analyzeNext(for rule: AutomationRule, respectBackoff: Bool) async throws {
        guard !paused, let current = currentRule(rule.id), current.enabled else { return }
        let queued = state.decisionQueues.compactMap { key, bytes -> (String, AutomationDecisionQueue)? in
            guard let queue = try? storage.openQueue(bytes), queue.ruleID == rule.id,
                  queue.expiresAt > now() else { return nil }
            guard weatherMetadataIsCurrent(queue.sourceMetadata, rule: current) else { return nil }
            return (key, queue)
        }.sorted(by: { $0.1.expiresAt < $1.1.expiresAt }).first
        let retry = state.retryInputs.compactMap { key, bytes -> (String, AutomationRetryPayload)? in
            guard let payload = try? storage.openRetry(bytes), payload.expiresAt > now(),
                  weatherInputIsCurrent(payload.item, rule: current),
                  key == Self.retryKey(ruleID: rule.id, sourceID: payload.item.sourceID),
                  (!respectBackoff || payload.attempts < Self.analysisAttemptLimit) else { return nil }
            return (key, payload)
        }.sorted { $0.1.item.occurredAt < $1.1.item.occurredAt }.first
        let intake = state.intakeInputs.compactMap { key, bytes -> (String, AutomationIntakePayload)? in
            guard let payload = try? storage.openIntake(bytes), payload.ruleID == rule.id,
                  payload.expiresAt > now(), weatherInputIsCurrent(payload.item, rule: current),
                  key == Self.retryKey(ruleID: rule.id, sourceID: payload.item.sourceID) else { return nil }
            return (key, payload)
        }.sorted { $0.1.sequence < $1.1.sequence }.first
        guard queued != nil || retry != nil || intake != nil else { return }
        if queued == nil, respectBackoff, let failure = current.lastAnalysisFailureAt,
           now().timeIntervalSince(failure) < 300 { return }
        if current.agentID.hasPrefix("connection:") {
            guard await connectionAuthorization(String(current.agentID.dropFirst(11))) else {
                throw AutomationError.unauthorized
            }
        }
        try await input.authorize(rule: current)
        guard !paused, currentRule(rule.id)?.enabled == true else { throw AutomationError.unauthorized }
        if let queued {
            try await executeQueue(queued.1, key: queued.0)
            return
        }
        // A failed item gets a bounded retry; a new intake item never shares its tick.
        if let retry, (intake == nil || retry.1.item.occurredAt <= intake!.1.item.occurredAt) {
            try await process(ruleID: rule.id, item: retry.1.item)
        } else if let intake {
            try await process(ruleID: rule.id, item: intake.1.item)
        }
    }

    private func weatherInputIsCurrent(_ item: AutomationInputItem, rule: AutomationRule) -> Bool {
        guard case .morningWeather = rule.trigger else { return true }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = localTimeZone()
        return calendar.isDate(item.occurredAt, inSameDayAs: now()) && weatherMetadataIsCurrent(item.metadata, rule: rule)
    }

    private func weatherMetadataIsCurrent(_ metadata: [String: String], rule: AutomationRule) -> Bool {
        guard case .morningWeather = rule.trigger else { return true }
        if let value = metadata["manualWeatherRequestedAt"] {
            guard let requested = ISO8601DateFormatter().date(from: value) else { return false }
            let age = now().timeIntervalSince(requested)
            return age >= 0 && age < 900 && metadata["day"] == Self.localDay(now(), zone: localTimeZone())
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = localTimeZone()
        return calendar.component(.hour, from: now()) < 8 &&
            (metadata["day"] == nil || metadata["day"] == Self.localDay(now(), zone: localTimeZone()))
    }

    func resolve(runID: String, approve: Bool,
                 correctedDecision: AutomationAgentDecision? = nil) async throws {
        guard let run = state.runs.first(where: { $0.id == runID }),
              run.status == .pendingApproval, let bytes = state.pending[runID] else {
            throw AutomationError.noPendingApproval
        }
        let payload = try storage.open(bytes)
        guard payload.expiresAt > now() else {
            expirePending()
            throw AutomationError.expiredApproval
        }
        guard !paused, currentRule(run.ruleID)?.enabled == true else { throw AutomationError.unauthorized }
        if !approve {
            let previous = state
            updateRun(runID, status: .rejected)
            state.pending.removeValue(forKey: runID)
            do { try storage.save(state) } catch { state = previous; throw error }
            return
        }
        let decision = correctedDecision ?? payload.decision
        guard decision.action == payload.decision.action,
              decision.title.count <= 120, decision.body.count <= 4_000,
              ![AutomationAction.createCalendar, .createReminder].contains(decision.action) ||
              (decision.eventAt != nil && decision.timeZoneID != nil &&
               (decision.action != .createCalendar || decision.eventEndAt != nil)) else {
            throw AutomationError.invalidDecision
        }
        do {
            try await apply(decision: decision, runID: runID, ruleID: run.ruleID,
                            sourceID: run.sourceID, sourceMetadata: payload.sourceMetadata)
            state.pending.removeValue(forKey: runID)
            try storage.save(state)
        } catch {
            // A reserved effect may have reached the external app; retain unknown, never replay.
            if state.effects.contains(where: { $0.runID == runID }) {
                state.pending.removeValue(forKey: runID)
                try storage.save(state)
            }
            throw error
        }
    }

    private func process(ruleID: String, item: AutomationInputItem) async throws {
        guard let rule = currentRule(ruleID), rule.enabled else { throw AutomationError.unauthorized }
        let queueKey = Self.retryKey(ruleID: ruleID, sourceID: item.sourceID)
        if let queueBytes = state.decisionQueues[queueKey] {
            try await executeQueue(storage.openQueue(queueBytes), key: queueKey)
            return
        }
        let prior = state.runs.filter { $0.ruleID == ruleID && $0.sourceID == item.sourceID }
        guard prior.isEmpty || prior.last?.status == .failed || state.retryInputs[queueKey] != nil else { return }
        guard !item.sourceID.isEmpty, item.sourceID.count <= 512, item.text.utf8.count <= 24_000 else {
            throw AutomationError.unavailableInput
        }
        let runID = UUID().uuidString
        let beforeAdmission = state
        let priorRetry = state.retryInputs[queueKey].flatMap { try? storage.openRetry($0) }
        let attempts = (priorRetry?.attempts ?? 0) + 1
        state.runs.append(AutomationRun(id: runID, ruleID: ruleID, sourceID: item.sourceID,
                                        startedAt: now(), updatedAt: now(), status: .analyzing, action: nil,
                                        decisionClassification: nil, decisionConfidence: nil,
                                        scheduleNote: item.metadata["manualWeatherRequestedAt"] == nil ? Self.scheduleNote(rule: rule, at: now(), zone: localTimeZone()) : "manual_weather_check",
                                        failureCode: nil))
        state.retryInputs[queueKey] = try storage.sealRetry(
            AutomationRetryPayload(item: item, expiresAt: priorRetry?.expiresAt ?? now().addingTimeInterval(7 * 24 * 3600), attempts: attempts))
        state.intakeInputs.removeValue(forKey: queueKey)
        do { try storage.save(state) } catch { state = beforeAdmission; throw error }
        let generation = authorizationGeneration
        let decisions: [AutomationAgentDecision]
        do {
            if item.metadata["bodyUnavailable"] == "true" {
                decisions = [.init(action: .notify, title: "邮件需人工查看", body: "正文无法核实，请到 Apple Mail 查看原邮件。", confidence: 1, classification: "uncertain", requiresApproval: true)]
            } else {
                decisions = try await analyzer.analyze(rule: rule, item: item)
            }
        }
        catch is CancellationError {
            updateRun(runID, status: .failed, failureCode: "analysis_cancelled")
            if let i = state.rules.firstIndex(where: { $0.id == ruleID }) { state.rules[i].lastAnalysisFailureAt = now() }
            try storage.save(state)
            throw CancellationError() // keep encrypted input for retry; never issue fallback after cancellation
        }
        catch {
            updateRun(runID, status: .failed, failureCode: attempts >= Self.analysisAttemptLimit ?
                "analysis_retry_exhausted" : ((error as? CodexAutomationError)?.failureCode ?? "analysis_failed"))
            if let i = state.rules.firstIndex(where: { $0.id == ruleID }) { state.rules[i].lastAnalysisFailureAt = now() }
            try storage.save(state)
            if case .morningWeather = rule.trigger {
                try? await weatherFallback(rule: rule, item: item)
            }
            throw error
        }
        guard generation == authorizationGeneration, !paused,
              let current = currentRule(ruleID), current.enabled,
              !decisions.isEmpty, decisions.count <= 5,
              Set(decisions.map(\.action)).count == decisions.count,
              decisions.allSatisfy({ current.grantedActions.contains($0.action) }) else {
            updateRun(runID, status: .rejected, failureCode: "authorization_changed")
            state.retryInputs.removeValue(forKey: queueKey)
            try storage.save(state)
            throw AutomationError.unauthorized
        }
        guard weatherInputIsCurrent(item, rule: current) else {
            updateRun(runID, status: .rejected, failureCode: "weather_input_expired")
            state.retryInputs.removeValue(forKey: queueKey)
            try storage.save(state)
            throw AutomationError.staleInput
        }
        guard decisions.allSatisfy({ decision in
            decision.confidence.isFinite && (0...1).contains(decision.confidence) &&
            !decision.title.isEmpty && decision.title.count <= 120 &&
            !decision.body.isEmpty && decision.body.count <= 4_000 &&
            ["summary", "important", "ads", "uncertain"].contains(decision.classification) &&
            (decision.sourceExcerpt?.count ?? 0) <= 600 &&
            (decision.timeZoneID == nil || TimeZone(identifier: decision.timeZoneID!) != nil) &&
            (decision.sourceExcerpt == nil || item.text.contains(decision.sourceExcerpt!))
        }) else {
            updateRun(runID, status: .rejected, failureCode: "invalid_decision")
            state.retryInputs.removeValue(forKey: queueKey)
            try storage.save(state)
            throw AutomationError.invalidDecision
        }
        // Ads may only produce a silent metadata outcome. A model cannot attach writes to an ad classification.
        guard !decisions.contains(where: { $0.classification == "ads" && $0.action != .notify }) else {
            updateRun(runID, status: .failed, failureCode: "invalid_advertisement_actions")
            state.retryInputs.removeValue(forKey: queueKey)
            try storage.save(state)
            throw AutomationError.invalidDecision
        }
        let previous = state
        state.decisionQueues[queueKey] = try storage.sealQueue(AutomationDecisionQueue(
            ruleID: ruleID, sourceID: item.sourceID, decisions: decisions,
            sourceMetadata: item.metadata, expiresAt: decisionDeadline(item: item, rule: current)))
        state.retryInputs.removeValue(forKey: queueKey)
        if let i = state.rules.firstIndex(where: { $0.id == ruleID }) { state.rules[i].lastAnalysisFailureAt = nil }
        do { try storage.save(state) } catch { state = previous; throw error }
        try await executeQueue(storage.openQueue(state.decisionQueues[queueKey]!), key: queueKey)
    }

    private func decisionDeadline(item: AutomationInputItem, rule: AutomationRule) -> Date {
        guard case .morningWeather = rule.trigger else { return now().addingTimeInterval(7 * 24 * 3600) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = localTimeZone()
        if let value = item.metadata["manualWeatherRequestedAt"],
           let requested = ISO8601DateFormatter().date(from: value) {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: requested)) ?? requested
            return min(requested.addingTimeInterval(900), nextDay)
        }
        return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: now()) ?? now()
    }

    private func executeQueue(_ queue: AutomationDecisionQueue, key: String) async throws {
        guard !paused, let rule = currentRule(queue.ruleID), rule.enabled else { throw AutomationError.unauthorized }
        guard weatherMetadataIsCurrent(queue.sourceMetadata, rule: rule) else { throw AutomationError.staleInput }
        if rule.agentID.hasPrefix("connection:") {
            guard await connectionAuthorization(String(rule.agentID.dropFirst(11))) else { throw AutomationError.unauthorized }
        }
        try await input.authorize(rule: rule)
        for decision in queue.decisions {
            try Task.checkCancellation()
            guard !paused, currentRule(queue.ruleID)?.enabled == true else { throw AutomationError.unauthorized }
            guard weatherMetadataIsCurrent(queue.sourceMetadata, rule: rule) else { throw AutomationError.staleInput }
            if state.runs.contains(where: { $0.ruleID == queue.ruleID && $0.sourceID == queue.sourceID &&
                $0.action == decision.action && [.pendingApproval, .succeeded, .rejected, .unknown].contains($0.status) }) {
                continue
            }
            let runID: String
            if let i = state.runs.lastIndex(where: { $0.ruleID == queue.ruleID && $0.sourceID == queue.sourceID &&
                $0.action == nil && [.failed, .analyzing].contains($0.status) }) {
                runID = state.runs[i].id
            } else {
                runID = UUID().uuidString
                let previous = state
                state.runs.append(AutomationRun(id: runID, ruleID: queue.ruleID, sourceID: queue.sourceID,
                    startedAt: now(), updatedAt: now(), status: .analyzing, action: nil,
                    decisionClassification: nil, decisionConfidence: nil,
                    scheduleNote: queue.sourceMetadata["manualWeatherRequestedAt"] == nil ? Self.scheduleNote(rule: rule, at: now(), zone: localTimeZone()) : "manual_weather_check", failureCode: nil))
                do { try storage.save(state) } catch { state = previous; throw error }
            }
            let needsEvidenceReview = [.createCalendar, .createReminder].contains(decision.action) &&
                !Self.hasExplicitEventEvidence(decision)
            let preflightReview: Bool
            do {
                preflightReview = try await effects.requiresReview(decision,
                    resourceID: rule.resourceIDs[decision.action], sourceMetadata: queue.sourceMetadata)
            } catch {
                // Preflight is read-only; an unavailable result requires review.
                preflightReview = true
            }
            guard !paused, currentRule(queue.ruleID)?.enabled == true else { throw AutomationError.unauthorized }
            guard weatherMetadataIsCurrent(queue.sourceMetadata, rule: rule) else { throw AutomationError.staleInput }
            let previous = state
            if let i = state.runs.firstIndex(where: { $0.id == runID }) {
                state.runs[i].action = decision.action
                state.runs[i].decisionClassification = decision.classification
                state.runs[i].decisionConfidence = decision.confidence
            }
            if decision.requiresApproval || decision.classification == "uncertain" ||
                needsEvidenceReview || preflightReview {
                state.pending[runID] = try storage.seal(AutomationPendingPayload(
                    decision: decision, expiresAt: queue.expiresAt, sourceMetadata: queue.sourceMetadata))
                updateRun(runID, status: .pendingApproval)
                do { try storage.save(state) } catch { state = previous; throw error }
            } else {
                do { try storage.save(state) } catch { state = previous; throw error }
                do {
                    try await apply(decision: decision, runID: runID, ruleID: queue.ruleID,
                                    sourceID: queue.sourceID, sourceMetadata: queue.sourceMetadata)
                } catch {
                    // The write may have occurred. Its effect is unknown; continue other independent actions.
                    if !state.effects.contains(where: { $0.runID == runID }) { throw error }
                }
            }
        }
        let completed = queue.decisions.allSatisfy { decision in
            state.runs.contains { $0.ruleID == queue.ruleID && $0.sourceID == queue.sourceID &&
                $0.action == decision.action && [.pendingApproval, .succeeded, .rejected, .unknown].contains($0.status) }
        }
        if completed {
            let previous = state
            state.decisionQueues.removeValue(forKey: key)
            do { try storage.save(state) } catch { state = previous; throw error }
        }
    }

    private func weatherFallback(rule: AutomationRule, item: AutomationInputItem) async throws {
        guard rule.grantedActions.contains(.notify),
              !state.effects.contains(where: { $0.id == AutomationIdentity.effect(
                ruleID: rule.id, sourceID: item.sourceID, action: .notify) }) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let report = try? decoder.decode(WeatherReport.self, from: Data(item.text.utf8)) else { return }
        let temperature = String(format: "%.1f", report.current.temperatureC)
        let symbol = report.current.symbol.map { "，\($0)" } ?? ""
        let decision = AutomationAgentDecision(action: .notify, title: "\(report.city.name)天气",
            body: "当前 \(temperature)°C\(symbol)。AI分析未完成，稍后重试。", confidence: 1)
        let runID = UUID().uuidString
        let previous = state
        state.runs.append(AutomationRun(id: runID, ruleID: rule.id, sourceID: item.sourceID,
            startedAt: now(), updatedAt: now(), status: .analyzing, action: .notify,
            decisionClassification: "summary", decisionConfidence: nil,
            scheduleNote: "ai_analysis_incomplete", failureCode: nil))
        do { try storage.save(state) } catch { state = previous; throw error }
        try await apply(decision: decision, runID: runID, ruleID: rule.id,
                        sourceID: item.sourceID, sourceMetadata: item.metadata)
    }

    private func apply(decision: AutomationAgentDecision, runID: String, ruleID: String,
                       sourceID: String, sourceMetadata: [String: String]) async throws {
        let effectID = AutomationIdentity.effect(ruleID: ruleID, sourceID: sourceID, action: decision.action)
        guard !state.effects.contains(where: { $0.id == effectID }) else { throw AutomationError.duplicate }
        guard !paused, let rule = currentRule(ruleID), rule.enabled,
              rule.grantedActions.contains(decision.action) else { throw AutomationError.unauthorized }
        guard weatherMetadataIsCurrent(sourceMetadata, rule: rule) else { throw AutomationError.staleInput }
        let beforeReservation = state
        state.effects.append(AutomationEffectRecord(id: effectID, runID: runID, action: decision.action,
                                                    reservedAt: now(), status: .reserved,
                                                    completedAt: nil, externalID: nil))
        updateRun(runID, status: .applying)
        do { try storage.save(state) }
        catch { state = beforeReservation; throw error } // no write attempted
        let lease = UUID(), generation = authorizationGeneration
        activeLease[effectID] = lease
        defer { activeLease.removeValue(forKey: effectID) }
        let authorization = AutomationEffectAuthorization(leaseID: lease) { [weak self] in
            guard let self else { return false }
            return await self.validateLease(effectID: effectID, ruleID: ruleID,
                                            action: decision.action, lease: lease, generation: generation, sourceMetadata: sourceMetadata)
        }
        do {
            let externalID = try await effects.apply(decision, idempotencyKey: effectID,
                                                     resourceID: rule.resourceIDs[decision.action],
                                                     sourceMetadata: sourceMetadata,
                                                     authorization: authorization)
            guard await validateLease(effectID: effectID, ruleID: ruleID, action: decision.action,
                                lease: lease, generation: generation, sourceMetadata: sourceMetadata) else {
                updateEffect(effectID, status: .unknown)
                updateRun(runID, status: .unknown, failureCode: "late_or_revoked_result")
                try storage.save(state)
                return
            }
            updateEffect(effectID, status: .succeeded, externalID: externalID)
            updateRun(runID, status: .succeeded)
            try storage.save(state)
        } catch {
            let simulated = (error as? AutomationError) == .simulatedResult
            let rejected = (error as? AutomationError) == .unauthorized || simulated
            updateEffect(effectID, status: rejected ? .rejected : .unknown)
            updateRun(runID, status: rejected ? .rejected : .unknown, failureCode: simulated ? "simulation_not_allowed" : (rejected ? "permission_required" : "effect_unverifiable"))
            try storage.save(state)
            throw error
        }
        activeLease.removeValue(forKey: effectID)
    }

    private func validateLease(effectID: String, ruleID: String, action: AutomationAction,
                               lease: UUID, generation: Int, sourceMetadata: [String: String]) async -> Bool {
        if let rule = currentRule(ruleID), rule.agentID.hasPrefix("connection:") {
            guard await connectionAuthorization(String(rule.agentID.dropFirst(11))) else { return false }
        }
        return !Task.isCancelled && !paused && generation == authorizationGeneration && activeLease[effectID] == lease &&
            currentRule(ruleID).map { $0.enabled && $0.grantedActions.contains(action) && weatherMetadataIsCurrent(sourceMetadata, rule: $0) } == true
    }

    private func currentRule(_ id: String) -> AutomationRule? { state.rules.first { $0.id == id } }

    private func updateRun(_ id: String, status: AutomationRunStatus, failureCode: String? = nil) {
        guard let i = state.runs.firstIndex(where: { $0.id == id }) else { return }
        state.runs[i].status = status; state.runs[i].updatedAt = now()
        state.runs[i].failureCode = failureCode
    }

    private func updateEffect(_ id: String, status: AutomationEffectStatus, externalID: String? = nil) {
        guard let i = state.effects.firstIndex(where: { $0.id == id }) else { return }
        state.effects[i].status = status; state.effects[i].completedAt = now()
        state.effects[i].externalID = externalID
    }

    private func expirePending() {
        let previous = state
        for (id, data) in state.pending {
            if let payload = try? storage.open(data), payload.expiresAt > now() { continue }
            state.pending.removeValue(forKey: id)
            updateRun(id, status: .rejected, failureCode: "pending_expired_or_unreadable")
        }
        for (key, data) in state.retryInputs {
            if let payload = try? storage.openRetry(data), payload.expiresAt > now() { continue }
            state.retryInputs.removeValue(forKey: key)
        }
        for (key, data) in state.intakeInputs {
            guard let payload = try? storage.openIntake(data), payload.expiresAt > now(),
                  key == Self.retryKey(ruleID: payload.ruleID, sourceID: payload.item.sourceID) else {
                state.intakeInputs.removeValue(forKey: key)
                continue
            }
        }
        for (key, data) in state.decisionQueues {
            if let payload = try? storage.openQueue(data), payload.expiresAt > now() { continue }
            state.decisionQueues.removeValue(forKey: key)
        }
        do { try storage.save(state) } catch { state = previous }
    }

    private func due(_ rule: AutomationRule, at date: Date) -> Bool {
        // Successful mail pages resume on the next background tick; failed reads/analysis retain backoff.
        let continuingMail: Bool
        if case .mailPoll = rule.trigger { continuingMail = rule.moreInputPending && rule.lastErrorCode == nil }
        else { continuingMail = false }
        if let attempt = rule.lastAttemptAt, date.timeIntervalSince(attempt) < (continuingMail ? 15 : 300) { return false }
        switch rule.trigger {
        case .morningWeather:
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = localTimeZone()
            let hour = calendar.component(.hour, from: date)
            guard hour >= 6 && hour < 8 else { return false }
            return rule.lastPolledAt.map { !calendar.isDate($0, inSameDayAs: date) } ?? true
        case .mailPoll(_, let interval):
            return continuingMail || (rule.lastPolledAt.map { date.timeIntervalSince($0) >= Double(interval) } ?? true)
        }
    }

    private func recordMissedWeatherDays() {
        guard !paused else { return }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = localTimeZone()
        guard calendar.component(.hour, from: now()) >= 8 else { return }
        let day = Self.localDay(now(), zone: localTimeZone())
        for rule in state.rules where rule.enabled {
            guard case .morningWeather(let cityID, _) = rule.trigger else { continue }
            if let polled = rule.lastPolledAt, calendar.isDate(polled, inSameDayAs: now()) { continue }
            let source = "weather.\(cityID).\(day)"
            if state.runs.contains(where: { $0.ruleID == rule.id && $0.sourceID == source }) { continue }
            let previous = state
            state.runs.append(AutomationRun(id: UUID().uuidString, ruleID: rule.id, sourceID: source,
                startedAt: now(), updatedAt: now(), status: .failed, action: nil,
                decisionClassification: nil, decisionConfidence: nil,
                scheduleNote: "missed_after_08_local", failureCode: "weather_window_missed"))
            do { try storage.save(state) } catch { state = previous }
        }
    }

    private static func localDay(_ date: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func scheduleNote(rule: AutomationRule, at date: Date, zone: TimeZone) -> String? {
        guard case .morningWeather = rule.trigger else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return hour > 6 || minute > 0 ? "late_catchup_before_08_local" : nil
    }

    private static func sameSource(_ a: AutomationRule, _ b: AutomationRule) -> Bool {
        switch (a.trigger, b.trigger) {
        case (.morningWeather(let cityA, _), .morningWeather(let cityB, _)): return cityA == cityB
        case (.mailPoll(let scopeA, _), .mailPoll(let scopeB, _)): return scopeA == scopeB
        default: return false
        }
    }

    private static func retryKey(ruleID: String, sourceID: String) -> String {
        AutomationIdentity.effect(ruleID: ruleID, sourceID: sourceID, action: .notify)
    }

    private static func hasExplicitEventEvidence(_ decision: AutomationAgentDecision) -> Bool {
        guard let excerpt = decision.sourceExcerpt, let date = decision.eventAt,
              let zoneID = decision.timeZoneID, let zone = TimeZone(identifier: zoneID) else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let hour = parts.hour, let minute = parts.minute else { return false }
        let dayText = String(format: "%04d-%02d-%02d", year, month, day)
        let timeText = String(format: "%02d:%02d", hour, minute)
        return excerpt.localizedCaseInsensitiveContains(decision.title) && excerpt.contains(dayText) && excerpt.contains(timeText) && excerpt.contains(zoneID)
            && (decision.action != .createCalendar || Self.hasExplicitEndEvidence(decision, excerpt: excerpt, calendar: calendar))
    }

    private static func hasExplicitEndEvidence(_ decision: AutomationAgentDecision, excerpt: String,
                                               calendar: Calendar) -> Bool {
        guard let start = decision.eventAt, let end = decision.eventEndAt, end > start else { return false }
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: end)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let hour = parts.hour, let minute = parts.minute else { return false }
        let dayText = String(format: "%04d-%02d-%02d", year, month, day)
        let timeText = String(format: "%02d:%02d", hour, minute)
        return excerpt.contains(dayText) && excerpt.contains(timeText)
    }

    private static func validate(_ rule: AutomationRule) throws {
        guard !rule.id.isEmpty, rule.id.count <= 128, !rule.title.isEmpty, rule.title.count <= 120,
              !rule.grantedActions.isEmpty, (rule.agentID == "codex.exec.v1" || (rule.agentID.hasPrefix("connection:") && UUID(uuidString: String(rule.agentID.dropFirst(11))) != nil)) else { throw AutomationError.invalidRule }
        for action in [AutomationAction.createDraft, .appendDailyNote, .createCalendar, .createReminder] {
            if rule.grantedActions.contains(action),
               (rule.resourceIDs[action]?.isEmpty != false || rule.resourceIDs[action]!.count > 256) {
                throw AutomationError.invalidRule
            }
        }
        switch rule.trigger {
        case .morningWeather(let city, let zone):
            guard !city.isEmpty, city.count <= 128, TimeZone(identifier: zone) != nil,
                  rule.grantedActions.isSubset(of: [.notify, .appendDailyNote]) else { throw AutomationError.invalidRule }
        case .mailPoll(let scope, let interval):
            guard !scope.isEmpty, scope.count <= 256, interval >= 300,
                  rule.grantedActions.isSubset(of: [.notify, .createDraft, .appendDailyNote,
                                                    .createCalendar, .createReminder]) else { throw AutomationError.invalidRule }
        }
    }
}
