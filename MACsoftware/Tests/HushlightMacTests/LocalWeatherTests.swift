import Foundation
import XCTest
@testable import BridgeCore

private actor FakeWeatherBackend: WeatherBackend {
    nonisolated let isSimulation = true
    var report: WeatherReport?
    var failure = false
    var calls = 0
    func fetch(cityID: String) async throws -> WeatherReport {
        calls += 1
        if failure { throw URLError(.notConnectedToInternet) }
        return report ?? Self.validReport(cityID: cityID)
    }
    func setReport(_ value: WeatherReport?) { report = value }
    func setFailure(_ value: Bool) { failure = value }
    func count() -> Int { calls }

    static func validReport(cityID: String) -> WeatherReport {
        let now = Date()
        let point = WeatherPoint(time: now, temperatureC: 21, relativeHumidityPercent: 70,
                                 windSpeedMS: 2, symbol: "clearsky_day")
        return WeatherReport(city: WeatherCities.byID(cityID)!, modelUpdatedAt: now.addingTimeInterval(-3_600),
                             fetchedAt: now, current: point,
                             hourly: (1...12).map { offset in
                                 .init(time: now.addingTimeInterval(Double(offset) * 3_600), temperatureC: 22,
                                       relativeHumidityPercent: 65, windSpeedMS: 3, symbol: nil)
                             },
                             isCached: false)
    }
}

private actor RealCountingWeatherBackend: WeatherBackend {
    var calls = 0
    func fetch(cityID: String) async throws -> WeatherReport {
        calls += 1
        return FakeWeatherBackend.validReport(cityID: cityID)
    }
    func count() -> Int { calls }
}

