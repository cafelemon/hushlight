import Foundation
import XCTest
@testable import BridgeCore

private actor FakeLocationBackend: LocationBackend {
    nonisolated let isSimulation: Bool
    var authorization: LocationAuthorization = .authorized
    var sample = LocationSample(latitude: 31.23456, longitude: 121.4737,
                                horizontalAccuracyMeters: 10, timestamp: Date())
    var locationCalls = 0
    var authorizationRequests = 0

    init(simulation: Bool = true) { isSimulation = simulation }
    func authorizationStatus() async -> LocationAuthorization { authorization }
    func requestAuthorization() async throws -> LocationAuthorization {
        authorizationRequests += 1
        return authorization
    }
    func requestLocation() async throws -> LocationSample {
        locationCalls += 1
        return sample
    }
    func setAuthorization(_ value: LocationAuthorization) { authorization = value }
    func setSample(_ value: LocationSample) { sample = value }
    func counts() -> (Int, Int) { (locationCalls, authorizationRequests) }
}

final class LocalLocationTests: XCTestCase {
    func testAuthorizedReadIsApproximateAndMetadataHasNoCoordinates() async throws {
        let backend = FakeLocationBackend()
        let runtime = try await BridgeLocalRuntime(simulate: true,
            locationCoordinator: LocalLocationCoordinator(backend: backend))
        let result = await runtime.readLocation()
        XCTAssertEqual(result.status, "succeeded")
        XCTAssertEqual(result.location?.latitude, 31.23)
        XCTAssertEqual(result.location?.longitude, 121.47)
        XCTAssertEqual(result.location?.horizontalAccuracyMeters, 1_500)
        XCTAssertEqual(result.location?.source, "Core Location")
        XCTAssertEqual(result.location?.isApproximate, true)
        XCTAssertTrue(result.isSimulation)
        let counts = await backend.counts()
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 0)
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.recentActions.map(\.action), ["location.get"])
        XCTAssertFalse(String(describing: snapshot).contains("31.23"))
        XCTAssertFalse(String(describing: snapshot).contains("121.47"))
    }

    func testDeniedAndPausedNeverRequestLocationOrAuthorization() async throws {
        let backend = FakeLocationBackend()
        await backend.setAuthorization(.denied)
        let runtime = try await BridgeLocalRuntime(simulate: true,
            locationCoordinator: LocalLocationCoordinator(backend: backend))
        let denied = await runtime.readLocation()
        XCTAssertEqual(denied.stableError, "permission_required")
        XCTAssertNil(denied.location)
        await backend.setAuthorization(.authorized)
        await runtime.setPaused(true)
        let paused = await runtime.readLocation()
        XCTAssertEqual(paused.stableError, "bridge_paused")
        let counts = await backend.counts()
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
    }

    func testInvalidSamplesRejectedAndAccuracyFloor() async throws {
        let backend = FakeLocationBackend()
        let runtime = try await BridgeLocalRuntime(simulate: true,
            locationCoordinator: LocalLocationCoordinator(backend: backend))
        let invalid = [
            LocationSample(latitude: 91, longitude: 10, horizontalAccuracyMeters: 10, timestamp: Date()),
            LocationSample(latitude: 10, longitude: -181, horizontalAccuracyMeters: 10, timestamp: Date()),
            LocationSample(latitude: .nan, longitude: 10, horizontalAccuracyMeters: 10, timestamp: Date()),
            LocationSample(latitude: 10, longitude: 10, horizontalAccuracyMeters: -1, timestamp: Date()),
            LocationSample(latitude: 10, longitude: 10, horizontalAccuracyMeters: 0, timestamp: Date()),
            LocationSample(latitude: 10, longitude: 10, horizontalAccuracyMeters: 100_001, timestamp: Date()),
            LocationSample(latitude: 10, longitude: 10, horizontalAccuracyMeters: 10, timestamp: Date().addingTimeInterval(-61)),
            LocationSample(latitude: 10, longitude: 10, horizontalAccuracyMeters: 10, timestamp: Date().addingTimeInterval(6))
        ]
        for sample in invalid {
            await backend.setSample(sample)
            let result = await runtime.readLocation()
            XCTAssertEqual(result.stableError, "result_unverifiable")
            XCTAssertNil(result.location)
        }
        await backend.setSample(.init(latitude: -12.345, longitude: 24.876,
                                     horizontalAccuracyMeters: 2_000, timestamp: Date()))
        let valid = await runtime.readLocation()
        XCTAssertEqual(valid.location?.horizontalAccuracyMeters, 2_000)
        XCTAssertEqual(valid.location?.latitude, -12.35)
        XCTAssertEqual(valid.location?.longitude, 24.88)
    }

    func testSimulationGuardAndSingleUseRouterTombstone() async throws {
        let production = FakeLocationBackend(simulation: false)
        do {
            _ = try await BridgeLocalRuntime(simulate: true,
                locationCoordinator: LocalLocationCoordinator(backend: production))
            XCTFail("Production location backend entered simulation")
        } catch {
            XCTAssertEqual(error as? BridgeLocalCLIConfigurationError, .conflictingModes)
        }
        let productionCounts = await production.counts()
        XCTAssertEqual(productionCounts.0, 0)

        let backend = FakeLocationBackend()
        let router = try CommandRouter(registry: .locationExtended,
                                       adapters: [LocalLocationCoordinator(backend: backend)])
        let now = Date()
        let command = BridgeCommand(requestID: "same-id", source: .init(kind: .debugConsole, id: "test"),
                                    issuedAt: now, expiresAt: now.addingTimeInterval(60),
                                    action: "location.get", riskLevel: .l0, parameters: .emptyObject,
                                    confirmation: nil)
        let first = await router.handle(command)
        XCTAssertEqual(first.status, .succeeded)
        let cached = await router.cachedResult(for: command.requestID)
        XCTAssertNil(cached)
        let second = await router.handle(command)
        XCTAssertEqual(second.stableError, .replayDetected)
        let counts = await backend.counts()
        XCTAssertEqual(counts.0, 1)
        let cachedAfterReplay = await router.cachedResult(for: command.requestID)
        XCTAssertNil(cachedAfterReplay)
    }

    func testCompletedRequestWithNewNonceDoesNotSampleAgain() async throws {
        let backend = FakeLocationBackend()
        let runtime = try await BridgeLocalRuntime(simulate: true,
            locationCoordinator: LocalLocationCoordinator(backend: backend))
        let requestID = "018f0f4e-2f55-7f5c-8ca2-000000000001"
        func request(message: Int) throws -> Data {
            let formatter = ISO8601DateFormatter()
            let now = Date()
            let envelope: [String: Any] = [
                "protocol_version": "1.4", "message_type": "command.request",
                "message_id": String(format: "018f0f4e-2f55-7f5c-8ca2-%012d", message),
                "request_id": requestID,
                "source": ["kind": "debug_console", "id": "location-test"],
                "issued_at": formatter.string(from: now.addingTimeInterval(-1)),
                "expires_at": formatter.string(from: now.addingTimeInterval(60)),
                "nonce": "fresh-nonce-\(message)-with-sufficient-entropy",
                "payload": ["action": "location.get", "risk_level": "L0", "parameters": [:]]
            ]
            return try JSONSerialization.data(withJSONObject: envelope)
        }
        let first = await runtime.submit(try request(message: 1))
        let second = await runtime.submit(try request(message: 2))
        let firstJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let secondJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: second) as? [String: Any])
        XCTAssertEqual((firstJSON["result"] as? [String: Any])?["status"] as? String, "succeeded")
        XCTAssertEqual((secondJSON["result"] as? [String: Any])?["stable_error"] as? String, "replay_detected")
        let counts = await backend.counts()
        XCTAssertEqual(counts.0, 1)
    }
}
