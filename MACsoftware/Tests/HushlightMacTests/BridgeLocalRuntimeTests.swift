import Foundation
import XCTest
@testable import BridgeCore

final class BridgeLocalRuntimeTests: XCTestCase {
    func testSimulationCannotRegisterProductionTimerScheduler() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-isolation-\(UUID().uuidString)/Bridge/timers.json")
        let timer = try LocalTimerCoordinator(storageURL: url, scheduler: ProductionTimerSchedulerStub())
        do {
            _ = try await BridgeLocalRuntime(simulate: true, timerCoordinator: timer)
            XCTFail("Simulation must not register a production notification backend")
        } catch let error as BridgeLocalCLIConfigurationError {
            guard case .conflictingModes = error else { return XCTFail("Unexpected configuration error") }
        }
    }

    func testSnapshotPauseAndTypedReadUseSharedPolicy() async throws {
        let runtime = try await BridgeLocalRuntime(simulate: true, paused: true)
        let initial = await runtime.snapshot()
        XCTAssertTrue(initial.isPaused)
        XCTAssertEqual(initial.supportedActions, ["system.volume.adjust", "system.volume.get", "system.volume.set"])
        let blocked = await runtime.readSystemVolume()
        XCTAssertEqual(blocked.status, "rejected")
        XCTAssertEqual(blocked.stableError, "bridge_paused")
        XCTAssertNil(blocked.value)
        XCTAssertTrue(blocked.isSimulation)
        let blockedSnapshot = await runtime.snapshot()
        XCTAssertEqual(blockedSnapshot.recentActions.first?.stableError, "bridge_paused")

        await runtime.setPaused(false)
        let read = await runtime.readSystemVolume()
        XCTAssertEqual(read.status, "succeeded")
        XCTAssertEqual(read.value, 50)
        XCTAssertTrue(read.isSimulation)
        let activeSnapshot = await runtime.snapshot()
        XCTAssertFalse(activeSnapshot.isPaused)
        XCTAssertEqual(activeSnapshot.recentActions.first?.action, "system.volume.get")
    }

    func testRecentActionsBoundedAndSameRequestReplacesEntry() async throws {
        let runtime = try await BridgeLocalRuntime(simulate: true)
        for index in 1...51 {
            let response = await runtime.submit(try command(sequence: index))
            XCTAssertEqual(try resultStatus(response), "succeeded")
        }
        let first = await runtime.snapshot()
        XCTAssertEqual(first.recentActions.count, 50)
        XCTAssertEqual(first.recentActions.first?.requestID, requestID(51))
        XCTAssertFalse(first.recentActions.contains { $0.requestID == requestID(1) })

        let replayedRequest = await runtime.submit(try command(sequence: 52, requestSequence: 51))
        XCTAssertEqual(try resultStatus(replayedRequest), "succeeded")
        let second = await runtime.snapshot()
        XCTAssertEqual(second.recentActions.count, 50)
        XCTAssertEqual(second.recentActions.filter { $0.requestID == requestID(51) }.count, 1)
    }

    func testRejectsExternalSourceWithoutRecordingAction() async throws {
        let runtime = try await BridgeLocalRuntime(simulate: true)
        let rejected = await runtime.submit(try command(sequence: 1, source: "cloud"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: rejected) as? [String: Any])
        XCTAssertEqual(object["stable_error"] as? String, "unauthenticated")
        let snapshot = await runtime.snapshot()
        XCTAssertTrue(snapshot.recentActions.isEmpty)
    }

    private func requestID(_ sequence: Int) -> String {
        String(format: "018f0f4e-2f55-7f5c-8ca2-%012d", sequence)
    }

    private func command(sequence: Int, requestSequence: Int? = nil, source: String = "debug_console") throws -> Data {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let envelope: [String: Any] = [
            "protocol_version": "1.0", "message_type": "command.request",
            "message_id": requestID(sequence), "request_id": requestID(requestSequence ?? sequence),
            "source": ["kind": source, "id": "runtime-test"],
            "issued_at": formatter.string(from: now.addingTimeInterval(-1)),
            "expires_at": formatter.string(from: now.addingTimeInterval(60)),
            "nonce": "nonce-\(sequence)-with-sufficient-entropy",
            "payload": ["action": "system.volume.get", "risk_level": "L0", "parameters": [:]]
        ]
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    private func resultStatus(_ data: Data) throws -> String? {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (object["result"] as? [String: Any])?["status"] as? String
    }
}

private struct ProductionTimerSchedulerStub: TimerNotificationScheduling {
    func authorizationStatus() async -> TimerNotificationAuthorization { .authorized }
    func schedule(_ timer: LocalTimerRecord) async throws { throw StableErrorCode.internalError }
    func cancel(timerID: String) async throws { throw StableErrorCode.internalError }
}
