import Foundation

public enum LocationAuthorization: String, Codable, Sendable {
    case notChecked, notDetermined, authorized, denied, restricted, servicesDisabled, unavailable
}

/// A temporary, unrounded sample. Callers must not retain or log this value.
public struct LocationSample: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracyMeters: Double
    public let timestamp: Date

    public init(latitude: Double, longitude: Double, horizontalAccuracyMeters: Double, timestamp: Date) {
        self.latitude = latitude; self.longitude = longitude
        self.horizontalAccuracyMeters = horizontalAccuracyMeters; self.timestamp = timestamp
    }

    public func qualityIssue(at now: Date) -> LocationSampleIssue? {
        guard latitude.isFinite, (-90...90).contains(latitude), longitude.isFinite,
              (-180...180).contains(longitude) else { return .invalidCoordinate }
        guard horizontalAccuracyMeters.isFinite, horizontalAccuracyMeters > 0,
              horizontalAccuracyMeters <= 100_000 else { return .invalidAccuracy }
        guard timestamp.timeIntervalSince1970.isFinite else { return .invalidTimestamp }
        if timestamp < now.addingTimeInterval(-60) { return .stale }
        if timestamp > now.addingTimeInterval(5) { return .future }
        return nil
    }
}

public enum LocationSampleIssue: String, Sendable {
    case invalidCoordinate, invalidAccuracy, invalidTimestamp, stale, future
}

public struct LocalLocationRecord: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracyMeters: Double
    public let timestamp: Date
    public let source: String
    public let isApproximate: Bool

    public init(latitude: Double, longitude: Double, horizontalAccuracyMeters: Double, timestamp: Date) {
        self.latitude = latitude; self.longitude = longitude
        self.horizontalAccuracyMeters = horizontalAccuracyMeters; self.timestamp = timestamp
        self.source = "Core Location"; self.isApproximate = true
    }
}

public protocol LocationBackend: Sendable {
    var isSimulation: Bool { get }
    func authorizationStatus() async -> LocationAuthorization
    func requestAuthorization() async throws -> LocationAuthorization
    func requestLocation() async throws -> LocationSample
}

public extension LocationBackend {
    var isSimulation: Bool { false }
}

public actor LocalLocationCoordinator: CommandAdapter {
    public nonisolated let supportedActions: Set<String> = ["location.get"]
    public nonisolated let isSimulation: Bool
    private let backend: any LocationBackend
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(backend: any LocationBackend) {
        self.backend = backend
        self.isSimulation = backend.isSimulation
    }

    func execute(_ command: BridgeCommand) async throws -> AdapterExecution {
        await acquire()
        defer { release() }
        try ActionParameterValidator().validate(action: command.action, parameters: command.parameters,
                                                protocolVersion: BridgeProtocolValidator.locationVersion)
        let authorization = await backend.authorizationStatus()
        if authorization != .authorized {
            switch authorization {
            case .notChecked, .notDetermined, .denied, .restricted: throw StableErrorCode.permissionRequired
            case .servicesDisabled, .unavailable: throw StableErrorCode.capabilityDisabled
            case .authorized: break
            }
        }
        let sample: LocationSample
        do { sample = try await backend.requestLocation() }
        catch let error as StableErrorCode { throw error }
        catch { throw StableErrorCode.resultUnverifiable }
        guard sample.qualityIssue(at: Date()) == nil else {
            throw StableErrorCode.resultUnverifiable
        }
        // Only this reduced record crosses the command boundary. The raw sample dies here.
        let record = LocalLocationRecord(latitude: (sample.latitude * 100).rounded() / 100,
                                         longitude: (sample.longitude * 100).rounded() / 100,
                                         horizontalAccuracyMeters: max(sample.horizontalAccuracyMeters, 1_500),
                                         timestamp: sample.timestamp)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw StableErrorCode.resultUnverifiable
        }
        return .succeeded(summary: .object(["location": json]))
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
