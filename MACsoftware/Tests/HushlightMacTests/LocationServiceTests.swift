import BridgeCore
import Foundation
import XCTest
@testable import HushlightMac

final class LocationServiceTests: XCTestCase {
    func testWorkbenchStateSkipsAuthorizationForUnsupportedLocationAction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("location-unsupported-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = ServiceLocationFake()
        let service = LocalBridgeService(preferences: LocationServicePauseStore(),
                                         timerStorageURL: root.appendingPathComponent("timers.json"),
                                         notesStorageURL: root.appendingPathComponent("notes.json"),
                                         locationBackend: backend,
                                         runtimeFactory: { paused, _, _, _, _, _ in
            try await BridgeLocalRuntime(simulate: true, paused: paused)
        })
        let state = try await service.workbenchState()
        XCTAssertFalse(state.supportedActions.contains("location.get"))
        XCTAssertNil(state.locationAuthorization)
        let reads = await backend.statusReadCount()
        XCTAssertEqual(reads, 0)
    }

    func testRejectedSimulationServiceCannotInspectPromptOrSampleBackend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("location-mode-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = ServiceLocationFake()
        let service = LocalBridgeService(preferences: LocationServicePauseStore(), timerStorageURL: root.appendingPathComponent("timers.json"),
                                         notesStorageURL: root.appendingPathComponent("notes.json"), locationBackend: backend,
                                         runtimeFactory: { paused, _, _, _, _, location in
            try await BridgeLocalRuntime(simulate: true, paused: paused, locationCoordinator: location)
        })
        do { try await service.requestLocationPermission(); XCTFail("Real backend in simulation") } catch {}
        do { _ = try await service.snapshot(); XCTFail("Real backend in simulation") } catch {}
        let counts = await backend.counts()
        let reads = await backend.statusReadCount()
        XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0); XCTAssertEqual(reads, 0)
    }

    func testExplicitPermissionAndReadPassThroughRuntimePause() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("location-service-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = ServiceLocationFake()
        let service = LocalBridgeService(preferences: LocationServicePauseStore(), timerStorageURL: root.appendingPathComponent("timers.json"),
                                         notesStorageURL: root.appendingPathComponent("notes.json"), locationBackend: backend)
        let initial = try await service.snapshot()
        XCTAssertEqual(initial.locationAuthorization, .notChecked)
        let before = await backend.counts()
        XCTAssertEqual(before.0, 0); XCTAssertEqual(before.1, 0)
        try await service.requestLocationPermission()
        let afterPermission = await backend.counts()
        XCTAssertEqual(afterPermission.0, 1); XCTAssertEqual(afterPermission.1, 0)
        let fix = try await service.readLocation()
        XCTAssertEqual(fix.status, "succeeded")
        XCTAssertEqual(fix.location?.latitude, 31.12)
        XCTAssertEqual(fix.location?.horizontalAccuracyMeters, 1500)
        let state = try await service.snapshot()
        XCTAssertEqual(state.recentActions.first?.name, "location.get")
        XCTAssertFalse(String(describing: state.recentActions).contains("31.123456"))
        try await service.setPaused(true)
        do { try await service.requestLocationPermission(); XCTFail("Paused request must not prompt") } catch StableErrorCode.bridgePaused {}
        let rejected = try await service.readLocation()
        XCTAssertEqual(rejected.stableError, "bridge_paused")
        let afterPause = await backend.counts()
        XCTAssertEqual(afterPause.0, 1); XCTAssertEqual(afterPause.1, 1)
    }
}

private final class LocationServicePauseStore: PausePreferenceStore, @unchecked Sendable {
    func loadPaused() -> Bool { false }
    func savePaused(_ paused: Bool) {}
}
private actor ServiceLocationFake: LocationBackend {
    private var authorization: LocationAuthorization = .notChecked
    private var prompts = 0
    private var samples = 0
    private var reads = 0
    func authorizationStatus() async -> LocationAuthorization { reads += 1; return authorization }
    func statusReadCount() -> Int { reads }
    func requestAuthorization() async throws -> LocationAuthorization { prompts += 1; authorization = .authorized; return authorization }
    func requestLocation() async throws -> LocationSample {
        samples += 1
        return .init(latitude: 31.123456, longitude: 121.234567, horizontalAccuracyMeters: 20, timestamp: Date())
    }
    func counts() -> (Int, Int) { (prompts, samples) }
}
