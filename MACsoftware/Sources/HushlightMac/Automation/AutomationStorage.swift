import Foundation
import CryptoKit
import Security
import Darwin

protocol AutomationKeyProviding: Sendable {
    func key() throws -> SymmetricKey
}

struct AutomationKeychainKeyProvider: AutomationKeyProviding {
    private let service = "com.hushlight.bridge.mac.automation"
    private let account = "pending-v1"

    func key() throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else { throw AutomationError.unavailableKey }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AutomationError.unavailableKey
        }
        let data = Data(bytes)
        let insert: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service, kSecAttrAccount as String: account,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                     kSecValueData as String: data]
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw AutomationError.unavailableKey }
        return SymmetricKey(data: data)
    }
}

struct AutomationPendingPayload: Codable, Sendable {
    let decision: AutomationAgentDecision
    let expiresAt: Date
    let sourceMetadata: [String: String]
}

struct AutomationRetryPayload: Codable, Sendable {
    let item: AutomationInputItem
    let expiresAt: Date
    var attempts: Int = 1

    private enum CodingKeys: String, CodingKey { case item, expiresAt, attempts }
    init(item: AutomationInputItem, expiresAt: Date, attempts: Int = 1) {
        self.item = item; self.expiresAt = expiresAt; self.attempts = attempts
    }
    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        item = try value.decode(AutomationInputItem.self, forKey: .item)
        expiresAt = try value.decode(Date.self, forKey: .expiresAt)
        attempts = try value.decodeIfPresent(Int.self, forKey: .attempts) ?? 1
    }
}

struct AutomationIntakePayload: Codable, Sendable {
    let ruleID: String
    let item: AutomationInputItem
    let acceptedAt: Date
    let expiresAt: Date
    let sequence: Int
}

struct AutomationDecisionQueue: Codable, Sendable {
    let ruleID: String
    let sourceID: String
    let decisions: [AutomationAgentDecision]
    let sourceMetadata: [String: String]
    let expiresAt: Date
}

struct AutomationDiskState: Codable {
    var version = 1
    var rules: [AutomationRule] = []
    var runs: [AutomationRun] = []
    var effects: [AutomationEffectRecord] = []
    /// Encrypted AES-GCM combined bytes; never plaintext mail or draft text on disk.
    var pending: [String: Data] = [:]
    var retryInputs: [String: Data] = [:]
    var intakeInputs: [String: Data] = [:]
    var intakeSequence = 0
    var decisionQueues: [String: Data] = [:]

    private enum CodingKeys: String, CodingKey {
        case version, rules, runs, effects, pending, retryInputs, intakeInputs, intakeSequence, decisionQueues
    }

    init() {}

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        version = try value.decode(Int.self, forKey: .version)
        rules = try value.decode([AutomationRule].self, forKey: .rules)
        runs = try value.decode([AutomationRun].self, forKey: .runs)
        effects = try value.decode([AutomationEffectRecord].self, forKey: .effects)
        pending = try value.decodeIfPresent([String: Data].self, forKey: .pending) ?? [:]
        retryInputs = try value.decodeIfPresent([String: Data].self, forKey: .retryInputs) ?? [:]
        intakeInputs = try value.decodeIfPresent([String: Data].self, forKey: .intakeInputs) ?? [:]
        intakeSequence = try value.decodeIfPresent(Int.self, forKey: .intakeSequence) ?? 0
        decisionQueues = try value.decodeIfPresent([String: Data].self, forKey: .decisionQueues) ?? [:]
    }
}

struct AutomationStorage {
    let url: URL
    let keyProvider: any AutomationKeyProviding

    func load() throws -> AutomationDiskState {
        guard FileManager.default.fileExists(atPath: url.path) else { return AutomationDiskState() }
        let state = try JSONDecoder().decode(AutomationDiskState.self, from: Data(contentsOf: url))
        guard state.version == 1 else { throw AutomationError.corruptState }
        return state
    }

    func save(_ state: AutomationDiskState) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        let data = try JSONEncoder().encode(state)
        // Background rules must reopen state after the first unlock, including while the screen is locked.
        // Mail/decision bodies remain AES-GCM encrypted with the matching AfterFirstUnlock key.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let fileFD = Darwin.open(url.path, O_RDONLY)
        guard fileFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fileFD) }
        guard fsync(fileFD) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let directoryFD = Darwin.open(parent.path, O_RDONLY)
        guard directoryFD >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func seal(_ payload: AutomationPendingPayload) throws -> Data {
        let bytes = try JSONEncoder().encode(payload)
        return try AES.GCM.seal(bytes, using: keyProvider.key()).combined!
    }

    func open(_ bytes: Data) throws -> AutomationPendingPayload {
        let box = try AES.GCM.SealedBox(combined: bytes)
        return try JSONDecoder().decode(AutomationPendingPayload.self,
                                        from: AES.GCM.open(box, using: keyProvider.key()))
    }

    func sealRetry(_ payload: AutomationRetryPayload) throws -> Data {
        try AES.GCM.seal(JSONEncoder().encode(payload), using: keyProvider.key()).combined!
    }

    func openRetry(_ bytes: Data) throws -> AutomationRetryPayload {
        try JSONDecoder().decode(AutomationRetryPayload.self,
                                 from: AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: keyProvider.key()))
    }

    func sealIntake(_ payload: AutomationIntakePayload) throws -> Data {
        try AES.GCM.seal(JSONEncoder().encode(payload), using: keyProvider.key()).combined!
    }

    func openIntake(_ bytes: Data) throws -> AutomationIntakePayload {
        try JSONDecoder().decode(AutomationIntakePayload.self,
                                 from: AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: keyProvider.key()))
    }

    func sealQueue(_ payload: AutomationDecisionQueue) throws -> Data {
        try AES.GCM.seal(JSONEncoder().encode(payload), using: keyProvider.key()).combined!
    }

    func openQueue(_ bytes: Data) throws -> AutomationDecisionQueue {
        try JSONDecoder().decode(AutomationDecisionQueue.self,
                                 from: AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: keyProvider.key()))
    }
}
