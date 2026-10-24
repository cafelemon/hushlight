import Foundation

/// Set by trusted local entrypoints, never decoded from command parameters.
public enum BridgeExecutionContext {
    @TaskLocal public static var callerID: String = "local_ui"
    @TaskLocal public static var correlationID: String?
    @TaskLocal public static var backgroundAutomation = false
    @TaskLocal public static var mailScopeID: String?
}

public struct LocalRuntimeAction: Equatable, Sendable {
    public let requestID: String
    public let action: String
    public let status: String
    public let stableError: String?
    public let completedAt: Date
    public let callerID: String
    public let correlationID: String?
    public init(requestID: String, action: String, status: String, stableError: String?, completedAt: Date) {
        self.requestID = requestID; self.action = action; self.status = status
        self.stableError = stableError; self.completedAt = completedAt
        self.callerID = BridgeExecutionContext.callerID
        self.correlationID = BridgeExecutionContext.correlationID
    }
}

public struct LocalRuntimeSnapshot: Equatable, Sendable {
    public let isPaused: Bool
    public let supportedActions: [String]
    public let recentActions: [LocalRuntimeAction]
    public let isSimulation: Bool
    public init(isPaused: Bool, supportedActions: [String], recentActions: [LocalRuntimeAction], isSimulation: Bool = false) {
        self.isPaused = isPaused; self.supportedActions = supportedActions; self.recentActions = recentActions
        self.isSimulation = isSimulation
    }
}

public struct LocalVolumeResult: Equatable, Sendable {
    public let status: String
    public let stableError: String?
    public let value: Double?
    public let muted: Bool?
    public let completedAt: Date
    public let isSimulation: Bool
    public init(status: String, stableError: String?, value: Double?, muted: Bool?, completedAt: Date, isSimulation: Bool = false) {
        self.status = status; self.stableError = stableError; self.value = value
        self.muted = muted; self.completedAt = completedAt; self.isSimulation = isSimulation
    }
}

public struct LocalTimerCommandResult: Equatable, Sendable {
    public let status: String
    public let stableError: String?
    public let completedAt: Date
    public init(status: String, stableError: String?, completedAt: Date) {
        self.status = status; self.stableError = stableError; self.completedAt = completedAt
    }
}

public struct LocalReminderCommandResult: Equatable, Sendable {
    public let status: String
    public let stableError: String?
    public let completedAt: Date
    public init(status: String, stableError: String?, completedAt: Date) {
        self.status = status; self.stableError = stableError; self.completedAt = completedAt
    }
}

public struct LocalNotesCommandResult: Equatable, Sendable {
    public let status: String
    public let stableError: String?
    public let completedAt: Date
    public let notes: [LocalNoteSummary]
    public let note: LocalNoteContent?
    public let isSimulation: Bool
    public init(status: String, stableError: String?, completedAt: Date,
                notes: [LocalNoteSummary] = [], note: LocalNoteContent? = nil,
                isSimulation: Bool = false) {
        self.status = status; self.stableError = stableError; self.completedAt = completedAt
        self.notes = notes; self.note = note; self.isSimulation = isSimulation
    }
}

public struct LocalWeatherCommandResult: Equatable, Sendable {
    public let status: String
    public let stableError: String?
    public let completedAt: Date
    public let report: WeatherReport?
    public let isSimulation: Bool
    public init(status: String, stableError: String?, completedAt: Date,
                report: WeatherReport? = nil, isSimulation: Bool = false) {
        self.status = status; self.stableError = stableError; self.completedAt = completedAt
        self.report = report; self.isSimulation = isSimulation
    }
}

public struct LocalLocationCommandResult: Equatable, Sendable {
    public let status: String
    public let stableError: String?
    public let completedAt: Date
    public let location: LocalLocationRecord?
    public let isSimulation: Bool