final class LocalWeatherTests: XCTestCase {
    func testRoundTripCatalogAndHistory() async throws {
        XCTAssertEqual(WeatherCities.all.count, 13)
        XCTAssertEqual(Set(WeatherCities.all.map(\.id)).count, 13)
        let backend = FakeWeatherBackend()
        let runtime = try await BridgeLocalRuntime(simulate: true, weatherCoordinator: LocalWeatherCoordinator(backend: backend))
        let result = await runtime.readWeather(cityID: "beijing")
        XCTAssertEqual(result.status, "succeeded")
        XCTAssertEqual(result.report?.city.id, "beijing")
        XCTAssertEqual(result.report?.hourly.count, 12)
        XCTAssertTrue(result.isSimulation)
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.recentActions.map(\.action), ["weather.get"])
        XCTAssertFalse(String(describing: snapshot).contains("116.4"))
    }

    func testInvalidCityPauseAndSimulationGuardDoNotCallBackend() async throws {
        let backend = FakeWeatherBackend()
        let runtime = try await BridgeLocalRuntime(simulate: true, weatherCoordinator: LocalWeatherCoordinator(backend: backend))
        let invalid = await runtime.readWeather(cityID: "unknown")
        XCTAssertEqual(invalid.stableError, "invalid_schema")
        let callsAfterInvalid = await backend.count()
        XCTAssertEqual(callsAfterInvalid, 0)
        await runtime.setPaused(true)
        let paused = await runtime.readWeather(cityID: "beijing")
        XCTAssertEqual(paused.stableError, "bridge_paused")
        let callsAfterPause = await backend.count()
        XCTAssertEqual(callsAfterPause, 0)

        let real = RealCountingWeatherBackend()
        do {
            _ = try await BridgeLocalRuntime(simulate: true, weatherCoordinator: LocalWeatherCoordinator(backend: real))
            XCTFail("Real backend entered simulation")
        } catch {
            XCTAssertEqual(error as? BridgeLocalCLIConfigurationError, .conflictingModes)
        }
        let realCalls = await real.count()
        XCTAssertEqual(realCalls, 0)
    }

    func testUntrustedReportAndNetworkFailure() async throws {
        let backend = FakeWeatherBackend()
        let runtime = try await BridgeLocalRuntime(simulate: true, weatherCoordinator: LocalWeatherCoordinator(backend: backend))
        let valid = FakeWeatherBackend.validReport(cityID: "beijing")
        let badReports = [
            WeatherReport(city: WeatherCities.byID("london")!, modelUpdatedAt: valid.modelUpdatedAt,
                          fetchedAt: valid.fetchedAt, current: valid.current, hourly: valid.hourly, isCached: false),
            WeatherReport(city: valid.city, modelUpdatedAt: Date().addingTimeInterval(-72 * 3_600),
                          fetchedAt: valid.fetchedAt, current: valid.current, hourly: valid.hourly, isCached: false),
            WeatherReport(city: valid.city, modelUpdatedAt: Date().addingTimeInterval(3_600),
                          fetchedAt: valid.fetchedAt, current: valid.current, hourly: valid.hourly, isCached: false),
            WeatherReport(city: valid.city, modelUpdatedAt: Date().addingTimeInterval(-25 * 3_600),
                          fetchedAt: valid.fetchedAt, current: valid.current, hourly: valid.hourly, isCached: false),
            WeatherReport(city: valid.city, modelUpdatedAt: valid.modelUpdatedAt,
                          fetchedAt: Date().addingTimeInterval(-25 * 3_600),
                          current: valid.current, hourly: valid.hourly, isCached: false),
            WeatherReport(city: valid.city, modelUpdatedAt: valid.modelUpdatedAt,
                          fetchedAt: valid.fetchedAt,
                          current: .init(time: valid.current.time.addingTimeInterval(3600), temperatureC: 21,
                                         relativeHumidityPercent: 70, windSpeedMS: 2, symbol: nil),
                          hourly: valid.hourly.map { point in
                              .init(time: point.time.addingTimeInterval(3600), temperatureC: point.temperatureC,
                                    relativeHumidityPercent: point.relativeHumidityPercent,
                                    windSpeedMS: point.windSpeedMS, symbol: point.symbol)
                          }, isCached: false),
            WeatherReport(city: valid.city, modelUpdatedAt: valid.modelUpdatedAt,
                          fetchedAt: valid.fetchedAt,
                          current: .init(time: valid.current.time, temperatureC: .nan,
                                         relativeHumidityPercent: 70, windSpeedMS: 2, symbol: nil),
                          hourly: valid.hourly, isCached: false),
            WeatherReport(city: valid.city, modelUpdatedAt: valid.modelUpdatedAt,
                          fetchedAt: valid.fetchedAt,
                          current: .init(time: Date().addingTimeInterval(-5_401), temperatureC: 21,
                                         relativeHumidityPercent: 70, windSpeedMS: 2, symbol: nil),
                          hourly: valid.hourly, isCached: false),
            WeatherReport(city: valid.city, modelUpdatedAt: valid.modelUpdatedAt,
                          fetchedAt: valid.fetchedAt, current: valid.current,
                          hourly: Array(valid.hourly.dropLast()), isCached: false),
            WeatherReport(city: valid.city, modelUpdatedAt: valid.modelUpdatedAt,
                          fetchedAt: valid.fetchedAt, current: valid.current,
                          hourly: valid.hourly.enumerated().map { index, point in
                              index == 5 ? .init(time: point.time.addingTimeInterval(2), temperatureC: point.temperatureC,
                                                 relativeHumidityPercent: point.relativeHumidityPercent,
                                                 windSpeedMS: point.windSpeedMS, symbol: point.symbol) : point
                          }, isCached: false),
            WeatherReport(city: valid.city, modelUpdatedAt: valid.modelUpdatedAt,
                          fetchedAt: valid.fetchedAt,
                          current: .init(time: valid.current.time, temperatureC: 21,
                                         relativeHumidityPercent: 70, windSpeedMS: 2, symbol: "☀️"),
                          hourly: valid.hourly, isCached: false)
        ]
        for report in badReports {
            await backend.setReport(report)
            let result = await runtime.readWeather(cityID: "beijing")
            XCTAssertEqual(result.status, "unknown")
            XCTAssertEqual(result.stableError, "result_unverifiable")
            XCTAssertNil(result.report)
        }
        await backend.setReport(nil)
        await backend.setFailure(true)
        let unavailable = await runtime.readWeather(cityID: "beijing")
        XCTAssertEqual(unavailable.stableError, "capability_disabled")
        XCTAssertNil(unavailable.report)
        await backend.setFailure(false)
        let recovered = await runtime.readWeather(cityID: "beijing")
        XCTAssertEqual(recovered.status, "succeeded")
    }
}
