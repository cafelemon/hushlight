import BridgeCore
import CryptoKit
import Foundation
import UserNotifications

/// Source collection runs only after a rule is explicitly installed and enabled.
struct BridgeAutomationInput: AutomationInputProviding {
    let bridge: any BridgeService
    private let mailAuthorization: @Sendable () async -> Bool

    init(bridge: any BridgeService, mailAuthorization: @escaping @Sendable () async -> Bool = {
        await AppleEventPermission.prepareRunningTarget(bundleID: "com.apple.mail") == .granted
    }) {
        self.bridge = bridge
        self.mailAuthorization = mailAuthorization
    }

    func authorize(rule: AutomationRule) async throws {
        try Task.checkCancellation()
        guard try await bridge.workbenchState().status != "paused" else { throw AutomationError.unauthorized }
        if case .mailPoll(let scopeID, _) = rule.trigger {
            guard try await bridge.selectedMailScope()?.scopeID == scopeID,
                  await mailAuthorization() else { throw AutomationError.unauthorized }
        }
    }

    func collect(rule: AutomationRule, cursor: String?) async throws -> AutomationInputBatch {
        try await BridgeExecutionContext.$backgroundAutomation.withValue(true) {
            try await collectGranted(rule: rule, cursor: cursor)
        }
    }
    private func collectGranted(rule: AutomationRule, cursor: String?) async throws -> AutomationInputBatch {
        try await authorize(rule: rule)
        switch rule.trigger {
        case .morningWeather(let cityID, _):
            let result = try await bridge.readWeather(cityID: cityID)
            guard result.status == "succeeded", let report = result.report, !result.isSimulation else { throw AutomationError.unavailableInput }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let text = String(decoding: try encoder.encode(report), as: UTF8.self)
            let day = Self.day(Date())
            return AutomationInputBatch(items: [.init(sourceID: "weather.\(cityID).\(day)", occurredAt: Date(), text: text,
                metadata: ["day": day, "source": "weather.\(cityID)", "city": report.city.name])], nextCursor: nil)
        case .mailPoll(let scopeID, _):
            let decoder = JSONDecoder()
            let baseline: MailIncrementalCursor
            if let cursor, let bytes = cursor.data(using: .utf8) { baseline = try decoder.decode(MailIncrementalCursor.self, from: bytes) }
            else { baseline = try await bridge.mailBaseline() }
            guard baseline.scopeID == scopeID else { throw AutomationError.unauthorized }
            let batch = try await bridge.pollMail(after: baseline)
            let sender = try await bridge.mailSender()
            var items: [AutomationInputItem] = []
            for message in batch.messages {
                try Task.checkCancellation()
                guard try await bridge.workbenchState().status != "paused",
                      try await bridge.selectedMailScope()?.scopeID == scopeID else { throw AutomationError.unauthorized }
                let replyTo = Self.address(message.sender)
                var metadata = ["day": Self.day(Date()), "source": message.id, "sender": sender,
                                "replyTo": replyTo ?? "", "subject": message.subject, "scopeID": scopeID]
                let header = "Subject: \(message.subject)\nFrom: \(message.sender)\nReceived: \(ISO8601DateFormatter().string(from: message.receivedAt))"
                let result: LocalMailCommandResult?
                do { result = try await bridge.readMail(id: message.id) }
                catch is CancellationError { throw CancellationError() }
                catch { result = nil }
                try Task.checkCancellation()
                let text: String
                if let result, result.status == "succeeded", let mail = result.mail, !result.isSimulation {
                    text = header + "\n\n" + mail.text
                } else {
                    // A deleted, oversized or otherwise unreadable message must not hold the entire cursor hostage.
                    // Retain metadata for human review; do not let the model fabricate a body or downstream writes.
                    metadata["bodyUnavailable"] = "true"
                    text = header
                }
                items.append(.init(sourceID: message.id, occurredAt: message.receivedAt,
                    text: Self.prefixUTF8(text, bytes: 24_000), metadata: metadata))
            }
            return AutomationInputBatch(items: items, nextCursor: String(decoding: try JSONEncoder().encode(batch.nextCursor), as: UTF8.self), hasMore: batch.hasMore)
        }
    }

