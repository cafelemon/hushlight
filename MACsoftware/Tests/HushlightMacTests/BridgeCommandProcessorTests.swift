import XCTest
@testable import HushlightMac

final class BridgeCommandProcessorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_687_200)

    func testProcessorAppliesReplayGuardBeforeRouter() async throws {
        let adapter = ProcessorCountingAdapter()
        let router = try CommandRouter(adapters: [adapter])
        let processor = BridgeCommandProcessor(router: router)
        let data = try commandData(
            messageID: "018f0f4e-2f55-7f5c-8ca2-111111111111",
            nonce: "first-nonce-with-entropy"
        )

        let first = await processor.process(data, now: now)
        let replay = await processor.process(data, now: now)
        let executionCount = await adapter.executionCount

        guard case let .commandResult(result) = first else {
            return XCTFail("Expected command result")
        }
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(
            replay,
            .protocolFailure(
                BridgeProtocolFailure(
                    stableError: .replayDetected,
                    requestID: "018f0f4e-2f55-7f5c-8ca2-222222222222"
                )
            )
        )
        XCTAssertEqual(executionCount, 1)
    }

    func testSameRequestWithFreshEnvelopeReturnsCachedResult() async throws {
        let adapter = ProcessorCountingAdapter()
        let router = try CommandRouter(adapters: [adapter])
        let processor = BridgeCommandProcessor(router: router)

        let first = await processor.process(
            try commandData(
                messageID: "018f0f4e-2f55-7f5c-8ca2-111111111111",
                nonce: "first-nonce-with-entropy"
            ),
            now: now
        )
        let retry = await processor.process(
            try commandData(
                messageID: "018f0f4e-2f55-7f5c-8ca2-333333333333",
                nonce: "second-nonce-with-entropy"
            ),
            now: now
        )
        let executionCount = await adapter.executionCount

        XCTAssertEqual(first, retry)
        XCTAssertEqual(executionCount, 1)
    }

    func testSignedL3CommandUsesTheSameProcessorChain() async throws {
        let keyID = "confirmation-key-01"
        let authority = HMACConfirmationAuthority(
            expectedBridgeID: "bridge-mac-test",
            keys: [keyID: Data(repeating: 0x42, count: 32)]
        )
        let digest = String(repeating: "a", count: 64)
        let credential = try authority.sign(
            ConfirmationClaims(
                confirmationID: "018f0f4e-2f55-7f5c-8ca2-999999999999",
                action: "chat.send",
                issuedAt: now.addingTimeInterval(-1),
                expiresAt: now.addingTimeInterval(30),
                userID: "user-01",
                deviceID: "device-01",
                bridgeID: "bridge-mac-test",
                sessionID: "session-01",
                provider: "wechat",
                targetID: "contact-01",
                draftSHA256: digest
            ),
            keyID: keyID
        )
        let adapter = ProcessorL3Adapter()
        let router = try CommandRouter(
            adapters: [adapter],
            policyEngine: PolicyEngine(confirmationVerifier: authority)
        )
        let processor = BridgeCommandProcessor(router: router)
        let payload = CommandPayload(
            action: "chat.send",
            riskLevel: .l3,
            parameters: .object([
                "provider": .string("wechat"),
                "user_id": .string("user-01"),
                "device_id": .string("device-01"),
                "session_id": .string("session-01"),
                "target_id": .string("contact-01"),
                "draft_sha256": .string(digest)
            ]),
            confirmation: credential
        )
        let envelope = BridgeEnvelope(
            protocolVersion: "1.0",
            messageType: .commandRequest,
            messageID: "018f0f4e-2f55-7f5c-8ca2-444444444444",
            requestID: "018f0f4e-2f55-7f5c-8ca2-555555555555",
            source: BridgeSource(kind: .cloud, id: "cloud-test"),
            issuedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(30),
            nonce: "signed-l3-nonce-with-entropy",
            auth: nil,
            payload: try jsonValue(payload)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let outcome = await processor.process(try encoder.encode(envelope), now: now)
        let executionCount = await adapter.executionCount

        guard case let .commandResult(result) = outcome else {
            return XCTFail("Expected signed L3 command result")
        }
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(executionCount, 1)
    }

    private func commandData(messageID: String, nonce: String) throws -> Data {
        let envelope = BridgeEnvelope(
            protocolVersion: "1.0",
            messageType: .commandRequest,
            messageID: messageID,
            requestID: "018f0f4e-2f55-7f5c-8ca2-222222222222",
            source: BridgeSource(kind: .debugConsole, id: "processor-test"),
            issuedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(30),
            nonce: nonce,
            auth: nil,
            payload: .object([
                "action": .string("system.volume.get"),
                "risk_level": .string("L0"),
                "parameters": .emptyObject,
                "confirmation": .null
            ])
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    private func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

private actor ProcessorCountingAdapter: CommandAdapter {
    nonisolated let supportedActions: Set<String> = ["system.volume.get"]
    private(set) var executionCount = 0

    func execute(_ command: BridgeCommand) async throws -> AdapterExecution {
        executionCount += 1
        return .succeeded()
    }
}

private actor ProcessorL3Adapter: CommandAdapter {
    nonisolated let supportedActions: Set<String> = ["chat.send"]
    private(set) var executionCount = 0

    func execute(_ command: BridgeCommand) async throws -> AdapterExecution {
        executionCount += 1
        return .succeeded()
    }
}
