import Foundation

struct BridgeProtocolFailure: Equatable, Sendable {
    let stableError: StableErrorCode
    let requestID: String?
}

enum BridgeProcessingOutcome: Equatable, Sendable {
    case commandResult(CommandResult)
    case protocolFailure(BridgeProtocolFailure)
}

actor BridgeCommandProcessor {
    private let validator: BridgeProtocolValidator
    private let replayGuard: ReplayGuard
    private let router: CommandRouter

    init(
        validator: BridgeProtocolValidator = BridgeProtocolValidator(),
        replayGuard: ReplayGuard = ReplayGuard(),
        router: CommandRouter
    ) {
        self.validator = validator
        self.replayGuard = replayGuard
        self.router = router
    }

    func process(_ data: Data, now: Date = Date()) async -> BridgeProcessingOutcome {
        let validated: ValidatedCommand
        do {
            validated = try validator.decodeCommand(data, now: now)
        } catch let error as StableErrorCode {
            return .protocolFailure(
                BridgeProtocolFailure(stableError: error, requestID: nil)
            )
        } catch {
            return .protocolFailure(
                BridgeProtocolFailure(stableError: .internalError, requestID: nil)
            )
        }

        do {
            try await replayGuard.checkAndRecord(validated.envelope, now: now)
        } catch let error as StableErrorCode {
            return .protocolFailure(
                BridgeProtocolFailure(
                    stableError: error,
                    requestID: validated.command.requestID
                )
            )
        } catch {
            return .protocolFailure(
                BridgeProtocolFailure(
                    stableError: .internalError,
                    requestID: validated.command.requestID
                )
            )
        }

        return .commandResult(
            await router.handle(validated.command, now: now)
        )
    }
}
