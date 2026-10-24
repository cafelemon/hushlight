import BridgeCore
import Foundation
import XCTest
@testable import HushlightMac

final class LocalBridgeServiceTests: XCTestCase {
    func testLiveReadOnlyServiceSmoke() async throws {
        guard ProcessInfo.processInfo.environment["HUSHLIGHT_LIVE_VOLUME_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in real Core Audio read; regular tests need no audio hardware")
        }
        let (preferences, defaults, suite) = preferenceFixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = LocalBridgeService(preferences: preferences)
        let reading = try await service.readSystemVolume()
        XCTAssertFalse(reading.isSimulation)
        XCTAssertEqual(reading.outcome, .succeeded)
        let value = try XCTUnwrap(reading.value)
        XCTAssertTrue((0...100).contains(value))
        let state = try await service.snapshot()
        XCTAssertEqual(state.status, .localReady)
        XCTAssertEqual(state.recentActions.count, 1)
        print("Live LocalBridgeService -> BridgeLocalRuntime -> Core Audio: \(reading.outcome.rawValue)")
    }

    func testRealServiceUsesRuntimeAndRecordsActualResult() async throws {
        let (preferences, defaults, suite) = preferenceFixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = LocalBridgeService(preferences: preferences, runtimeFactory: simulatedRuntime)
        let initial = try await service.snapshot()
        XCTAssertEqual(initial.status, .localReady)
        XCTAssertTrue(initial.recentActions.isEmpty)
        XCTAssertTrue(initial.permissions.filter { $0.kind != .notifications }.allSatisfy { $0.state == .notRequested || $0.state == .notChecked })
        XCTAssertTrue(initial.permissions.contains { $0.kind == .notifications })
        let reading = try await service.readSystemVolume()
        XCTAssertEqual(reading.outcome, .succeeded)
        XCTAssertEqual(reading.value, 50)
        XCTAssertTrue(reading.isSimulation)
        let final = try await service.snapshot()
        XCTAssertEqual(final.recentActions.count, 1)
        XCTAssertEqual(final.recentActions[0].outcome, .succeeded)
        XCTAssertTrue(final.recentActions[0].name.hasPrefix("模拟"))
    }

    func testPauseSurvivesNewServiceAndRejectsAtRouter() async throws {
        let (preferences, defaults, suite) = preferenceFixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = LocalBridgeService(preferences: preferences, runtimeFactory: simulatedRuntime)
        try await first.setPaused(true)
        let restored = LocalBridgeService(preferences: preferences, runtimeFactory: simulatedRuntime)
        let paused = try await restored.snapshot()
        XCTAssertEqual(paused.status, .paused)
        let rejected = try await restored.readSystemVolume()
        XCTAssertEqual(rejected.outcome, .rejected)
        XCTAssertEqual(rejected.stableError, "bridge_paused")
        XCTAssertNil(rejected.value)
        try await restored.setPaused(false)
        let next = LocalBridgeService(preferences: preferences, runtimeFactory: simulatedRuntime)
        let resumed = try await next.snapshot()
        XCTAssertEqual(resumed.status, .localReady)
        let read = try await next.readSystemVolume()
        XCTAssertEqual(read.outcome, .succeeded)
    }

    func testConcurrentPausePersistenceMatchesRuntimeAndRestart() async throws {
        let (preferences, defaults, suite) = preferenceFixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = LocalBridgeService(preferences: preferences, runtimeFactory: simulatedRuntime)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask { try await service.setPaused(index.isMultiple(of: 2)) }
            }
            try await group.waitForAll()
        }
        let final = try await service.snapshot()
        XCTAssertEqual(final.status == .paused, preferences.loadPaused())
        let restored = LocalBridgeService(preferences: preferences, runtimeFactory: simulatedRuntime)
        let restarted = try await restored.snapshot()
        XCTAssertEqual(final.status, restarted.status)
    }

    func testRuntimeInitializationFailureDoesNotBecomeLocalReadyOrPersistPause() async throws {
        let (preferences, defaults, suite) = preferenceFixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = LocalBridgeService(preferences: preferences) { _ in
            throw BridgeServiceError.notConfigured
        }
        do {
            _ = try await service.snapshot()
            XCTFail("Expected initialization failure")
        } catch { XCTAssertFalse(preferences.loadPaused()) }
        do {
            try await service.setPaused(true)
            XCTFail("Expected initialization failure")
        } catch { XCTAssertFalse(preferences.loadPaused()) }
    }

    private var simulatedRuntime: @Sendable (Bool) async throws -> BridgeLocalRuntime {
        { try await BridgeLocalRuntime(simulate: true, paused: $0) }
    }

    private func preferenceFixture() -> (UserDefaultsPausePreferenceStore, UserDefaults, String) {
        let suite = "com.hushlight.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (UserDefaultsPausePreferenceStore(defaults: defaults), defaults, suite)
    }
}
