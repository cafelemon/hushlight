import Foundation
import XCTest
@testable import BridgeCore

final class BridgeLocalCLIEngineTests: XCTestCase {
    func testSimulationKeepsStateAndLabelsEveryResult() async throws {
        let engine = try await BridgeLocalCLIEngine(simulate: true)
        let set = await engine.processLine(try command(action: "system.volume.set", risk: "L1", parameters: ["value": 72], sequence: 1))
        let get = await engine.processLine(try command(action: "system.volume.get", risk: "L0", parameters: [:], sequence: 2))
        let setObject = try object(set)
        let getObject = try object(get)
        XCTAssertEqual(setObject["mode"] as? String, "simulation")
        XCTAssertEqual((setObject["result"] as? [String: Any])?["status"] as? String, "succeeded")
        XCTAssertEqual(((getObject["result"] as? [String: Any])?["summary"] as? [String: Any])?["value"] as? Double, 72)
    }

    func testRejectsNonLocalSourceAndOversizedLineWithoutEchoingInput() async throws {
        let engine = try await BridgeLocalCLIEngine(simulate: true)
        let payload = try command(action: "system.volume.get", risk: "L0", parameters: [:], sequence: 1, source: "cloud")
        let rejected = try object(await engine.processLine(payload))
        XCTAssertEqual(rejected["stable_error"] as? String, "unauthenticated")
        let oversized = try object(await engine.processLine(Data(repeating: 65, count: 65_537)))
        XCTAssertEqual(oversized["stable_error"] as? String, "payload_too_large")
        let repeatedResponse = await engine.processLine(payload)
        XCTAssertFalse(String(decoding: repeatedResponse, as: UTF8.self).contains("system.volume.get"))
    }

    func testReplayAndRequestCacheRemainInOneEngine() async throws {
        let engine = try await BridgeLocalCLIEngine(simulate: true)
        let first = try command(action: "system.volume.set", risk: "L1", parameters: ["value": 64], sequence: 1)
        let duplicate = await engine.processLine(first)
        let replay = await engine.processLine(first)
        XCTAssertEqual((try object(duplicate)["result"] as? [String: Any])?["status"] as? String, "succeeded")
        XCTAssertEqual(try object(replay)["stable_error"] as? String, "replay_detected")
        let freshEnvelope = try command(action: "system.volume.set", risk: "L1", parameters: ["value": 10], sequence: 2, requestSequence: 1)
        let cached = try object(await engine.processLine(freshEnvelope))
        XCTAssertEqual((((cached["result"] as? [String: Any])?["summary"] as? [String: Any])?["value"] as? Double), 64)
    }

    func testPausedAndUnavailableActionsReject() async throws {
        let paused = try await BridgeLocalCLIEngine(simulate: true, paused: true)
        let result = try object(await paused.processLine(command(action: "system.volume.get", risk: "L0", parameters: [:], sequence: 1)))
        XCTAssertEqual((result["result"] as? [String: Any])?["stable_error"] as? String, "bridge_paused")
        let active = try await BridgeLocalCLIEngine(simulate: true)
        let unsupported = try object(await active.processLine(command(action: "timer.cancel", risk: "L2", parameters: ["timer_id": "timer-1"], sequence: 2)))
        XCTAssertEqual((unsupported["result"] as? [String: Any])?["status"] as? String, "rejected")
    }

    func testDefaultRealModeDoesNotRegisterWrites() async throws {
        let engine = try await BridgeLocalCLIEngine()
        let response = try object(await engine.processLine(command(
            action: "system.volume.set", risk: "L1", parameters: ["value": 99], sequence: 1
        )))
        XCTAssertEqual(response["mode"] as? String, "system_read_only")
        XCTAssertEqual((response["result"] as? [String: Any])?["stable_error"] as? String, "capability_disabled")
    }

    func testLongLivedEnvelopeIsRejectedBeforeReplayCache() async throws {
        let engine = try await BridgeLocalCLIEngine(simulate: true)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: command(
            action: "system.volume.get", risk: "L0", parameters: [:], sequence: 1
        )) as? [String: Any])
        let formatter = ISO8601DateFormatter()
        envelope["expires_at"] = formatter.string(from: Date().addingTimeInterval(3_600))
        let response = try object(await engine.processLine(JSONSerialization.data(withJSONObject: envelope)))
        XCTAssertEqual(response["stable_error"] as? String, "invalid_schema")
    }

    private func command(action: String, risk: String, parameters: [String: Any], sequence: Int, source: String = "debug_console", requestSequence: Int? = nil) throws -> Data {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let id = String(format: "%012d", sequence)
        let requestID = String(format: "%012d", requestSequence ?? sequence)
        let envelope: [String: Any] = [
            "protocol_version": "1.0", "message_type": "command.request",
            "message_id": "018f0f4e-2f55-7f5c-8ca2-\(id)",
            "request_id": "018f0f4e-2f55-7f5c-8ca2-\(requestID)",
            "source": ["kind": source, "id": "local-test"],
            "issued_at": formatter.string(from: now.addingTimeInterval(-1)),
            "expires_at": formatter.string(from: now.addingTimeInterval(60)),
            "nonce": "nonce-\(id)-with-entropy",
            "payload": ["action": action, "risk_level": risk, "parameters": parameters]
        ]
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
