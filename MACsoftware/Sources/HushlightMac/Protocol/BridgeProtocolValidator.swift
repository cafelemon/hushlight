import Foundation

enum BridgeProtocolSchema {
    static func data() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "bridge-v1.schema",
            withExtension: "json"
        ) else {
            throw StableErrorCode.internalError
        }
        return try Data(contentsOf: url)
    }
}

struct ValidatedCommand: Equatable, Sendable {
    let envelope: BridgeEnvelope
    let command: BridgeCommand
}

struct BridgeProtocolValidator: Sendable {
    static let supportedVersion = "1.0"
    static let maximumMessageBytes = 64 * 1_024

    let allowedFutureClockSkew: TimeInterval
    let parameterValidator: ActionParameterValidator

    init(
        allowedFutureClockSkew: TimeInterval = 30,
        parameterValidator: ActionParameterValidator = ActionParameterValidator()
    ) {
        self.allowedFutureClockSkew = allowedFutureClockSkew
        self.parameterValidator = parameterValidator
    }

    func decodeCommand(_ data: Data, now: Date = Date()) throws -> ValidatedCommand {
        guard data.count <= Self.maximumMessageBytes else {
            throw StableErrorCode.payloadTooLarge
        }

        let envelope: BridgeEnvelope
        do {
            envelope = try Self.decoder.decode(BridgeEnvelope.self, from: data)
        } catch {
            throw StableErrorCode.invalidSchema
        }

        guard envelope.protocolVersion == Self.supportedVersion else {
            throw StableErrorCode.unsupportedProtocol
        }
        guard envelope.messageType == .commandRequest,
              isUUIDv7(envelope.messageID),
              let requestID = envelope.requestID,
              isUUIDv7(requestID),
              !envelope.source.id.isEmpty,
              envelope.source.id.count <= 128,
              (16...256).contains(envelope.nonce.count),
              envelope.expiresAt > envelope.issuedAt,
              envelope.issuedAt <= now.addingTimeInterval(allowedFutureClockSkew) else {
            throw StableErrorCode.invalidSchema
        }
        guard envelope.expiresAt > now else {
            throw StableErrorCode.requestExpired
        }
        if envelope.source.kind == .device {
            guard let auth = envelope.auth,
                  !auth.keyID.isEmpty,
                  !auth.mac.isEmpty else {
                throw StableErrorCode.unauthenticated
            }
        }

        let payload: CommandPayload
        do {
            let payloadData = try Self.encoder.encode(envelope.payload)
            payload = try Self.decoder.decode(CommandPayload.self, from: payloadData)
        } catch {
            throw StableErrorCode.invalidSchema
        }
        guard case .object = payload.parameters else {
            throw StableErrorCode.invalidSchema
        }
        try parameterValidator.validate(
            action: payload.action,
            parameters: payload.parameters
        )

        let command = BridgeCommand(
            requestID: requestID,
            source: envelope.source,
            issuedAt: envelope.issuedAt,
            expiresAt: envelope.expiresAt,
            action: payload.action,
            riskLevel: payload.riskLevel,
            parameters: payload.parameters,
            confirmation: payload.confirmation
        )
        return ValidatedCommand(envelope: envelope, command: command)
    }

    private func isUUIDv7(_ value: String) -> Bool {
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
        return components.count == 5
            && components[0].count == 8
            && components[1].count == 4
            && components[2].count == 4
            && components[2].first == "7"
            && components[3].count == 4
            && components[3].first.map { "89aAbB".contains($0) } == true
            && components[4].count == 12
            && UUID(uuidString: value) != nil
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

actor ReplayGuard {
    private struct ReplayKey: Hashable {
        let source: BridgeSource
        let nonce: String
    }

    private var seen: [ReplayKey: Date] = [:]

    func checkAndRecord(_ envelope: BridgeEnvelope, now: Date = Date()) throws {
        seen = seen.filter { $0.value > now }

        let key = ReplayKey(source: envelope.source, nonce: envelope.nonce)
        guard seen[key] == nil else {
            throw StableErrorCode.replayDetected
        }
        seen[key] = envelope.expiresAt
    }

    func reset() {
        seen.removeAll()
    }
}
