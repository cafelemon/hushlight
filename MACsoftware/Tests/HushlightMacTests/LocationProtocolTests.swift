import Foundation
import XCTest
@testable import BridgeCore

final class LocationProtocolTests: XCTestCase {
    func testVersion14AddsOnlyLocationAndPreservesOlderSchemas() throws {
        let versions = try ["1.0", "1.1", "1.2", "1.3", "1.4"].map { version -> Set<String> in
            let schema = try JSONSerialization.jsonObject(with: BridgeProtocolSchema.data(version: version)) as! [String: Any]
            let defs = schema["$defs"] as! [String: Any]
            let request = defs["commandRequest"] as! [String: Any]
            return Set((request["oneOf"] as! [[String: Any]]).compactMap { entry in
                let properties = entry["properties"] as? [String: Any]
                return (properties?["action"] as? [String: Any])?["const"] as? String
            })
        }
        XCTAssertEqual(versions.map(\.count), [17, 18, 22, 23, 24])
        XCTAssertEqual(versions[4].subtracting(versions[3]), ["location.get"])
        XCTAssertEqual(CapabilityRegistry.locationExtended.definitions.count, 24)
    }

    func testVersionedActionValidation() throws {
        let validator = ActionParameterValidator()
        for version in ["1.0", "1.1", "1.2", "1.3"] {
            XCTAssertThrowsError(try validator.validate(action: "location.get", parameters: .emptyObject,
                                                        protocolVersion: version)) {
                XCTAssertEqual($0 as? StableErrorCode, .capabilityDisabled)
            }
        }
        XCTAssertNoThrow(try validator.validate(action: "location.get", parameters: .emptyObject,
                                                protocolVersion: "1.4"))
        XCTAssertThrowsError(try validator.validate(action: "location.get",
                                                    parameters: .object(["latitude": .number(1)]),
                                                    protocolVersion: "1.4"))
        XCTAssertNoThrow(try validator.validate(action: "weather.get",
                                                parameters: .object(["city_id": .string("beijing")]),
                                                protocolVersion: "1.4"))
        XCTAssertNoThrow(try validator.validate(action: "note.read",
                                                parameters: .object(["note_id": .string("n1")]),
                                                protocolVersion: "1.4"))
        XCTAssertNoThrow(try validator.validate(action: "reminder.complete",
                                                parameters: .object(["reminder_id": .string("r1"),
                                                                     "is_completed": .bool(true)]),
                                                protocolVersion: "1.4"))
    }
}
