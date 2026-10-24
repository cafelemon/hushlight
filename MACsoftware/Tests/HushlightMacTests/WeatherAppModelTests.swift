import BridgeCore
import Foundation
import XCTest
@testable import HushlightMac

@MainActor
final class WeatherAppModelTests: XCTestCase {
    func testSuccessfulQueryRefreshesRecentActions() async {
        let service = WeatherModelFixture()
        let model = AppModel(bridgeService: service)

        await model.refresh()
        XCTAssertNil(model.weatherResult)
        let initialReads = await service.readCount
        XCTAssertEqual(initialReads, 0)

        await model.readWeather(cityID: "beijing")
        XCTAssertEqual(model.weatherResult?.status, "succeeded")
        XCTAssertEqual(model.weatherResult?.report?.city.id, "beijing")
        XCTAssertNil(model.weatherError)
        XCTAssertEqual(model.recentActions.count, 1)
        XCTAssertFalse(model.isBusy)
    }

    func testChangingCityAndFailedQueryClearPreviousReport() async {
        let service = WeatherModelFixture()
        let model = AppModel(bridgeService: service)
        await model.readWeather(cityID: "beijing")
        XCTAssertNotNil(model.weatherResult?.report)

        model.clearWeather()
        XCTAssertNil(model.weatherResult)
        await service.failCity("london")
        await model.readWeather(cityID: "london")
        XCTAssertNil(model.weatherResult)
        XCTAssertNotNil(model.weatherError)
    }

    func testBusyDuplicateQueryDoesNotReachService() async {
        let service = WeatherModelFixture(suspendRead: true)
        let model = AppModel(bridgeService: service)
        let first = Task { await model.readWeather(cityID: "beijing") }
        await service.waitForReadStart()
        XCTAssertTrue(model.isBusy)

        await model.readWeather(cityID: "beijing")
        let reads = await service.readCount
        XCTAssertEqual(reads, 1)
        await service.releaseRead()
        await first.value
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.weatherResult?.report?.city.id, "beijing")
    }

    func testPausedQueryDoesNotReachService() async {
        let service = WeatherModelFixture()
        let model = AppModel(bridgeService: service)
        await model.refresh()
        await model.togglePause()

        await model.readWeather(cityID: "beijing")
        let reads = await service.readCount
        XCTAssertEqual(reads, 0)
        XCTAssertNil(model.weatherResult)
    }
}

private actor WeatherModelFixture: BridgeService {
    private let suspendRead: Bool
    private var paused = false
    private var failedCity: String?
    private var readContinuation: CheckedContinuation<Void, Never>?
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var readCount = 0

    init(suspendRead: Bool = false) { self.suspendRead = suspendRead }

    func snapshot() async throws -> BridgeSnapshot {
        let actions = (0..<readCount).map { _ in
            ActionRecord(name: "天气查询", outcome: .succeeded, occurredAt: Date())
        }
        return BridgeSnapshot(status: paused ? .paused : .localReady, permissions: [], recentActions: actions)
    }

    func setPaused(_ value: Bool) async throws { paused = value }
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
    func failCity(_ id: String) { failedCity = id }

    func readWeather(cityID: String) async throws -> LocalWeatherCommandResult {
        readCount += 1
        readWaiters.forEach { $0.resume() }
        readWaiters.removeAll()
        if suspendRead { await withCheckedContinuation { readContinuation = $0 } }
        if cityID == failedCity {
            return LocalWeatherCommandResult(status: "failed", stableError: "invalid_schema", completedAt: Date())
        }
        guard let city = WeatherCities.byID(cityID) else { throw BridgeServiceError.notConfigured }
        let now = Date()
        let point = WeatherPoint(time: now, temperatureC: 20, relativeHumidityPercent: 60,
                                 windSpeedMS: 3, symbol: nil)
        let report = WeatherReport(city: city, modelUpdatedAt: now, fetchedAt: now,
                                   current: point, hourly: [point], isCached: false)
        return LocalWeatherCommandResult(status: "succeeded", stableError: nil, completedAt: now,
                                         report: report)
    }

    func waitForReadStart() async {
        if readCount > 0 { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }

    func releaseRead() { readContinuation?.resume(); readContinuation = nil }
}
