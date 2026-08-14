import Foundation

struct CapabilityDefinition: Equatable, Sendable {
    let action: String
    let riskLevel: RiskLevel
}

struct CapabilityRegistry: Sendable {
    let definitions: [String: CapabilityDefinition]

    init(_ definitions: [CapabilityDefinition]) {
        self.definitions = Dictionary(
            definitions.map { ($0.action, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    subscript(action: String) -> CapabilityDefinition? {
        definitions[action]
    }

    static let standard = CapabilityRegistry([
        CapabilityDefinition(action: "system.volume.get", riskLevel: .l0),
        CapabilityDefinition(action: "system.volume.set", riskLevel: .l1),
        CapabilityDefinition(action: "system.volume.adjust", riskLevel: .l1),
        CapabilityDefinition(action: "timer.create", riskLevel: .l2),
        CapabilityDefinition(action: "timer.update", riskLevel: .l2),
        CapabilityDefinition(action: "timer.cancel", riskLevel: .l2),
        CapabilityDefinition(action: "reminder.create", riskLevel: .l2),
        CapabilityDefinition(action: "reminder.update", riskLevel: .l2),
        CapabilityDefinition(action: "reminder.cancel", riskLevel: .l2),
        CapabilityDefinition(action: "content.open", riskLevel: .l1),
        CapabilityDefinition(action: "media.play", riskLevel: .l1),
        CapabilityDefinition(action: "media.pause", riskLevel: .l1),
        CapabilityDefinition(action: "media.previous", riskLevel: .l1),
        CapabilityDefinition(action: "media.next", riskLevel: .l1),
        CapabilityDefinition(action: "music.search_and_play", riskLevel: .l2),
        CapabilityDefinition(action: "chat.draft", riskLevel: .l2),
        CapabilityDefinition(action: "chat.send", riskLevel: .l3)
    ])
}

struct AdapterExecution: Equatable, Sendable {
    let status: CommandStatus
    let stableError: StableErrorCode?
    let summary: JSONValue

    static func succeeded(summary: JSONValue = .emptyObject) -> AdapterExecution {
        AdapterExecution(status: .succeeded, stableError: nil, summary: summary)
    }
}

protocol CommandAdapter: Sendable {
    var supportedActions: Set<String> { get }
    func execute(_ command: BridgeCommand) async throws -> AdapterExecution
}

struct PolicyEngine: Sendable {
    private let confirmationVerifier: (any ConfirmationVerifying)?

    init(confirmationVerifier: (any ConfirmationVerifying)? = nil) {
        self.confirmationVerifier = confirmationVerifier
    }

    func rejection(
        for command: BridgeCommand,
        capability: CapabilityDefinition,
        isPaused: Bool,
        now: Date
    ) -> StableErrorCode? {
        if isPaused {
            return .bridgePaused
        }
        if command.expiresAt <= now {
            return .requestExpired
        }
        guard command.action == capability.action,
              command.riskLevel == capability.riskLevel else {
            return .invalidSchema
        }

        if capability.riskLevel == .l3 {
            guard let confirmation = command.confirmation else {
                return .confirmationRequired
            }
            guard confirmation.action == command.action,
                  confirmation.issuedAt < confirmation.expiresAt,
                  confirmation.expiresAt > now else {
                return .confirmationExpired
            }
            guard let confirmationVerifier else {
                return .confirmationInvalid
            }
            if let rejection = confirmationVerifier.rejection(
                for: confirmation,
                command: command,
                now: now
            ) {
                return rejection
            }
        } else if command.confirmation != nil {
            return .invalidSchema
        }

        return nil
    }
}

enum CommandRouterConfigurationError: Error, Equatable {
    case duplicateAction(String)
    case unregisteredAction(String)
}

actor CommandRouter {
    private struct UsedConfirmation: Sendable {
        let retainUntil: Date
    }

    private let registry: CapabilityRegistry
    private let policyEngine: PolicyEngine
    private let resultLimit: Int
    private let resultLifetime: TimeInterval
    private var adapters: [String: any CommandAdapter] = [:]
    private var completedResults: [String: CommandResult] = [:]
    private var inFlight: [String: Task<CommandResult, Never>] = [:]
    private var usedConfirmations: [String: UsedConfirmation] = [:]
    private var isPaused = false

    init(
        registry: CapabilityRegistry = .standard,
        adapters: [any CommandAdapter] = [],
        policyEngine: PolicyEngine = PolicyEngine(),
        resultLimit: Int = 500,
        resultLifetime: TimeInterval = 7 * 24 * 60 * 60
    ) throws {
        self.registry = registry
        self.policyEngine = policyEngine
        self.resultLimit = resultLimit
        self.resultLifetime = resultLifetime

        for adapter in adapters {
            for action in adapter.supportedActions {
                guard registry[action] != nil else {
                    throw CommandRouterConfigurationError.unregisteredAction(action)
                }
                guard self.adapters[action] == nil else {
                    throw CommandRouterConfigurationError.duplicateAction(action)
                }
                self.adapters[action] = adapter
            }
        }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    func handle(_ command: BridgeCommand, now: Date = Date()) async -> CommandResult {
        pruneCompletedResults(now: now)
        pruneUsedConfirmations(now: now)

        if let completed = completedResults[command.requestID] {
            return completed
        }
        if let existingTask = inFlight[command.requestID] {
            return await existingTask.value
        }

        if isPaused {
            return storeRejection(
                command: command,
                error: .bridgePaused,
                now: now
            )
        }

        guard let capability = registry[command.action],
              let adapter = adapters[command.action] else {
            return storeRejection(
                command: command,
                error: .capabilityDisabled,
                now: now
            )
        }
        if let rejection = policyEngine.rejection(
            for: command,
            capability: capability,
            isPaused: isPaused,
            now: now
        ) {
            return storeRejection(command: command, error: rejection, now: now)
        }
        if capability.riskLevel == .l3,
           let confirmation = command.confirmation {
            guard usedConfirmations[confirmation.confirmationID] == nil else {
                return storeRejection(
                    command: command,
                    error: .confirmationUsed,
                    now: now
                )
            }
            guard usedConfirmations.count < resultLimit else {
                return storeRejection(
                    command: command,
                    error: .internalError,
                    now: now
                )
            }
            usedConfirmations[confirmation.confirmationID] = UsedConfirmation(
                retainUntil: now.addingTimeInterval(resultLifetime)
            )
        }

        let task = Task<CommandResult, Never> {
            do {
                let execution = try await adapter.execute(command)
                guard Self.isConsistent(execution) else {
                    return CommandResult(
                        requestID: command.requestID,
                        action: command.action,
                        status: .failed,
                        stableError: .internalError,
                        summary: .emptyObject,
                        completedAt: Date()
                    )
                }
                return CommandResult(
                    requestID: command.requestID,
                    action: command.action,
                    status: execution.status,
                    stableError: execution.stableError,
                    summary: execution.summary,
                    completedAt: Date()
                )
            } catch let error as StableErrorCode {
                return CommandResult(
                    requestID: command.requestID,
                    action: command.action,
                    status: Self.status(for: error),
                    stableError: error,
                    summary: .emptyObject,
                    completedAt: Date()
                )
            } catch {
                return CommandResult(
                    requestID: command.requestID,
                    action: command.action,
                    status: .failed,
                    stableError: .internalError,
                    summary: .emptyObject,
                    completedAt: Date()
                )
            }
        }
        inFlight[command.requestID] = task

        let result = await task.value
        completedResults[command.requestID] = result
        inFlight[command.requestID] = nil
        enforceResultLimit()
        return result
    }

    func cachedResult(for requestID: String) -> CommandResult? {
        completedResults[requestID]
    }

    private func storeRejection(
        command: BridgeCommand,
        error: StableErrorCode,
        now: Date
    ) -> CommandResult {
        let result = CommandResult(
            requestID: command.requestID,
            action: command.action,
            status: .rejected,
            stableError: error,
            summary: .emptyObject,
            completedAt: now
        )
        completedResults[command.requestID] = result
        enforceResultLimit()
        return result
    }

    private func pruneCompletedResults(now: Date) {
        let cutoff = now.addingTimeInterval(-resultLifetime)
        completedResults = completedResults.filter { $0.value.completedAt > cutoff }
    }

    private func pruneUsedConfirmations(now: Date) {
        usedConfirmations = usedConfirmations.filter { $0.value.retainUntil > now }
    }

    private func enforceResultLimit() {
        guard completedResults.count > resultLimit else { return }
        let overflow = completedResults.count - resultLimit
        for result in completedResults.values.sorted(by: { $0.completedAt < $1.completedAt }).prefix(overflow) {
            completedResults[result.requestID] = nil
        }
    }

    private static func status(for error: StableErrorCode) -> CommandStatus {
        switch error {
        case .appNotInstalled, .internalError:
            return .failed
        case .executionTimeout, .resultUnverifiable:
            return .unknown
        default:
            return .rejected
        }
    }

    private static func isConsistent(_ execution: AdapterExecution) -> Bool {
        switch execution.status {
        case .succeeded:
            return execution.stableError == nil
        case .failed, .rejected, .unknown:
            return execution.stableError != nil
        }
    }
}
