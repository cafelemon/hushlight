import BridgeCore
import Foundation

struct WeatherHTTPResponse: Sendable {
    let data: Data
    let status: Int
    let headers: [String: String]
}

protocol WeatherHTTPClient: Sendable {
    func get(_ request: URLRequest) async throws -> WeatherHTTPResponse
}

private final class WeatherRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct URLSessionWeatherClient: WeatherHTTPClient {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        session = URLSession(configuration: configuration, delegate: WeatherRedirectPolicy(), delegateQueue: nil)
    }

    func get(_ request: URLRequest) async throws -> WeatherHTTPResponse {
        guard request.httpMethod == "GET", let url = request.url,
              url.scheme == "https", url.host == "api.met.no", url.port == nil,
              url.user == nil, url.password == nil,
              url.path == "/weatherapi/locationforecast/2.0/compact" else { throw StableErrorCode.invalidSchema }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw StableErrorCode.resultUnverifiable }
        guard response.expectedContentLength <= 1_000_000 else { throw StableErrorCode.resultUnverifiable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_000_000 else { throw StableErrorCode.resultUnverifiable }
            data.append(byte)
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
        return WeatherHTTPResponse(data: data, status: response.statusCode, headers: headers)
    }
}

/// No requests in init/snapshot; only explicit weather.get reaches this backend.
actor METWeatherBackend: WeatherBackend {
    nonisolated let isSimulation = false
    private let client: any WeatherHTTPClient
    private let now: @Sendable () -> Date
    private var cache: [String: Cache] = [:]
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private struct Cache {
        let document: Document
        let fetchedAt: Date
        var expiresAt: Date
        var lastModified: String?
    }
    private struct Document: Decodable {
        let geometry: Geometry
        let properties: Properties
    }
    private struct Geometry: Decodable { let type: String; let coordinates: [Double] }
    private struct Properties: Decodable { let meta: Meta; let timeseries: [Series] }
    private struct Meta: Decodable {
        let updated_at: Date
        let units: [String: String]
    }
    private struct Series: Decodable { let time: Date; let data: SeriesData }
    private struct SeriesData: Decodable {
        let instant: Instant
        let next_1_hours: Period?
    }
    private struct Instant: Decodable { let details: Details }
    private struct Details: Decodable {
        let air_temperature: Double
        let relative_humidity: Double
        let wind_speed: Double
    }
    private struct Period: Decodable { let summary: SymbolSummary }
    private struct SymbolSummary: Decodable { let symbol_code: String }

    init(client: any WeatherHTTPClient = URLSessionWeatherClient(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client; self.now = now
    }

    func fetch(cityID: String) async throws -> WeatherReport {
        await acquire(); defer { release() }
        guard let city = WeatherCities.all.first(where: { $0.id == cityID }) else { throw StableErrorCode.invalidSchema }
        let time = now()
        if let saved = cache[cityID], saved.fetchedAt <= time, saved.expiresAt > time {
            return try report(saved.document, city: city, fetchedAt: saved.fetchedAt, time: time, cached: true)
        }
        var components = URLComponents(string: "https://api.met.no/weatherapi/locationforecast/2.0/compact")!
        components.queryItems = [URLQueryItem(name: "lat", value: String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), city.latitude)),
                                 URLQueryItem(name: "lon", value: String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), city.longitude))]
        guard let url = components.url else { throw StableErrorCode.invalidSchema }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("HushlightMacBridge/0.0.1 (macOS city forecast)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let lastModified = cache[cityID]?.lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let response: WeatherHTTPResponse
        do { response = try await client.get(request) }
        catch let error as StableErrorCode { throw error }
        catch { throw StableErrorCode.capabilityDisabled }
        let receivedAt = now()
        if response.status == 304, var saved = cache[cityID], request.value(forHTTPHeaderField: "If-Modified-Since") != nil {
            saved.expiresAt = Self.expiration(response.headers, now: receivedAt)
            if let value = response.headers["last-modified"] { saved.lastModified = value }
            let value = try report(saved.document, city: city, fetchedAt: saved.fetchedAt, time: receivedAt, cached: true)
            cache[cityID] = saved
            return value
        }
        guard response.status == 200 else { throw StableErrorCode.capabilityDisabled }
        guard response.data.count <= 1_000_000,
              response.headers["content-type"]?.lowercased().components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) == "application/json" else {
            throw StableErrorCode.resultUnverifiable
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document: Document
        do { document = try decoder.decode(Document.self, from: response.data) }
        catch { throw StableErrorCode.resultUnverifiable }
        let value = try report(document, city: city, fetchedAt: receivedAt, time: receivedAt, cached: false)
        // At most one cached response for each fixed city; failures never replace a valid document.
        cache[cityID] = Cache(document: document, fetchedAt: receivedAt,
                              expiresAt: Self.expiration(response.headers, now: receivedAt),
                              lastModified: response.headers["last-modified"])
        return value
    }

    private func report(_ document: Document, city: WeatherCity, fetchedAt: Date, time: Date, cached: Bool) throws -> WeatherReport {
        let units = document.properties.meta.units
        guard units["air_temperature"] == "celsius", units["relative_humidity"] == "%", units["wind_speed"] == "m/s",
              document.geometry.type == "Point", document.geometry.coordinates.count >= 2,
              abs(document.geometry.coordinates[0] - city.longitude) <= 0.2,
              abs(document.geometry.coordinates[1] - city.latitude) <= 0.2,
              document.properties.meta.updated_at <= time.addingTimeInterval(300),
              document.properties.meta.updated_at >= time.addingTimeInterval(-86400),
              (13...300).contains(document.properties.timeseries.count) else { throw StableErrorCode.resultUnverifiable }
        let series = document.properties.timeseries
        guard zip(series, series.dropFirst()).allSatisfy({ $0.time < $1.time }) else { throw StableErrorCode.resultUnverifiable }
        let points = try series.map { item -> WeatherPoint in
            let detail = item.data.instant.details
            guard detail.air_temperature.isFinite, (-100...65).contains(detail.air_temperature),
                  detail.relative_humidity.isFinite, (0...100).contains(detail.relative_humidity),
                  detail.wind_speed.isFinite, (0...150).contains(detail.wind_speed) else { throw StableErrorCode.resultUnverifiable }
            let symbol = item.data.next_1_hours?.summary.symbol_code
            guard symbol == nil || (symbol!.count <= 80 && symbol!.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })) else {
                throw StableErrorCode.resultUnverifiable
            }
            return WeatherPoint(time: item.time, temperatureC: detail.air_temperature,
                                relativeHumidityPercent: detail.relative_humidity, windSpeedMS: detail.wind_speed, symbol: symbol)
        }
        guard let current = points.last(where: { $0.time <= time }),
              abs(current.time.timeIntervalSince(time)) <= 5400 else { throw StableErrorCode.resultUnverifiable }
        let hourly = Array(points.filter { $0.time > current.time && $0.time <= current.time.addingTimeInterval(12 * 3600) }.prefix(12))
        guard hourly.count == 12,
              zip([current] + hourly, hourly).allSatisfy({ abs($1.time.timeIntervalSince($0.time) - 3600) <= 1 }) else {
            throw StableErrorCode.resultUnverifiable
        }
        return WeatherReport(city: city, modelUpdatedAt: document.properties.meta.updated_at,
                             fetchedAt: fetchedAt, current: current, hourly: hourly, isCached: cached)
    }

    private static func expiration(_ headers: [String: String], now: Date) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        if let raw = headers["expires"] {
            // An explicit stale/invalid expiry must not be promoted to a fresh cache entry.
            return formatter.date(from: raw) ?? now
        }
        return now.addingTimeInterval(600)
    }
    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
