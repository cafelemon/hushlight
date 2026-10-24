import Foundation

public struct WeatherCity: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let region: String
    public let latitude: Double
    public let longitude: Double
    public let timeZoneID: String

    public init(id: String, name: String, region: String, latitude: Double, longitude: Double, timeZoneID: String) {
        self.id = id; self.name = name; self.region = region
        self.latitude = latitude; self.longitude = longitude; self.timeZoneID = timeZoneID
    }
}

public enum WeatherCities {
    public static let all: [WeatherCity] = [
        .init(id: "beijing", name: "北京", region: "中国", latitude: 40, longitude: 116.4, timeZoneID: "Asia/Shanghai"),
        .init(id: "shanghai", name: "上海", region: "中国", latitude: 31.23, longitude: 121.47, timeZoneID: "Asia/Shanghai"),
        .init(id: "guangzhou", name: "广州", region: "中国", latitude: 23.13, longitude: 113.26, timeZoneID: "Asia/Shanghai"),
        .init(id: "shenzhen", name: "深圳", region: "中国", latitude: 22.54, longitude: 114.06, timeZoneID: "Asia/Shanghai"),
        .init(id: "hangzhou", name: "杭州", region: "中国", latitude: 30.27, longitude: 120.15, timeZoneID: "Asia/Shanghai"),
        .init(id: "chengdu", name: "成都", region: "中国", latitude: 30.57, longitude: 104.07, timeZoneID: "Asia/Shanghai"),
        .init(id: "wuhan", name: "武汉", region: "中国", latitude: 30.59, longitude: 114.31, timeZoneID: "Asia/Shanghai"),
        .init(id: "xian", name: "西安", region: "中国", latitude: 34.34, longitude: 108.94, timeZoneID: "Asia/Shanghai"),
        .init(id: "chongqing", name: "重庆", region: "中国", latitude: 29.56, longitude: 106.55, timeZoneID: "Asia/Shanghai"),
        .init(id: "nanjing", name: "南京", region: "中国", latitude: 32.06, longitude: 118.8, timeZoneID: "Asia/Shanghai"),
        .init(id: "tokyo", name: "东京", region: "日本", latitude: 35.68, longitude: 139.76, timeZoneID: "Asia/Tokyo"),
        .init(id: "paris", name: "巴黎", region: "法国", latitude: 48.86, longitude: 2.35, timeZoneID: "Europe/Paris"),
        .init(id: "london", name: "伦敦", region: "英国", latitude: 51.51, longitude: -0.13, timeZoneID: "Europe/London")
    ]

    public static func byID(_ id: String) -> WeatherCity? { all.first { $0.id == id } }
}

public struct WeatherPoint: Codable, Equatable, Sendable {
    public let time: Date
    public let temperatureC: Double
    public let relativeHumidityPercent: Double
    public let windSpeedMS: Double
    public let symbol: String?

    public init(time: Date, temperatureC: Double, relativeHumidityPercent: Double, windSpeedMS: Double, symbol: String?) {
        self.time = time; self.temperatureC = temperatureC
        self.relativeHumidityPercent = relativeHumidityPercent; self.windSpeedMS = windSpeedMS
        self.symbol = symbol
    }
}

public struct WeatherReport: Codable, Equatable, Sendable {
    public let city: WeatherCity
    public let modelUpdatedAt: Date
    public let fetchedAt: Date
    public let current: WeatherPoint
    public let hourly: [WeatherPoint]
    public let isCached: Bool

    public init(city: WeatherCity, modelUpdatedAt: Date, fetchedAt: Date, current: WeatherPoint,
                hourly: [WeatherPoint], isCached: Bool) {
        self.city = city; self.modelUpdatedAt = modelUpdatedAt; self.fetchedAt = fetchedAt
        self.current = current; self.hourly = hourly; self.isCached = isCached
    }
}

public protocol WeatherBackend: Sendable {
    var isSimulation: Bool { get }
    func fetch(cityID: String) async throws -> WeatherReport
}

public extension WeatherBackend {
    var isSimulation: Bool { false }
}

public actor LocalWeatherCoordinator: CommandAdapter {
    public nonisolated let supportedActions: Set<String> = ["weather.get"]
    public nonisolated let isSimulation: Bool
    private let backend: any WeatherBackend
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(backend: any WeatherBackend) {
        self.backend = backend
        self.isSimulation = backend.isSimulation
    }

    func execute(_ command: BridgeCommand) async throws -> AdapterExecution {
        await acquire()
        defer { release() }
        try ActionParameterValidator().validate(action: command.action, parameters: command.parameters, protocolVersion: "1.3")
        guard case .object(let parameters) = command.parameters,
              case .string(let cityID)? = parameters["city_id"],
              let city = WeatherCities.byID(cityID) else { throw StableErrorCode.invalidSchema }

        let report: WeatherReport
        do { report = try await backend.fetch(cityID: cityID) }
        catch let error as StableErrorCode { throw error }
        catch { throw StableErrorCode.capabilityDisabled }
        try Self.verify(report, city: city, now: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw StableErrorCode.resultUnverifiable
        }
        return .succeeded(summary: .object(["report": json]))
    }

    private static func verify(_ report: WeatherReport, city: WeatherCity, now: Date) throws {
        guard report.city == city,
              report.modelUpdatedAt.timeIntervalSince1970.isFinite,
              report.fetchedAt.timeIntervalSince1970.isFinite,
              report.modelUpdatedAt <= now.addingTimeInterval(300),
              report.modelUpdatedAt >= now.addingTimeInterval(-24 * 3_600),
              report.fetchedAt <= now.addingTimeInterval(300),
              report.fetchedAt >= now.addingTimeInterval(-24 * 3_600),
              report.fetchedAt >= report.modelUpdatedAt.addingTimeInterval(-300),
              report.hourly.count == 12 else { throw StableErrorCode.resultUnverifiable }
        try verifyPoint(report.current)
        guard report.current.time <= now.addingTimeInterval(1), abs(report.current.time.timeIntervalSince(now)) <= 5_400 else {
            throw StableErrorCode.resultUnverifiable
        }
        for (index, point) in report.hourly.enumerated() {
            try verifyPoint(point)
            let expected = report.current.time.addingTimeInterval(Double(index + 1) * 3_600)
            guard abs(point.time.timeIntervalSince(expected)) <= 1 else {
                throw StableErrorCode.resultUnverifiable
            }
        }
    }

    private static func verifyPoint(_ point: WeatherPoint) throws {
        guard point.time.timeIntervalSince1970.isFinite,
              point.temperatureC.isFinite, (-100...70).contains(point.temperatureC),
              point.relativeHumidityPercent.isFinite, (0...100).contains(point.relativeHumidityPercent),
              point.windSpeedMS.isFinite, (0...150).contains(point.windSpeedMS),
              point.symbol.map({ !$0.isEmpty && $0.count <= 80 && $0.allSatisfy { character in
                  character.isASCII && (character.isLetter || character.isNumber || character == "_")
              } }) ?? true else {
            throw StableErrorCode.resultUnverifiable
        }
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
}
