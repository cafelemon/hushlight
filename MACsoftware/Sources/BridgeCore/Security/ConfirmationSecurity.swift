import CryptoKit
import Foundation

struct ConfirmationClaims: Codable, Equatable, Sendable {
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
    }
}

protocol ConfirmationVerifying: Sendable {
    func rejection(
        for credential: ConfirmationCredential,
        command: BridgeCommand,
        now: Date
    ) -> StableErrorCode?
}

struct HMACConfirmationAuthority: ConfirmationVerifying, Sendable {
    static let maximumLifetime: TimeInterval = 60

    let expectedBridgeID: String
    private let keys: [String: Data]

    init(expectedBridgeID: String, keys: [String: Data]) {
        self.expectedBridgeID = expectedBridgeID
        self.keys = keys
    }

    func sign(_ claims: ConfirmationClaims, keyID: String) throws -> ConfirmationCredential {
        guard let keyData = keys[keyID], keyData.count == 32 else {
            throw StableErrorCode.confirmationInvalid
        }
        let signature = try signature(for: claims, keyData: keyData)
        return ConfirmationCredential(
            confirmationID: claims.confirmationID,
            action: claims.action,
            issuedAt: claims.issuedAt,
            expiresAt: claims.expiresAt,
            userID: claims.userID,
            deviceID: claims.deviceID,
            bridgeID: claims.bridgeID,
            sessionID: claims.sessionID,
            provider: claims.provider,
            targetID: claims.targetID,
            draftSHA256: claims.draftSHA256,
            keyID: keyID,
            signature: signature
        )
    }

    func rejection(
        for credential: ConfirmationCredential,
        command: BridgeCommand,
        now: Date
    ) -> StableErrorCode? {
        guard credential.expiresAt > now,
              credential.issuedAt < credential.expiresAt else {
            return .confirmationExpired
        }
        guard credential.issuedAt <= now.addingTimeInterval(30),
              credential.expiresAt.timeIntervalSince(credential.issuedAt) <= Self.maximumLifetime,
              credential.action == "chat.send",
              credential.action == command.action,
              credential.bridgeID == expectedBridgeID,
              isUUIDv7(credential.confirmationID),
              !credential.userID.isEmpty,
              !credential.deviceID.isEmpty,
              !credential.sessionID.isEmpty,
              credential.provider == "wechat",
              !credential.targetID.isEmpty,
              isLowercaseSHA256(credential.draftSHA256),
              let parameters = chatSendParameters(command.parameters),
              credential.userID == parameters.userID,
              credential.deviceID == parameters.deviceID,
              credential.sessionID == parameters.sessionID,
              credential.provider == parameters.provider,
              credential.targetID == parameters.targetID,
              credential.draftSHA256 == parameters.draftSHA256 else {
            return .confirmationInvalid
        }
        if command.source.kind == .device,
           credential.deviceID != command.source.id {
            return .confirmationInvalid
        }
        guard let keyData = keys[credential.keyID], keyData.count == 32,
              let suppliedSignature = Data(base64URLEncoded: credential.signature),
              suppliedSignature.count == SHA256.byteCount else {
            return .confirmationInvalid
        }

        do {
            let claims = ConfirmationClaims(
                confirmationID: credential.confirmationID,
                action: credential.action,
                issuedAt: credential.issuedAt,
                expiresAt: credential.expiresAt,
                userID: credential.userID,
                deviceID: credential.deviceID,
                bridgeID: credential.bridgeID,
                sessionID: credential.sessionID,
                provider: credential.provider,
                targetID: credential.targetID,
                draftSHA256: credential.draftSHA256
            )
            let data = try canonicalData(for: claims)
            let key = SymmetricKey(data: keyData)
            guard HMAC<SHA256>.isValidAuthenticationCode(
                suppliedSignature,
                authenticating: data,
                using: key
            ) else {
                return .confirmationInvalid
            }
        } catch {
            return .confirmationInvalid
        }
        return nil
    }

    private func signature(for claims: ConfirmationClaims, keyData: Data) throws -> String {
        let data = try canonicalData(for: claims)
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: data,
            using: SymmetricKey(data: keyData)
        )
        return Data(authenticationCode).base64URLEncodedString()
    }

    private func canonicalData(for claims: ConfirmationClaims) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(claims)
    }

    private func chatSendParameters(_ value: JSONValue) -> ChatSendBindings? {
        guard case let .object(object) = value,
              case let .string(provider)? = object["provider"],
              case let .string(userID)? = object["user_id"],
              case let .string(deviceID)? = object["device_id"],
              case let .string(sessionID)? = object["session_id"],
              case let .string(targetID)? = object["target_id"],
              case let .string(draftSHA256)? = object["draft_sha256"] else {
            return nil
        }
        return ChatSendBindings(
            provider: provider,
            userID: userID,
            deviceID: deviceID,
            sessionID: sessionID,
            targetID: targetID,
            draftSHA256: draftSHA256
        )
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

    private func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64
            && value == value.lowercased()
            && value.allSatisfy(\.isHexDigit)
    }
}

private struct ChatSendBindings {
    let provider: String
    let userID: String
    let deviceID: String
    let sessionID: String
    let targetID: String
    let draftSHA256: String
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
