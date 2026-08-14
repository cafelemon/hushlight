import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    static let emptyObject: JSONValue = .object([:])
}

enum BridgeMessageType: String, Codable, Sendable {
    case hello
    case heartbeat
    case capabilitySnapshot = "capability.snapshot"
    case commandRequest = "command.request"
    case commandAck = "command.ack"
    case commandResult = "command.result"
    case pairBegin = "pair.begin"
    case pairComplete = "pair.complete"
    case error
}

enum BridgeSourceKind: String, Codable, Sendable {
    case device
    case cloud
    case debugConsole = "debug_console"
}

struct BridgeSource: Codable, Equatable, Hashable, Sendable {
    let kind: BridgeSourceKind
    let id: String
}

struct BridgeAuthentication: Codable, Equatable, Sendable {
    let keyID: String
    let mac: String

    enum CodingKeys: String, CodingKey {
        case keyID = "key_id"
        case mac
    }
}

struct BridgeEnvelope: Codable, Equatable, Sendable {
    let protocolVersion: String
    let messageType: BridgeMessageType
    let messageID: String
    let requestID: String?
    let source: BridgeSource
    let issuedAt: Date
    let expiresAt: Date
    let nonce: String
    let auth: BridgeAuthentication?
    let payload: JSONValue

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case messageType = "message_type"
        case messageID = "message_id"
        case requestID = "request_id"
        case source
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
        case nonce
        case auth
        case payload
    }
}

enum RiskLevel: String, Codable, CaseIterable, Sendable {
    case l0 = "L0"
    case l1 = "L1"
    case l2 = "L2"
    case l3 = "L3"
}

struct ConfirmationCredential: Codable, Equatable, Sendable {
    let confirmationID: String
    let action: String
    let issuedAt: Date
    let expiresAt: Date
    let userID: String
    let deviceID: String
    let bridgeID: String
    let sessionID: String
    let provider: String
    let targetID: String
    let draftSHA256: String
    let keyID: String
    let signature: String

    enum CodingKeys: String, CodingKey {
        case confirmationID = "confirmation_id"
        case action
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
        case userID = "user_id"
        case deviceID = "device_id"
        case bridgeID = "bridge_id"
        case sessionID = "session_id"
        case provider
        case targetID = "target_id"
        case draftSHA256 = "draft_sha256"
        case keyID = "key_id"
        case signature
    }
}

struct CommandPayload: Codable, Equatable, Sendable {
    let action: String
    let riskLevel: RiskLevel
    let parameters: JSONValue
    let confirmation: ConfirmationCredential?

    enum CodingKeys: String, CodingKey {
        case action
        case riskLevel = "risk_level"
        case parameters
        case confirmation
    }
}

struct BridgeCommand: Equatable, Sendable {
    let requestID: String
    let source: BridgeSource
    let issuedAt: Date
    let expiresAt: Date
    let action: String
    let riskLevel: RiskLevel
    let parameters: JSONValue
    let confirmation: ConfirmationCredential?
}

enum CommandStatus: String, Codable, Sendable {
    case succeeded
    case failed
    case rejected
    case unknown
}

enum StableErrorCode: String, Codable, Error, Sendable {
    case unsupportedProtocol = "unsupported_protocol"
    case invalidSchema = "invalid_schema"
    case payloadTooLarge = "payload_too_large"
    case unauthenticated
    case requestExpired = "request_expired"
    case replayDetected = "replay_detected"
    case bridgePaused = "bridge_paused"
    case permissionRequired = "permission_required"
    case capabilityDisabled = "capability_disabled"
    case appNotInstalled = "app_not_installed"
    case appVersionUnsupported = "app_version_unsupported"
    case targetAmbiguous = "target_ambiguous"
    case confirmationRequired = "confirmation_required"
    case confirmationExpired = "confirmation_expired"
    case confirmationInvalid = "confirmation_invalid"
    case confirmationUsed = "confirmation_used"
    case executionTimeout = "execution_timeout"
    case resultUnverifiable = "result_unverifiable"
    case internalError = "internal_error"
}

struct CommandResult: Codable, Equatable, Sendable {
    let requestID: String
    let action: String
    let status: CommandStatus
    let stableError: StableErrorCode?
    let summary: JSONValue
    let completedAt: Date

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case action
        case status
        case stableError = "stable_error"
        case summary
        case completedAt = "completed_at"
    }
}
