import BridgeCore
import Foundation
import XCTest
@testable import HushlightMac

final class METWeatherBackendTests: XCTestCase {
    func testExplicitFetchCachesAndBuildsOnlyFixedCityRequests() async throws {
        let clock = WeatherTestClock()
        let client = WeatherHTTPFake([try WeatherFixture.response(at: clock.now())])
        let backend = METWeatherBackend(client: client, now: { clock.now() })
        let before = await client.requests
        XCTAssertTrue(before.isEmpty)
        let first = try await backend.fetch(cityID: "beijing")
        XCTAssertFalse(first.isCached)
        XCTAssertEqual(first.hourly.count, 12)
        XCTAssertLessThanOrEqual(first.current.time, clock.now())
        XCTAssertEqual(clock.now().timeIntervalSince(first.current.time), 31 * 60, accuracy: 1)
        let second = try await backend.fetch(cityID: "beijing")
        XCTAssertTrue(second.isCached)
        XCTAssertEqual(second.fetchedAt, first.fetchedAt)
        let requests = await client.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.host, "api.met.no")
        XCTAssertEqual(requests[0].url?.path, "/weatherapi/locationforecast/2.0/compact")
        XCTAssertTrue(requests[0].value(forHTTPHeaderField: "User-Agent")?.contains("HushlightMacBridge") == true)
        let query = try XCTUnwrap(URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(Set(query.map(\.name)), ["lat", "lon"])
    }

    func testExpiredCacheUsesConditionalRequestAnd304KeepsOriginalFetchTime() async throws {
        let clock = WeatherTestClock()
        let first = try WeatherFixture.response(at: clock.now())
        let next = WeatherHTTPResponse(data: Data(), status: 304, headers: ["expires": WeatherFixture.httpDate(clock.now().addingTimeInterval(1800))])
        let client = WeatherHTTPFake([first, next])
        let backend = METWeatherBackend(client: client, now: { clock.now() })
        let original = try await backend.fetch(cityID: "beijing")
        clock.advance(601)
        let refreshed = try await backend.fetch(cityID: "beijing")
        XCTAssertTrue(refreshed.isCached)
        XCTAssertEqual(refreshed.fetchedAt, original.fetchedAt)
        let requests = await client.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-Modified-Since"), first.headers["last-modified"])
    }

    func testExpiredCacheNeverMasqueradesAsSuccessAfterNetworkFailure() async throws {
        let clock = WeatherTestClock()
        let client = WeatherHTTPFake([try WeatherFixture.response(at: clock.now()), WeatherHTTPResponse(data: Data(), status: 503, headers: [:])])
        let backend = METWeatherBackend(client: client, now: { clock.now() })
        _ = try await backend.fetch(cityID: "beijing")
        clock.advance(601)
        do { _ = try await backend.fetch(cityID: "beijing"); XCTFail("Expired data must not pass as fresh") }
        catch StableErrorCode.capabilityDisabled {}
    }

    func testRejectsWrongUnitsCoordinatesStaleAndInvalidValues() async throws {
        let clock = WeatherTestClock()
        for response in try [
            WeatherFixture.response(at: clock.now(), temperatureUnit: "fahrenheit"),
            WeatherFixture.response(at: clock.now(), longitude: -20),
            WeatherFixture.response(at: clock.now(), modelAge: 90000),
            WeatherFixture.response(at: clock.now(), temperature: 500),
            WeatherFixture.response(at: clock.now(), count: 8)
        ] {
            let backend = METWeatherBackend(client: WeatherHTTPFake([response]), now: { clock.now() })
            do { _ = try await backend.fetch(cityID: "beijing"); XCTFail("Unverifiable data must reject") }
            catch StableErrorCode.resultUnverifiable {}
        }
    }

    func testExplicitPastOrInvalidExpiresDoesNotBecomeFreshCache() async throws {
        let clock = WeatherTestClock()
        let valid = try WeatherFixture.response(at: clock.now())
        for expiry in [WeatherFixture.httpDate(clock.now().addingTimeInterval(-1)), "invalid-date"] {
            var headers = valid.headers
            headers["expires"] = expiry
            let expired = WeatherHTTPResponse(data: valid.data, status: 200, headers: headers)
            let client = WeatherHTTPFake([expired, expired])
            let backend = METWeatherBackend(client: client, now: { clock.now() })
            let first = try await backend.fetch(cityID: "beijing")
            let second = try await backend.fetch(cityID: "beijing")
            XCTAssertFalse(first.isCached)
            XCTAssertFalse(second.isCached)
            let calls = await client.requests
            XCTAssertEqual(calls.count, 2)
        }
    }

    func testUnknownCitiesAndForeignURLsNeverReachNetwork() async throws {
        let client = WeatherHTTPFake([])
        let backend = METWeatherBackend(client: client)
        do { _ = try await backend.fetch(cityID: "anything.example"); XCTFail("Unknown city") }
        catch StableErrorCode.invalidSchema {}
        let requests = await client.requests
        XCTAssertTrue(requests.isEmpty)
        let network = URLSessionWeatherClient()
        for value in ["http://api.met.no/weatherapi/locationforecast/2.0/compact", "https://example.com/", "https://api.met.no/other"] {
            var request = URLRequest(url: URL(string: value)!)
            request.httpMethod = "GET"
            do { _ = try await network.get(request); XCTFail("Disallowed endpoint") }
            catch StableErrorCode.invalidSchema {}
        }
    }
}

final class WeatherTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 3600) * 3600 + 31 * 60)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date = date.addingTimeInterval(seconds) }
}

actor WeatherHTTPFake: WeatherHTTPClient {
    private var responses: [WeatherHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [WeatherHTTPResponse]) { self.responses = responses }
    func get(_ request: URLRequest) async throws -> WeatherHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.notConnectedToInternet) }
        return responses.removeFirst()
    }
}

enum WeatherFixture {
    static func response(at time: Date, temperatureUnit: String = "celsius", longitude: Double = 116.4,
                         modelAge: TimeInterval = 600, temperature: Double = 18, count: Int = 36) throws -> WeatherHTTPResponse {
        let formatter = ISO8601DateFormatter()
        let start = Date(timeIntervalSince1970: floor(time.timeIntervalSince1970 / 3600) * 3600)
        let series: [[String: Any]] = (0..<count).map { offset in
            ["time": formatter.string(from: start.addingTimeInterval(Double(offset) * 3600)),
             "data": ["instant": ["details": ["air_temperature": temperature, "relative_humidity": 60.0, "wind_speed": 3.0]],
                      "next_1_hours": ["summary": ["symbol_code": "cloudy"]]]]
        }
        let object: [String: Any] = ["geometry": ["type": "Point", "coordinates": [longitude, 40.0]],
                                     "properties": ["meta": ["updated_at": formatter.string(from: time.addingTimeInterval(-modelAge)),
                                                              "units": ["air_temperature": temperatureUnit, "relative_humidity": "%", "wind_speed": "m/s"]],
                                                    "timeseries": series]]
        return WeatherHTTPResponse(data: try JSONSerialization.data(withJSONObject: object), status: 200,
                                   headers: ["content-type": "application/json", "expires": httpDate(time.addingTimeInterval(600)),
                                             "last-modified": httpDate(time.addingTimeInterval(-600))])
    }
    static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}
