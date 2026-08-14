import XCTest
@testable import HushlightMac

final class BridgeProtocolTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_687_200)

    func testValidDeviceCommandDecodes() throws {
        let envelope = makeEnvelope()

        let validated = try BridgeProtocolValidator().decodeCommand(
            try encode(envelope),
            now: now
        )

        XCTAssertEqual(validated.command.requestID, envelope.requestID)
        XCTAssertEqual(validated.command.action, "system.volume.get")
        XCTAssertEqual(validated.command.riskLevel, .l0)
    }

    func testUnsupportedVersionIsRejected() throws {
        let envelope = makeEnvelope(protocolVersion: "2.0")

        XCTAssertThrowsError(
            try BridgeProtocolValidator().decodeCommand(try encode(envelope), now: now)
        ) { error in
            XCTAssertEqual(error as? StableErrorCode, .unsupportedProtocol)
        }
    }

    func testExpiredRequestIsRejected() throws {
        let envelope = makeEnvelope(
            issuedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(-1)
        )

        XCTAssertThrowsError(
            try BridgeProtocolValidator().decodeCommand(try encode(envelope), now: now)
        ) { error in
            XCTAssertEqual(error as? StableErrorCode, .requestExpired)
        }
    }

    func testDeviceRequestRequiresAuthenticationFields() throws {
        let envelope = makeEnvelope(auth: nil)

        XCTAssertThrowsError(
            try BridgeProtocolValidator().decodeCommand(try encode(envelope), now: now)
        ) { error in
            XCTAssertEqual(error as? StableErrorCode, .unauthenticated)
        }
    }

    func testInvalidUUIDv7VariantIsRejected() throws {
        let envelope = makeEnvelope(
            messageID: "018f0f4e-2f55-7f5c-1ca2-111111111111"
        )

        XCTAssertThrowsError(
            try BridgeProtocolValidator().decodeCommand(try encode(envelope), now: now)
        ) { error in
            XCTAssertEqual(error as? StableErrorCode, .invalidSchema)
        }
    }

    func testCommandParametersMustBeJSONObject() throws {
        let envelope = makeEnvelope(parameters: .string("not-an-object"))

        XCTAssertThrowsError(
            try BridgeProtocolValidator().decodeCommand(try encode(envelope), now: now)
        ) { error in
            XCTAssertEqual(error as? StableErrorCode, .invalidSchema)
        }
    }

    func testReplayGuardRejectsSameSourceAndNonce() async throws {
        let guardStore = ReplayGuard()
        let envelope = makeEnvelope()

        try await guardStore.checkAndRecord(envelope, now: now)

        do {
            try await guardStore.checkAndRecord(envelope, now: now)
            XCTFail("Expected replay rejection")
        } catch {
            XCTAssertEqual(error as? StableErrorCode, .replayDetected)
        }
    }

    func testBundledSchemaIsValidJSONAndContainsCanonicalAction() throws {
        let object = try JSONSerialization.jsonObject(with: BridgeProtocolSchema.data())
        let schema = try XCTUnwrap(object as? [String: Any])
        let definitions = try XCTUnwrap(schema["$defs"] as? [String: Any])
        let command = try XCTUnwrap(definitions["commandRequest"] as? [String: Any])
        let variants = try XCTUnwrap(command["oneOf"] as? [[String: Any]])
        let actions = try variants.map { variant in
            let properties = try XCTUnwrap(variant["properties"] as? [String: Any])
            let action = try XCTUnwrap(properties["action"] as? [String: Any])
            return try XCTUnwrap(action["const"] as? String)
        }

        XCTAssertEqual(actions.count, CapabilityRegistry.standard.definitions.count)
        XCTAssertTrue(actions.contains("system.volume.adjust"))
        XCTAssertTrue(actions.contains("chat.send"))

        for variant in variants {
            let properties = try XCTUnwrap(variant["properties"] as? [String: Any])
            let actionSchema = try XCTUnwrap(properties["action"] as? [String: Any])
            let action = try XCTUnwrap(actionSchema["const"] as? String)
            let riskSchema = try XCTUnwrap(properties["risk_level"] as? [String: Any])
            let risk = try XCTUnwrap(riskSchema["const"] as? String)
            let parameterSchema = try XCTUnwrap(properties["parameters"] as? [String: Any])
            let parameterReference = try XCTUnwrap(parameterSchema["$ref"] as? String)
            let definitionName = String(parameterReference.split(separator: "/").last ?? "")
            let capability = try XCTUnwrap(CapabilityRegistry.standard[action])

            XCTAssertEqual(risk, capability.riskLevel.rawValue)
            XCTAssertNotNil(definitions[definitionName])

            let confirmationSchema = try XCTUnwrap(properties["confirmation"] as? [String: Any])
            if capability.riskLevel == .l3 {
                XCTAssertEqual(confirmationSchema["$ref"] as? String, "#/$defs/confirmation")
            } else {
                XCTAssertEqual(confirmationSchema["type"] as? String, "null")
            }
        }
    }

    private func makeEnvelope(
        protocolVersion: String = "1.0",
        messageID: String = "018f0f4e-2f55-7f5c-8ca2-111111111111",
        issuedAt: Date? = nil,
        expiresAt: Date? = nil,
        parameters: JSONValue = .emptyObject,
        auth: BridgeAuthentication? = BridgeAuthentication(
            keyID: "test-key",
            mac: "test-mac-placeholder"
        )
    ) -> BridgeEnvelope {
        BridgeEnvelope(
            protocolVersion: protocolVersion,
            messageType: .commandRequest,
            messageID: messageID,
            requestID: "018f0f4e-2f55-7f5c-8ca2-222222222222",
            source: BridgeSource(kind: .device, id: "h0-reference-01"),
            issuedAt: issuedAt ?? now.addingTimeInterval(-1),
            expiresAt: expiresAt ?? now.addingTimeInterval(30),
            nonce: "nonce-with-enough-entropy",
            auth: auth,
            payload: .object([
                "action": .string("system.volume.get"),
                "risk_level": .string("L0"),
                "parameters": parameters,
                "confirmation": .null
            ])
        )
    }

    private func encode(_ envelope: BridgeEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }
}
