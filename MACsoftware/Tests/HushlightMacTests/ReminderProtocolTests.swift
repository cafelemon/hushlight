import Foundation
import XCTest
@testable import BridgeCore

final class ReminderProtocolTests: XCTestCase {
    func testSchemaVersionsKeepV10AtSeventeenActions() throws {
        let old = try JSONSerialization.jsonObject(with: BridgeProtocolSchema.data()) as! [String: Any]
        let next = try JSONSerialization.jsonObject(with: BridgeProtocolSchema.data(version: "1.1")) as! [String: Any]
        let oldText = String(data: try JSONSerialization.data(withJSONObject: old), encoding: .utf8)!
        let nextText = String(data: try JSONSerialization.data(withJSONObject: next), encoding: .utf8)!
        XCTAssertFalse(oldText.contains("reminder.complete"))
        XCTAssertTrue(nextText.contains("reminder.complete"))
        XCTAssertEqual(CapabilityRegistry.standard.definitions.count, 17)
        XCTAssertEqual(CapabilityRegistry.extended.definitions.count, 18)
    }

    func testCompletionRequiresVersion11AndBoolean() throws {
        let validator = ActionParameterValidator()
        let valid: JSONValue = .object(["reminder_id": .string("r1"), "is_completed": .bool(true)])
        XCTAssertThrowsError(try validator.validate(action: "reminder.complete", parameters: valid))
        XCTAssertNoThrow(try validator.validate(action: "reminder.complete", parameters: valid, protocolVersion: "1.1"))
        let invalid: JSONValue = .object(["reminder_id": .string("r1"), "is_completed": .string("true")])
        XCTAssertThrowsError(try validator.validate(action: "reminder.complete", parameters: invalid, protocolVersion: "1.1"))
    }

    func testEnvelopeValidatorRejectsV10CompletionAndAcceptsV11() throws {
        let now = Date()
        func command(version: String) throws -> Data {
            let envelope = BridgeEnvelope(
                protocolVersion: version, messageType: .commandRequest,
                messageID: "018f0f4e-2f55-7f5c-8ca2-111111111111",
                requestID: "018f0f4e-2f55-7f5c-8ca2-222222222222",
                source: BridgeSource(kind: .debugConsole, id: "test"),
                issuedAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(30),
                nonce: "nonce-with-enough-entropy", auth: nil,
                payload: .object([
                    "action": .string("reminder.complete"), "risk_level": .string("L2"),
                    "parameters": .object(["reminder_id": .string("r1"), "is_completed": .bool(true)]),
                    "confirmation": .null
                ])
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(envelope)
        }
        XCTAssertThrowsError(try BridgeProtocolValidator().decodeCommand(command(version: "1.0"), now: now)) {
            XCTAssertEqual($0 as? StableErrorCode, .capabilityDisabled)
        }
        XCTAssertEqual(try BridgeProtocolValidator().decodeCommand(command(version: "1.1"), now: now).command.action,
                       "reminder.complete")
    }
}
