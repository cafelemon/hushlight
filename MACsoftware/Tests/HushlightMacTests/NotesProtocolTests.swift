import Foundation
import XCTest
@testable import BridgeCore

final class NotesProtocolTests: XCTestCase {
    func testVersion12ExtendsVersion11Only() throws {
        let versions = try ["1.0", "1.1", "1.2"].map { version -> Set<String> in
            let schema = try JSONSerialization.jsonObject(with: BridgeProtocolSchema.data(version: version)) as! [String: Any]
            let defs = schema["$defs"] as! [String: Any]
            let request = defs["commandRequest"] as! [String: Any]
            return Set((request["oneOf"] as! [[String: Any]]).compactMap { entry in
                let properties = entry["properties"] as? [String: Any]
                return (properties?["action"] as? [String: Any])?["const"] as? String
            })
        }
        XCTAssertEqual(versions[0].count, 17)
        XCTAssertEqual(versions[1].count, 18)
        XCTAssertEqual(versions[2].count, 22)
        XCTAssertTrue(versions[0].isSubset(of: versions[1]))
        XCTAssertTrue(versions[1].isSubset(of: versions[2]))
        XCTAssertEqual(CapabilityRegistry.notesExtended.definitions.count, 22)
    }

    func testNotesRequireVersion12AndTightParameters() throws {
        let validator = ActionParameterValidator()
        let list: JSONValue = .object(["query": .string("")])
        XCTAssertThrowsError(try validator.validate(action: "note.list", parameters: list, protocolVersion: "1.1")) {
            XCTAssertEqual($0 as? StableErrorCode, .capabilityDisabled)
        }
        XCTAssertNoThrow(try validator.validate(action: "note.list", parameters: list, protocolVersion: "1.2"))
        XCTAssertThrowsError(try validator.validate(action: "note.list", parameters: .object(["query": .number(1)]), protocolVersion: "1.2"))
        XCTAssertThrowsError(try validator.validate(action: "note.create", parameters: .object([
            "note_id": .string("n1"), "title": .string("two\nlines"), "text": .string("body")
        ]), protocolVersion: "1.2"))
        XCTAssertThrowsError(try validator.validate(action: "note.append", parameters: .object([
            "note_id": .string("n1"), "text": .string("body"), "expected_revision": .string("abc")
        ]), protocolVersion: "1.2"))
        XCTAssertNoThrow(try validator.validate(action: "reminder.complete", parameters: .object([
            "reminder_id": .string("r1"), "is_completed": .bool(true)
        ]), protocolVersion: "1.2"))
    }

    func testEnvelopeRejectsNotesOnOldVersionsAndAcceptsReminderCompletionOn12() throws {
        let now = Date()
        func encode(version: String, action: String, risk: String, parameters: JSONValue) throws -> Data {
            let envelope = BridgeEnvelope(
                protocolVersion: version, messageType: .commandRequest,
                messageID: "018f0f4e-2f55-7f5c-8ca2-111111111111",
                requestID: "018f0f4e-2f55-7f5c-8ca2-222222222222",
                source: BridgeSource(kind: .debugConsole, id: "test"),
                issuedAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(30),
                nonce: "nonce-with-enough-entropy", auth: nil,
                payload: .object(["action": .string(action), "risk_level": .string(risk),
                                  "parameters": parameters, "confirmation": .null])
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(envelope)
        }
        let actions: [(String, String, JSONValue)] = [
            ("note.list", "L0", .object(["query": .string("")])),
            ("note.read", "L0", .object(["note_id": .string("n1")])),
            ("note.create", "L2", .object(["note_id": .string("n1"), "title": .string("Title"), "text": .string("body")])),
            ("note.append", "L2", .object(["note_id": .string("n1"), "text": .string("more"),
                                            "expected_revision": .string(String(repeating: "a", count: 64))]))
        ]
        for (action, risk, parameters) in actions {
            for version in ["1.0", "1.1"] {
                XCTAssertThrowsError(try BridgeProtocolValidator().decodeCommand(
                    encode(version: version, action: action, risk: risk, parameters: parameters), now: now
                )) { XCTAssertEqual($0 as? StableErrorCode, .capabilityDisabled) }
            }
            XCTAssertEqual(try BridgeProtocolValidator().decodeCommand(
                encode(version: "1.2", action: action, risk: risk, parameters: parameters), now: now
            ).command.action, action)
        }
        XCTAssertEqual(try BridgeProtocolValidator().decodeCommand(encode(
            version: "1.2", action: "reminder.complete", risk: "L2",
            parameters: .object(["reminder_id": .string("r1"), "is_completed": .bool(true)])
        ), now: now).command.action, "reminder.complete")
    }
}
