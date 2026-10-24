import Foundation
import XCTest
@testable import BridgeCore

final class WeatherProtocolTests: XCTestCase {
    func testVersion13AddsOnlyWeatherAction() throws {
        let versions = try ["1.0", "1.1", "1.2", "1.3"].map { version -> Set<String> in
            let schema = try JSONSerialization.jsonObject(with: BridgeProtocolSchema.data(version: version)) as! [String: Any]
            let defs = schema["$defs"] as! [String: Any]
            let request = defs["commandRequest"] as! [String: Any]
            return Set((request["oneOf"] as! [[String: Any]]).compactMap { entry in
                let properties = entry["properties"] as? [String: Any]
                return (properties?["action"] as? [String: Any])?["const"] as? String
            })
        }
        XCTAssertEqual(versions.map(\.count), [17, 18, 22, 23])
        XCTAssertEqual(versions[3].subtracting(versions[2]), ["weather.get"])
        XCTAssertEqual(CapabilityRegistry.weatherExtended.definitions.count, 23)
    }

    func testVersionedParameters() throws {
        let validator = ActionParameterValidator()
        let weather: JSONValue = .object(["city_id": .string("beijing")])
        for version in ["1.0", "1.1", "1.2"] {
            XCTAssertThrowsError(try validator.validate(action: "weather.get", parameters: weather, protocolVersion: version)) {
                XCTAssertEqual($0 as? StableErrorCode, .capabilityDisabled)
            }
        }
        XCTAssertNoThrow(try validator.validate(action: "weather.get", parameters: weather, protocolVersion: "1.3"))
        XCTAssertThrowsError(try validator.validate(action: "weather.get", parameters: .object(["city_id": .string("Paris")]), protocolVersion: "1.3"))
        XCTAssertThrowsError(try validator.validate(action: "weather.get", parameters: .object(["city_id": .string("beijing"), "x": .number(1)]), protocolVersion: "1.3"))
        XCTAssertNoThrow(try validator.validate(action: "note.read", parameters: .object(["note_id": .string("n1")]), protocolVersion: "1.3"))
        XCTAssertNoThrow(try validator.validate(action: "reminder.complete", parameters: .object(["reminder_id": .string("r1"), "is_completed": .bool(true)]), protocolVersion: "1.3"))
    }
}