    static func prefixUTF8(_ text: String, bytes: Int) -> String {
        var result = "", count = 0
        for character in text {
            let width = String(character).utf8.count
            if count + width > bytes { break }
            result.append(character); count += width
        }
        return result
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.timeZone = .current; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func address(_ source: String) -> String? {
        var value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let begin = value.lastIndex(of: "<"), value.hasSuffix(">") { value = String(value[value.index(after: begin)..<value.index(before: value.endIndex)]) }
        guard (try? MailDraftInput(sender: value, to: [value], subject: "Address validation", text: "").validate()) != nil else { return nil }
        return value
    }
}

/// All actual automation writes share the App's BridgeService and global pause.
actor BridgeAutomationEffects: AutomationEffectDriving {
    let bridge: any BridgeService
    init(bridge: any BridgeService) { self.bridge = bridge }

    func requiresReview(_ decision: AutomationAgentDecision, resourceID: String?, sourceMetadata: [String: String]) async throws -> Bool {
        if decision.action == .createCalendar {
            guard let start = decision.eventAt, let end = decision.eventEndAt, end > start else { return true }
            return try await bridge.calendarConflict(start: start, end: end)
        }
        return false
    }
    func apply(_ decision: AutomationAgentDecision, idempotencyKey: String, resourceID: String?,
               sourceMetadata: [String: String], authorization: AutomationEffectAuthorization) async throws -> String? {
        let bridge = self.bridge
        let scopedAuthorization = AutomationEffectAuthorization(leaseID: authorization.leaseID) {
            guard await authorization.validate() else { return false }
            if let scopeID = sourceMetadata["scopeID"] {
                guard let selected = try? await bridge.selectedMailScope(), selected.scopeID == scopeID else { return false }
            }
            return await authorization.validate()
        }
        return try await BridgeExecutionContext.$backgroundAutomation.withValue(true) {
            try await BridgeExecutionContext.$callerID.withValue("automation") {
                try await BridgeExecutionContext.$mailScopeID.withValue(sourceMetadata["scopeID"]) {
                    try await applyGranted(decision, idempotencyKey: idempotencyKey, resourceID: resourceID, sourceMetadata: sourceMetadata, authorization: scopedAuthorization)
                }
            }
        }
    }
    private func applyGranted(_ decision: AutomationAgentDecision, idempotencyKey: String, resourceID: String?,
               sourceMetadata: [String: String], authorization: AutomationEffectAuthorization) async throws -> String? {
        guard try await !bridge.workbenchState().isSimulation else { throw AutomationError.simulatedResult }
        if let scope = sourceMetadata["scopeID"], try await bridge.selectedMailScope()?.scopeID != scope {
            throw AutomationError.unauthorized
        }
        if decision.action != .notify {
            guard let resourceID, await bridge.automationResources()[decision.action] == resourceID else { throw AutomationError.unauthorized }
        }
        guard await authorization.validate(), try await bridge.workbenchState().status != "paused" else { throw AutomationError.unauthorized }
        let result: String?
        switch decision.action {
        case .notify:
            if decision.classification == "ads" { return "silent_advertisement" }
            guard Bundle.main.bundleIdentifier == "com.hushlight.bridge.mac" else { throw AutomationError.unavailableInput }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard [.authorized, .provisional].contains(settings.authorizationStatus), await authorization.validate(), try await bridge.workbenchState().status != "paused" else { throw AutomationError.unauthorized }
            let content = UNMutableNotificationContent(); content.title = decision.title; content.body = decision.body
            try await center.add(UNNotificationRequest(identifier: "workbench.automation." + idempotencyKey, content: content, trigger: nil))
            result = "notification." + idempotencyKey
        case .createDraft:
            guard let sender = sourceMetadata["sender"], let recipient = sourceMetadata["replyTo"],
                  BridgeAutomationInput.address(sender) == sender, BridgeAutomationInput.address(recipient) == recipient else { throw AutomationError.invalidDecision }
            let subject = sourceMetadata["subject"] ?? ""
            let input = MailDraftInput(sender: sender, to: [recipient], subject: subject.lowercased().hasPrefix("re:") ? subject : "Re: " + subject, text: decision.body)
            guard await authorization.validate() else { throw AutomationError.unauthorized }
            let draft = try await bridge.createMailDraft(id: "automation." + idempotencyKey, input: input)
            guard !draft.isSimulation else { throw AutomationError.simulatedResult }
            guard draft.status == "succeeded" else { throw AutomationError.unavailableInput }
            result = draft.draftID
        case .appendDailyNote:
            let day = sourceMetadata["day"] ?? BridgeAutomationInput.day(Date())
            let id = "automation.daily." + day
            let section = "\(decision.title)\n\(decision.body)\n来源：\(sourceMetadata["source"] ?? "")\n[联动:\(idempotencyKey)]"
            let before = try await bridge.readNote(id: id)
            guard !before.isSimulation else { throw AutomationError.simulatedResult }
            if before.status == "succeeded", let note = before.note {
                if note.text.contains("[联动:\(idempotencyKey)]") { return id }
                guard note.canAppend, await authorization.validate() else { throw AutomationError.unauthorized }
                let applied = try await bridge.appendNote(id: id, text: section, expectedRevision: note.revision)
                guard !applied.isSimulation else { throw AutomationError.simulatedResult }
                guard applied.status == "succeeded" else { throw AutomationError.unavailableInput }
            } else {
                guard before.stableError == "invalid_schema", await authorization.validate() else { throw AutomationError.unavailableInput }
                let applied = try await bridge.createNote(id: id, title: "联动摘要 " + day, text: section)
                guard !applied.isSimulation else { throw AutomationError.simulatedResult }
                guard applied.status == "succeeded" else { throw AutomationError.unavailableInput }
            }
            result = id
        case .createCalendar:
            guard let start = decision.eventAt, let end = decision.eventEndAt, end > start, let zone = decision.timeZoneID, TimeZone(identifier: zone) != nil else { throw AutomationError.invalidDecision }
            guard await authorization.validate() else { throw AutomationError.unauthorized }
            let record = try await bridge.createCalendarEvent(id: "automation_" + idempotencyKey, title: decision.title,
                start: start, end: end, sourceURL: Self.sourceURL(sourceMetadata["source"]))
            result = record.id
        case .createReminder:
            guard let date = decision.eventAt else { throw AutomationError.invalidDecision }
            guard await authorization.validate() else { throw AutomationError.unauthorized }
            let reminder = try await bridge.createReminder(id: "automation." + idempotencyKey,
                title: decision.title + " [来源:" + (sourceMetadata["source"] ?? "") + "]", dueAt: date)
            guard reminder.outcome == .succeeded else { throw AutomationError.unavailableInput }
            result = "automation." + idempotencyKey
        }
        return result
    }

    private static func sourceURL(_ source: String?) -> URL? {
        guard let source else { return nil }
        var url = URLComponents(); url.scheme = "workbench-source"; url.host = "mail"; url.path = "/" + source
        return url.url
    }
}
