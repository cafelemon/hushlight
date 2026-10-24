import BridgeCore
import Foundation
import XCTest
@testable import HushlightMac

final class WeatherServiceTests: XCTestCase {
    func testServiceDoesNotFetchAtStartupAndPausedQueriesDoNotReachHTTP() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("weather-service-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = WeatherHTTPFake([try WeatherFixture.response(at: Date())])
        let service = LocalBridgeService(preferences: WeatherPauseStore(), timerStorageURL: root.appendingPathComponent("timers.json"),
                                         notesStorageURL: root.appendingPathComponent("notes.json"), weatherBackend: METWeatherBackend(client: client))
        _ = try await service.snapshot()
        let before = await client.requests
        XCTAssertTrue(before.isEmpty)
        try await service.setPaused(true)
        let rejected = try await service.readWeather(cityID: "beijing")
        XCTAssertEqual(rejected.stableError, "bridge_paused")
        let paused = await client.requests
        XCTAssertTrue(paused.isEmpty)
        try await service.setPaused(false)
        let result = try await service.readWeather(cityID: "beijing")
        XCTAssertEqual(result.status, "succeeded")
        XCTAssertEqual(result.report?.city.id, "beijing")
        let state = try await service.snapshot()
        XCTAssertEqual(state.recentActions.first?.name, "weather.get")
        XCTAssertFalse(String(describing: state.recentActions).contains("116.4"))
    }
}

private final class WeatherPauseStore: PausePreferenceStore, @unchecked Sendable {
    func loadPaused() -> Bool { false }
    func savePaused(_ paused: Bool) {}
}