    public init(status: String, stableError: String?, completedAt: Date,
                location: LocalLocationRecord? = nil, isSimulation: Bool = false) {
        self.status = status; self.stableError = stableError; self.completedAt = completedAt
        self.location = location; self.isSimulation = isSimulation
    }
}

public struct LocalMailCommandResult: Equatable, Sendable {
    public let status: String
    public let stableError: String?
    public let messages: [LocalMailSummary]
    public let mail: LocalMailContent?
    public let isSimulation: Bool
    public let draft: MailDraftContent?
    public let draftID: String?
    public let revision: String?
    public let sendState: String?
    public init(status: String, stableError: String? = nil, messages: [LocalMailSummary] = [],
                mail: LocalMailContent? = nil, isSimulation: Bool = false, draft: MailDraftContent? = nil,
                draftID: String? = nil, revision: String? = nil, sendState: String? = nil) {
        self.status = status; self.stableError = stableError; self.messages = messages
        self.mail = mail; self.isSimulation = isSimulation
        self.draft = draft; self.draftID = draftID; self.revision = revision; self.sendState = sendState
    }
}

/// Shared local bridge: policy, replay cache, pause state, and bounded action history.
public actor BridgeLocalRuntime {
    public static let maximumMessageBytes = BridgeProtocolValidator.maximumMessageBytes
    private let router: CommandRouter
    private let processor: BridgeCommandProcessor
    private let timerCoordinator: LocalTimerCoordinator?
    private let reminderCoordinator: LocalReminderCoordinator?
    private let notesCoordinator: LocalNotesCoordinator?
    private let weatherCoordinator: LocalWeatherCoordinator?
    private let locationCoordinator: LocalLocationCoordinator?
    private let mode: String
    private let actions: [String]
    private var isPaused: Bool
    private var pauseTransition: Task<Void, Never>?
    private var pauseVersion = 0
    private var recentActions: [LocalRuntimeAction] = []

    public init(simulate: Bool = false, allowVolumeControl: Bool = false, paused: Bool = false,
                timerCoordinator: LocalTimerCoordinator? = nil,
                reminderCoordinator: LocalReminderCoordinator? = nil,
                notesCoordinator: LocalNotesCoordinator? = nil,
                weatherCoordinator: LocalWeatherCoordinator? = nil,
                locationCoordinator: LocalLocationCoordinator? = nil,
                mailCoordinator: LocalMailCoordinator? = nil,
                mailDraftCoordinator: LocalMailDraftCoordinator? = nil) async throws {
        guard !(simulate && allowVolumeControl) else { throw BridgeLocalCLIConfigurationError.conflictingModes }
        guard !simulate || reminderCoordinator == nil || reminderCoordinator!.isSimulation else {
            throw BridgeLocalCLIConfigurationError.conflictingModes
        }
        guard !simulate || notesCoordinator == nil || notesCoordinator!.isSimulation else {
            throw BridgeLocalCLIConfigurationError.conflictingModes
        }
        guard !simulate || weatherCoordinator == nil || weatherCoordinator!.isSimulation else {
            throw BridgeLocalCLIConfigurationError.conflictingModes
        }
        guard !simulate || locationCoordinator == nil || locationCoordinator!.isSimulation else {
            throw BridgeLocalCLIConfigurationError.conflictingModes
        }
        guard !simulate || mailCoordinator == nil || mailCoordinator!.isSimulation else {
            throw BridgeLocalCLIConfigurationError.conflictingModes
        }
        guard !simulate || mailDraftCoordinator == nil || mailDraftCoordinator!.isSimulation else { throw BridgeLocalCLIConfigurationError.conflictingModes }
        let adapter: any CommandAdapter
        if simulate {
            #if DEBUG
            adapter = SimulatedVolumeAdapter()
            #else
            throw BridgeLocalCLIConfigurationError.simulationUnavailable
            #endif
        } else {
            adapter = SystemVolumeAdapter(readOnly: !allowVolumeControl)
        }
        var adapters: [any CommandAdapter] = [adapter]
        if let timerCoordinator {
            guard !simulate || timerCoordinator.isSimulation else {
                throw BridgeLocalCLIConfigurationError.conflictingModes
            }
            adapters.append(timerCoordinator)
        }
        if let reminderCoordinator { adapters.append(reminderCoordinator) }
        if let notesCoordinator { adapters.append(notesCoordinator) }
        if let weatherCoordinator { adapters.append(weatherCoordinator) }
        if let locationCoordinator { adapters.append(locationCoordinator) }
        if let mailCoordinator { adapters.append(mailCoordinator) }
        if let mailDraftCoordinator { adapters.append(mailDraftCoordinator) }
        let registry: CapabilityRegistry = mailDraftCoordinator != nil ? .mailDraftExtended : mailCoordinator != nil ? .mailExtended : locationCoordinator != nil ? .locationExtended :
            (weatherCoordinator != nil ? .weatherExtended :
            (notesCoordinator != nil ? .notesExtended : (reminderCoordinator != nil ? .extended : .standard))
            )
        let router = try CommandRouter(registry: registry,
                                       adapters: adapters)
        await router.setPaused(paused)
        self.router = router
        self.timerCoordinator = timerCoordinator
        self.reminderCoordinator = reminderCoordinator
        self.notesCoordinator = notesCoordinator
        self.weatherCoordinator = weatherCoordinator
        self.locationCoordinator = locationCoordinator
        processor = BridgeCommandProcessor(router: router)
        mode = simulate ? "simulation" : (allowVolumeControl ? "system_volume_control" : "system_read_only")
        actions = adapters.reduce(into: Set<String>()) { $0.formUnion($1.supportedActions) }.sorted()
        isPaused = paused
    }

    public func setPaused(_ paused: Bool) async {
        let previous = pauseTransition
        let router = router
        let transition = Task {
            if let previous { await previous.value }
            await router.setPaused(paused)
        }
        pauseTransition = transition
        pauseVersion += 1
        isPaused = paused
        await transition.value
    }

    public func snapshot() async -> LocalRuntimeSnapshot {
        await waitForLatestPause()
        return LocalRuntimeSnapshot(isPaused: isPaused, supportedActions: actions, recentActions: recentActions, isSimulation: mode == "simulation")
    }

    public func submit(_ data: Data) async -> Data {
        await waitForLatestPause()
        guard data.count <= Self.maximumMessageBytes else { return encodeError(.payloadTooLarge) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = object["source"] as? [String: Any],
              source["kind"] as? String == "debug_console" else { return encodeError(.unauthenticated) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let envelope = try? decoder.decode(BridgeEnvelope.self, from: data),
           envelope.expiresAt.timeIntervalSince(envelope.issuedAt) > 300 { return encodeError(.invalidSchema) }
        switch await processor.process(data) {
        case .commandResult(let result):
            record(result)
            return encode(BridgeLocalRuntimeResponse(mode: mode, messageType: "command.result", result: result, stableError: nil, requestID: nil))
        case .protocolFailure(let failure):
            return encode(BridgeLocalRuntimeResponse(mode: mode, messageType: "error", result: nil, stableError: failure.stableError, requestID: failure.requestID))
        }
    }

    public func readSystemVolume() async -> LocalVolumeResult {
        let now = Date()
        let request = BridgeEnvelope(
            protocolVersion: BridgeProtocolValidator.supportedVersion, messageType: .commandRequest,
            messageID: Self.uuidV7(), requestID: Self.uuidV7(),
            source: BridgeSource(kind: .debugConsole, id: "local-runtime"),
            issuedAt: now, expiresAt: now.addingTimeInterval(60),
            nonce: UUID().uuidString + UUID().uuidString, auth: nil,
            payload: .object(["action": .string("system.volume.get"), "risk_level": .string("L0"), "parameters": .emptyObject])
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let requestData = try? encoder.encode(request) else {
            return LocalVolumeResult(status: "failed", stableError: "internal_error", value: nil, muted: nil, completedAt: Date(), isSimulation: mode == "simulation")
        }
        let responseData = await submit(requestData)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let response = try? decoder.decode(BridgeLocalRuntimeResponse.self, from: responseData) else {
            return LocalVolumeResult(status: "failed", stableError: "internal_error", value: nil, muted: nil, completedAt: Date(), isSimulation: mode == "simulation")
        }
        guard let result = response.result else {
            return LocalVolumeResult(status: "rejected", stableError: response.stableError?.rawValue, value: nil, muted: nil, completedAt: Date(), isSimulation: mode == "simulation")
        }
        let summary: [String: JSONValue]
        if case .object(let object) = result.summary { summary = object } else { summary = [:] }
        let value: Double?
        if case .number(let number)? = summary["value"] { value = number } else { value = nil }
        let muted: Bool?
        if case .bool(let flag)? = summary["muted"] { muted = flag } else { muted = nil }
        return LocalVolumeResult(status: result.status.rawValue, stableError: result.stableError?.rawValue,
                                 value: value, muted: muted, completedAt: result.completedAt, isSimulation: mode == "simulation")
    }

    public func createTimer(id: String, fireAt: Date, label: String) async -> LocalTimerCommandResult {
        await submitTimer(action: "timer.create", parameters: [
            "timer_id": .string(id), "fire_at": .string(Self.timerDateString(fireAt)), "label": .string(label)
        ])
    }

    public func updateTimer(id: String, fireAt: Date? = nil, label: String? = nil) async -> LocalTimerCommandResult {
        var parameters: [String: JSONValue] = ["timer_id": .string(id)]
        if let fireAt { parameters["fire_at"] = .string(Self.timerDateString(fireAt)) }
        if let label { parameters["label"] = .string(label) }
        return await submitTimer(action: "timer.update", parameters: parameters)
    }

    public func cancelTimer(id: String) async -> LocalTimerCommandResult {
        await submitTimer(action: "timer.cancel", parameters: ["timer_id": .string(id)])
    }

    public func timerSnapshot() async throws -> [LocalTimerRecord] {
        guard let timerCoordinator else { throw StableErrorCode.capabilityDisabled }
        return try await timerCoordinator.timers()
    }

    public func restoreTimers() async throws {
        guard let timerCoordinator else { throw StableErrorCode.capabilityDisabled }
        try await timerCoordinator.restore()
    }

    public func reminderSnapshot() async throws -> [LocalReminderRecord] {
        guard let reminderCoordinator else { throw StableErrorCode.capabilityDisabled }
        return try await reminderCoordinator.reminders()
    }

    public func createReminder(id: String, title: String, dueAt: Date) async -> LocalReminderCommandResult {
        await submitReminder(action: "reminder.create", parameters: [
            "reminder_id": .string(id), "title": .string(title),
            "due_at": .string(Self.timerDateString(dueAt))
        ])
    }

    public func updateReminder(id: String, title: String? = nil, dueAt: Date? = nil) async -> LocalReminderCommandResult {
        var parameters: [String: JSONValue] = ["reminder_id": .string(id)]
        if let title { parameters["title"] = .string(title) }
        if let dueAt { parameters["due_at"] = .string(Self.timerDateString(dueAt)) }
        return await submitReminder(action: "reminder.update", parameters: parameters)
    }

    public func completeReminder(id: String, completed: Bool) async -> LocalReminderCommandResult {
        await submitReminder(action: "reminder.complete", parameters: [
            "reminder_id": .string(id), "is_completed": .bool(completed)
        ], version: BridgeProtocolValidator.extendedVersion)
    }

    public func cancelReminder(id: String) async -> LocalReminderCommandResult {
        await submitReminder(action: "reminder.cancel", parameters: ["reminder_id": .string(id)])
    }

    private func submitReminder(action: String, parameters: [String: JSONValue],
                                version: String = BridgeProtocolValidator.supportedVersion) async -> LocalReminderCommandResult {
        let issuedAt = Date()
        let request = BridgeEnvelope(
            protocolVersion: version, messageType: .commandRequest,
            messageID: Self.uuidV7(), requestID: Self.uuidV7(),
            source: BridgeSource(kind: .debugConsole, id: "local-runtime"),
            issuedAt: issuedAt, expiresAt: issuedAt.addingTimeInterval(60),
            nonce: UUID().uuidString + UUID().uuidString, auth: nil,
            payload: .object(["action": .string(action), "risk_level": .string("L2"),
                              "parameters": .object(parameters)])
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(request) else {
            return LocalReminderCommandResult(status: "failed", stableError: "internal_error", completedAt: Date())
        }
        let responseData = await submit(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let response = try? decoder.decode(BridgeLocalRuntimeResponse.self, from: responseData) else {
            return LocalReminderCommandResult(status: "failed", stableError: "internal_error", completedAt: Date())
        }
        if let result = response.result {
            return LocalReminderCommandResult(status: result.status.rawValue,
                                              stableError: result.stableError?.rawValue,
                                              completedAt: result.completedAt)
        }
        return LocalReminderCommandResult(status: "rejected", stableError: response.stableError?.rawValue,
                                          completedAt: Date())
    }

    public func listNotes(query: String = "") async -> LocalNotesCommandResult {
        await submitNotes(action: "note.list", risk: .l0, parameters: ["query": .string(query)])
    }

    public func readWeather(cityID: String) async -> LocalWeatherCommandResult {
        let issuedAt = Date()
        let request = BridgeEnvelope(
            protocolVersion: BridgeProtocolValidator.weatherVersion, messageType: .commandRequest,
            messageID: Self.uuidV7(), requestID: Self.uuidV7(),
            source: BridgeSource(kind: .debugConsole, id: "local-runtime"),
            issuedAt: issuedAt, expiresAt: issuedAt.addingTimeInterval(60),
            nonce: UUID().uuidString + UUID().uuidString, auth: nil,
            payload: .object(["action": .string("weather.get"), "risk_level": .string("L0"),
                              "parameters": .object(["city_id": .string(cityID)])])
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(request) else {
            return LocalWeatherCommandResult(status: "failed", stableError: StableErrorCode.internalError.rawValue,
                                             completedAt: Date(), isSimulation: mode == "simulation")
        }
        let responseData = await submit(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let response = try? decoder.decode(BridgeLocalRuntimeResponse.self, from: responseData) else {
            return LocalWeatherCommandResult(status: "failed", stableError: StableErrorCode.internalError.rawValue,
                                             completedAt: Date(), isSimulation: mode == "simulation")
        }
        guard let result = response.result else {
            return LocalWeatherCommandResult(status: "rejected", stableError: response.stableError?.rawValue,
                                             completedAt: Date(), isSimulation: mode == "simulation")
        }
        var report: WeatherReport?
        if case .object(let summary) = result.summary, let value = summary["report"],
           let reportData = try? JSONEncoder().encode(value) {
            report = try? decoder.decode(WeatherReport.self, from: reportData)
        }
        return LocalWeatherCommandResult(status: result.status.rawValue, stableError: result.stableError?.rawValue,
                                         completedAt: result.completedAt, report: report,
                                         isSimulation: mode == "simulation")
    }

    public func readLocation() async -> LocalLocationCommandResult {
        let issuedAt = Date()
        let request = BridgeEnvelope(
            protocolVersion: BridgeProtocolValidator.locationVersion, messageType: .commandRequest,
            messageID: Self.uuidV7(), requestID: Self.uuidV7(),
            source: BridgeSource(kind: .debugConsole, id: "local-runtime"),
            issuedAt: issuedAt, expiresAt: issuedAt.addingTimeInterval(60),
            nonce: UUID().uuidString + UUID().uuidString, auth: nil,
            payload: .object(["action": .string("location.get"), "risk_level": .string("L0"),
                              "parameters": .emptyObject])
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let simulation = mode == "simulation"
        guard let data = try? encoder.encode(request) else {
            return LocalLocationCommandResult(status: "failed", stableError: StableErrorCode.internalError.rawValue,
                                              completedAt: Date(), isSimulation: simulation)
        }
        let responseData = await submit(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let response = try? decoder.decode(BridgeLocalRuntimeResponse.self, from: responseData) else {
            return LocalLocationCommandResult(status: "failed", stableError: StableErrorCode.internalError.rawValue,
                                              completedAt: Date(), isSimulation: simulation)
        }
        guard let result = response.result else {
            return LocalLocationCommandResult(status: "rejected", stableError: response.stableError?.rawValue,
                                              completedAt: Date(), isSimulation: simulation)
        }
        var location: LocalLocationRecord?
        if case .object(let summary) = result.summary,
           let value = summary["location"], let locationData = try? encoder.encode(value) {
            location = try? decoder.decode(LocalLocationRecord.self, from: locationData)
        }
        return LocalLocationCommandResult(status: result.status.rawValue, stableError: result.stableError?.rawValue,
                                          completedAt: result.completedAt, location: location,
                                          isSimulation: simulation)
    }

    public func readNote(id: String) async -> LocalNotesCommandResult {
        await submitNotes(action: "note.read", risk: .l0, parameters: ["note_id": .string(id)])
    }

    public func searchMail(query: String, unreadOnly: Bool) async -> LocalMailCommandResult {
        await submitMail(action: "mail.search", parameters: ["query": .string(query), "unread_only": .bool(unreadOnly)])
    }

    public func readMail(id: String) async -> LocalMailCommandResult {
        await submitMail(action: "mail.read", parameters: ["message_id": .string(id)])
    }

    public func createMailDraft(id: String, input: MailDraftInput) async -> LocalMailCommandResult {
        await submitMail(action: "mail.draft.create", parameters: ["draft_id": .string(id), "sender": .string(input.sender),
            "to": .array(input.to.map(JSONValue.string)), "cc": .array(input.cc.map(JSONValue.string)), "bcc": .array(input.bcc.map(JSONValue.string)),
            "subject": .string(input.subject), "text": .string(input.text)])
    }
    public func readMailDraft(id: String) async -> LocalMailCommandResult {
        await submitMail(action: "mail.draft.read", parameters: ["draft_id": .string(id)])
    }
    public func requestMailSend(id: String, revision: String) async -> LocalMailCommandResult {
        await submitMail(action: "mail.send.request", parameters: ["draft_id": .string(id), "expected_revision": .string(revision)])
    }

    public func mailDraftStatus(id: String) async -> LocalMailCommandResult {
        await submitMail(action: "mail.draft.status", parameters: ["draft_id": .string(id)])
    }

    private func submitMail(action: String, parameters: [String: JSONValue]) async -> LocalMailCommandResult {
        let now = Date()
        let isDraftAction = action.hasPrefix("mail.draft.") || action == "mail.send.request"
        let risk = ["mail.draft.create", "mail.send.request"].contains(action) ? "L2" : "L0"
        let request = BridgeEnvelope(protocolVersion: isDraftAction ? BridgeProtocolValidator.mailDraftVersion : BridgeProtocolValidator.mailVersion, messageType: .commandRequest,
                                     messageID: Self.uuidV7(), requestID: Self.uuidV7(),
                                     source: .init(kind: .debugConsole, id: "local-runtime"), issuedAt: now,
                                     expiresAt: now.addingTimeInterval(60), nonce: UUID().uuidString + UUID().uuidString,
                                     auth: nil, payload: .object(["action": .string(action), "risk_level": .string(risk),
                                                                  "parameters": .object(parameters)]))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let simulation = mode == "simulation"
        guard let data = try? encoder.encode(request) else {
            return .init(status: "failed", stableError: "internal_error", isSimulation: simulation)
        }
        let responseData = await submit(data)
        guard let response = try? decoder.decode(BridgeLocalRuntimeResponse.self, from: responseData) else {
            return .init(status: "failed", stableError: "internal_error", isSimulation: simulation)
        }
        guard let result = response.result else {
            return .init(status: "rejected", stableError: response.stableError?.rawValue, isSimulation: simulation)
        }
        guard result.status == .succeeded else {
            return .init(status: result.status.rawValue, stableError: result.stableError?.rawValue, isSimulation: simulation)
        }
        guard case .object(let fields) = result.summary else {
            return .init(status: "failed", stableError: "result_unverifiable", isSimulation: simulation)
        }
        do {
            if let value = fields["draft"] {
                return .init(status: "succeeded", isSimulation: simulation, draft: try decoder.decode(MailDraftContent.self, from: encoder.encode(value)))
            }
            if case .string(let draftID)? = fields["draft_id"] {
                let revision: String? = { if case .string(let s)? = fields["revision"] { return s }; return nil }()
                let state: String? = { if case .string(let s)? = fields["send_state"] { return s }; return nil }()
                return .init(status: "succeeded", isSimulation: simulation, draftID: draftID, revision: revision, sendState: state)
            }
            if action == "mail.search", let value = fields["messages"] {
                return .init(status: "succeeded", messages: try decoder.decode([LocalMailSummary].self, from: encoder.encode(value)), isSimulation: simulation)
            }
            if let value = fields["mail"] {
                return .init(status: "succeeded", mail: try decoder.decode(LocalMailContent.self, from: encoder.encode(value)), isSimulation: simulation)
            }
        } catch {}
        return .init(status: "failed", stableError: "result_unverifiable", isSimulation: simulation)
    }

    public func createNote(id: String, title: String, text: String) async -> LocalNotesCommandResult {
        await submitNotes(action: "note.create", risk: .l2, parameters: [
            "note_id": .string(id), "title": .string(title), "text": .string(text)
        ])
    }

    public func appendNote(id: String, text: String, expectedRevision: String) async -> LocalNotesCommandResult {
        await submitNotes(action: "note.append", risk: .l2, parameters: [
            "note_id": .string(id), "text": .string(text), "expected_revision": .string(expectedRevision)
        ])
    }

    private func submitNotes(action: String, risk: RiskLevel,
                             parameters: [String: JSONValue]) async -> LocalNotesCommandResult {
        let issuedAt = Date()
        let request = BridgeEnvelope(
            protocolVersion: BridgeProtocolValidator.notesVersion, messageType: .commandRequest,
            messageID: Self.uuidV7(), requestID: Self.uuidV7(),
            source: BridgeSource(kind: .debugConsole, id: "local-runtime"),
            issuedAt: issuedAt, expiresAt: issuedAt.addingTimeInterval(60),
            nonce: UUID().uuidString + UUID().uuidString, auth: nil,
            payload: .object(["action": .string(action), "risk_level": .string(risk.rawValue),
                              "parameters": .object(parameters)])
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(request) else {
            return LocalNotesCommandResult(status: "failed", stableError: "internal_error", completedAt: Date(), isSimulation: mode == "simulation")
        }
        let responseData = await submit(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let response = try? decoder.decode(BridgeLocalRuntimeResponse.self, from: responseData) else {
            return LocalNotesCommandResult(status: "failed", stableError: "internal_error", completedAt: Date(), isSimulation: mode == "simulation")
        }
        guard let result = response.result else {
            return LocalNotesCommandResult(status: "rejected", stableError: response.stableError?.rawValue,
                                           completedAt: Date(), isSimulation: mode == "simulation")
        }
        var notes: [LocalNoteSummary] = []
        var note: LocalNoteContent?
        if case .object(let summary) = result.summary {
            if case .array(let items)? = summary["notes"] {
                notes = items.compactMap { item in
                    guard case .object(let object) = item,
                          case .string(let id)? = object["id"],
                          case .string(let title)? = object["title"] else { return nil }
                    return LocalNoteSummary(id: id, title: title)
                }
            }
            if case .object(let object)? = summary["note"],
               case .string(let id)? = object["id"],
               case .string(let title)? = object["title"],
               case .string(let text)? = object["text"],
               case .string(let revision)? = object["revision"],
               case .bool(let canAppend)? = object["can_append"] {
                note = LocalNoteContent(id: id, title: title, text: text,
                                        revision: revision, canAppend: canAppend)
            }
        }
        return LocalNotesCommandResult(status: result.status.rawValue,
                                       stableError: result.stableError?.rawValue,
                                       completedAt: result.completedAt, notes: notes,
                                       note: note, isSimulation: mode == "simulation")
    }

    private func submitTimer(action: String, parameters: [String: JSONValue]) async -> LocalTimerCommandResult {
        let issuedAt = Date()
        let request = BridgeEnvelope(
            protocolVersion: BridgeProtocolValidator.supportedVersion, messageType: .commandRequest,
            messageID: Self.uuidV7(), requestID: Self.uuidV7(),
            source: BridgeSource(kind: .debugConsole, id: "local-runtime"),
            issuedAt: issuedAt, expiresAt: issuedAt.addingTimeInterval(60),
            nonce: UUID().uuidString + UUID().uuidString, auth: nil,
            payload: .object(["action": .string(action), "risk_level": .string("L2"),
                              "parameters": .object(parameters)])
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(request) else {
            return LocalTimerCommandResult(status: "failed", stableError: "internal_error", completedAt: Date())
        }
        let responseData = await submit(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let response = try? decoder.decode(BridgeLocalRuntimeResponse.self, from: responseData) else {
            return LocalTimerCommandResult(status: "failed", stableError: "internal_error", completedAt: Date())
        }
        if let result = response.result {
            return LocalTimerCommandResult(status: result.status.rawValue,
                                           stableError: result.stableError?.rawValue,
                                           completedAt: result.completedAt)
        }
        return LocalTimerCommandResult(status: "rejected", stableError: response.stableError?.rawValue,
                                       completedAt: Date())
    }

    private static func timerDateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public func oversizedLineResponse() -> Data { encodeError(.payloadTooLarge) }

    private func waitForLatestPause() async {
        while let transition = pauseTransition {
            let version = pauseVersion
            await transition.value
            if version == pauseVersion { return }
        }
    }

    private func record(_ result: CommandResult) {
        recentActions.removeAll { $0.requestID == result.requestID }
        recentActions.insert(LocalRuntimeAction(requestID: result.requestID, action: result.action,
                                                status: result.status.rawValue, stableError: result.stableError?.rawValue,
                                                completedAt: result.completedAt), at: 0)
        if recentActions.count > 50 { recentActions.removeLast(recentActions.count - 50) }
    }

    private func encodeError(_ error: StableErrorCode) -> Data {
        encode(BridgeLocalRuntimeResponse(mode: mode, messageType: "error", result: nil, stableError: error, requestID: nil))
    }

    private func encode(_ response: BridgeLocalRuntimeResponse) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(response)) ?? Data("{\"message_type\":\"error\",\"stable_error\":\"internal_error\"}".utf8)
    }

    private static func uuidV7() -> String {
        let timestamp = String(format: "%012llx", UInt64(Date().timeIntervalSince1970 * 1_000))
        let random = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "\(timestamp.prefix(8))-\(timestamp.suffix(4))-7\(random.prefix(3))-8\(random.dropFirst(3).prefix(3))-\(random.dropFirst(6).prefix(12))"
    }
}

private struct BridgeLocalRuntimeResponse: Codable {
    let mode: String
    let messageType: String
    let result: CommandResult?
    let stableError: StableErrorCode?
    let requestID: String?
    enum CodingKeys: String, CodingKey {
        case mode
        case messageType = "message_type"
        case result
        case stableError = "stable_error"
        case requestID = "request_id"
    }
}
