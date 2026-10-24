import BridgeCore
import CoreLocation
import Foundation
import OSLog

protocol LocationSystemDriving: Sendable {
    func authorizationStatus() async -> LocationAuthorization
    func requestAuthorization() async throws -> LocationAuthorization
    func requestLocation() async throws -> LocationSample
}

/// A passive manager may be constructed to read a persisted authorization grant.
actor CoreLocationBackend: LocationBackend {
    nonisolated let isSimulation = false
    private let isAppBundle: Bool
    private let driverFactory: @Sendable () async -> any LocationSystemDriving
    private let servicesEnabled: @Sendable () -> Bool
    private var driver: (any LocationSystemDriving)?

    init(isAppBundle: Bool = Bundle.main.bundleIdentifier == "com.hushlight.bridge.mac",
         servicesEnabled: @escaping @Sendable () -> Bool = { CLLocationManager.locationServicesEnabled() },
         driverFactory: @escaping @Sendable () async -> any LocationSystemDriving = { OneShotLocationController() }) {
        self.isAppBundle = isAppBundle
        self.servicesEnabled = servicesEnabled
        self.driverFactory = driverFactory
    }

    func authorizationStatus() async -> LocationAuthorization {
        guard isAppBundle else { return .unavailable }
        guard servicesEnabled() else { return .servicesDisabled }
        let driver = await getDriver()
        return await driver.authorizationStatus()
    }

    func requestAuthorization() async throws -> LocationAuthorization {
        guard isAppBundle else { throw StableErrorCode.capabilityDisabled }
        // Called on this actor, never the main thread; the system check can block.
        guard servicesEnabled() else { return .servicesDisabled }
        let driver = await getDriver()
        return try await driver.requestAuthorization()
    }

    func requestLocation() async throws -> LocationSample {
        guard isAppBundle else { throw StableErrorCode.capabilityDisabled }
        guard servicesEnabled() else { throw StableErrorCode.permissionRequired }
        let driver = await getDriver()
        // The manager instance, rather than the deprecated class status, owns the current grant.
        guard await driver.authorizationStatus() == .authorized else { throw StableErrorCode.permissionRequired }
        let value = try await driver.requestLocation()
        let authorization = await driver.authorizationStatus()
        // Recheck after every suspension, before delivering even the temporary sample.
        guard servicesEnabled() else { throw StableErrorCode.permissionRequired }
        guard authorization == .authorized else { throw StableErrorCode.permissionRequired }
        return value
    }

    private func getDriver() async -> any LocationSystemDriving {
        if let driver { return driver }
        let value = await driverFactory()
        if let driver { return driver }
        driver = value
        return value
    }
}

@MainActor
protocol LocationManagerAccess: AnyObject, Sendable {
    var authorization: LocationAuthorization { get }
    var onAuthorization: (@MainActor @Sendable (LocationAuthorization) -> Void)? { get set }
    var onLocation: (@MainActor @Sendable (Result<LocationSample, StableErrorCode>) -> Void)? { get set }
    func requestAuthorization()
    func requestOneShot()
    func stop()
}

/// Constructed on the main runloop, so Core Location delegate callbacks use that runloop.
@MainActor
final class AppleLocationManagerAccess: NSObject, LocationManagerAccess, @preconcurrency CLLocationManagerDelegate {
    private static let logger = Logger(subsystem: "com.hushlight.bridge.mac", category: "location")
    private let manager: CLLocationManager
    var onAuthorization: (@MainActor @Sendable (LocationAuthorization) -> Void)?
    var onLocation: (@MainActor @Sendable (Result<LocationSample, StableErrorCode>) -> Void)?

    override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var authorization: LocationAuthorization { Self.map(manager.authorizationStatus) }
    func requestAuthorization() { manager.requestWhenInUseAuthorization() }
    func requestOneShot() { manager.requestLocation() }
    func stop() { manager.stopUpdatingLocation() }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorization?(Self.map(manager.authorizationStatus))
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.max(by: { $0.timestamp < $1.timestamp }) else {
            onLocation?(.failure(.resultUnverifiable)); return
        }
        onLocation?(.success(LocationSample(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                                           horizontalAccuracyMeters: location.horizontalAccuracy, timestamp: location.timestamp)))
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let value = error as NSError
        if value.domain == kCLErrorDomain {
            Self.logger.error("One-shot location failed with Core Location code \(value.code, privacy: .public)")
        } else {
            Self.logger.error("One-shot location failed outside Core Location")
        }
        onLocation?(.failure(Self.mapFailure(error)))
    }
    static func mapFailure(_ error: Error) -> StableErrorCode {
        let value = error as NSError
        guard value.domain == kCLErrorDomain else { return .resultUnverifiable }
        switch value.code {
        case CLError.Code.denied.rawValue, CLError.Code.promptDeclined.rawValue: return .permissionRequired
        case CLError.Code.locationUnknown.rawValue, CLError.Code.network.rawValue: return .resultUnverifiable
        default: return .resultUnverifiable
        }
    }
    nonisolated static func map(_ status: CLAuthorizationStatus) -> LocationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .authorizedAlways, .authorizedWhenInUse: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unavailable
        }
    }
}

/// Continuations are finished once; generation tokens discard callbacks from stopped managers.
@MainActor
final class OneShotLocationController: LocationSystemDriving {
    private static let logger = Logger(subsystem: "com.hushlight.bridge.mac", category: "location")
    private let factory: @MainActor @Sendable () -> any LocationManagerAccess
    private let authorizationTimeout: TimeInterval
    private let fixTimeout: TimeInterval
    private var access: (any LocationManagerAccess)?
    private var generation = UUID()
    private var authorizationPending: (UUID, CheckedContinuation<LocationAuthorization, Error>)?
    private var fixPending: (UUID, CheckedContinuation<LocationSample, Error>)?
    private var fixRetryUsed = false
    private var fixAwaitingAuthorization = false
    private var authorizationTimer: Task<Void, Never>?
    private var fixTimer: Task<Void, Never>?

    init(authorizationTimeout: TimeInterval = 30, fixTimeout: TimeInterval = 20,
         factory: @escaping @MainActor @Sendable () -> any LocationManagerAccess = { AppleLocationManagerAccess() }) {
        self.authorizationTimeout = authorizationTimeout
        self.fixTimeout = fixTimeout
        self.factory = factory
    }

    func authorizationStatus() async -> LocationAuthorization {
        let access = self.access ?? installAccess()
        let token = generation
        let status = await settledAuthorization(for: access)
        if generation == token { return status }
        // A concurrent one-shot may have replaced the manager while we were waiting.
        guard let currentAccess = self.access else { return .notChecked }
        let currentToken = generation
        let currentStatus = await settledAuthorization(for: currentAccess)
        return generation == currentToken ? currentStatus : .notChecked
    }

    func requestAuthorization() async throws -> LocationAuthorization {
        try Task.checkCancellation()
        guard authorizationPending == nil, fixPending == nil else { throw StableErrorCode.capabilityDisabled }
        let access = self.access ?? installAccess()
        guard access.authorization == .notDetermined else { return access.authorization }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                authorizationPending = (id, continuation)
                authorizationTimer = Task { [weak self, authorizationTimeout] in
                    do { try await Task.sleep(for: .seconds(authorizationTimeout)) } catch { return }
                    self?.finishAuthorization(id: id, result: .failure(StableErrorCode.executionTimeout))
                }
                access.requestAuthorization()
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.finishAuthorization(id: id, result: .failure(CancellationError())) }
        }
    }

    func requestLocation() async throws -> LocationSample {
        try Task.checkCancellation()
        guard authorizationPending == nil, fixPending == nil else { throw StableErrorCode.capabilityDisabled }
        // Fresh manager generation prevents late callbacks after timeout/cancel from satisfying the next request.
        // A fresh manager verifies authorization again before each location request.
        let access = installAccess()
        let token = generation
        let status = await settledAuthorization(for: access)
        try Task.checkCancellation()
        guard generation == token, authorizationPending == nil, fixPending == nil else {
            throw StableErrorCode.capabilityDisabled
        }
        guard status == .authorized else { throw StableErrorCode.permissionRequired }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                fixPending = (id, continuation)
                fixRetryUsed = false
                fixTimer = Task { [weak self, fixTimeout] in
                    do { try await Task.sleep(for: .seconds(fixTimeout)) } catch { return }
                    self?.finishFix(id: id, result: .failure(StableErrorCode.executionTimeout))
                }
                access.requestOneShot()
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.finishFix(id: id, result: .failure(CancellationError())) }
        }
    }

    private func installAccess() -> any LocationManagerAccess {
        access?.stop()
        access?.onAuthorization = nil
        access?.onLocation = nil
        let value = factory()
        let token = UUID()
        generation = token
        value.onAuthorization = { [weak self] status in
            guard let self, self.generation == token else { return }
            if let (id, _) = self.authorizationPending, status != .notDetermined {
                self.finishAuthorization(id: id, result: .success(status))
            }
            if let (id, _) = self.fixPending, status != .authorized,
               !(self.fixAwaitingAuthorization && status == .notDetermined) {
                self.finishFix(id: id, result: .failure(StableErrorCode.permissionRequired))
            }
        }
        value.onLocation = { [weak self] result in
            guard let self, self.generation == token, let (id, _) = self.fixPending else { return }
            self.handleFix(id: id, result: result)
        }
        access = value
        return value
    }
    private func handleFix(id: UUID, result: Result<LocationSample, StableErrorCode>) {
        guard fixPending?.0 == id else { return }
        switch result {
        case .success(let sample):
            if let issue = sample.qualityIssue(at: Date()) {
                Self.logger.error("One-shot location sample rejected for \(issue.rawValue, privacy: .public)")
                retryFixOrFinish(id: id)
            } else {
                finishFix(id: id, result: .success(sample))
            }
        case .failure(.resultUnverifiable):
            retryFixOrFinish(id: id)
        case .failure(let error):
            finishFix(id: id, result: .failure(error))
        }
    }
    private func retryFixOrFinish(id: UUID) {
        guard !fixRetryUsed else {
            finishFix(id: id, result: .failure(StableErrorCode.resultUnverifiable))
            return
        }
        fixRetryUsed = true
        // The original timer remains active: two one-shot attempts share one 20-second budget.
        fixAwaitingAuthorization = true
        let access = installAccess()
        let token = generation
        Task { [weak self] in
            guard let self else { return }
            let status = await self.settledAuthorization(for: access)
            guard self.fixPending?.0 == id, self.generation == token else { return }
            self.fixAwaitingAuthorization = false
            guard status == .authorized else {
                self.finishFix(id: id, result: .failure(StableErrorCode.permissionRequired))
                return
            }
            access.requestOneShot()
        }
    }
    private func settledAuthorization(for access: any LocationManagerAccess) async -> LocationAuthorization {
        // A new manager can briefly report notDetermined before its initial delegate callback.
        if access.authorization == .notDetermined {
            try? await Task.sleep(for: .milliseconds(300))
        }
        return access.authorization
    }
    private func finishAuthorization(id: UUID, result: Result<LocationAuthorization, Error>) {
        guard let (pendingID, continuation) = authorizationPending, pendingID == id else { return }
        authorizationPending = nil
        authorizationTimer?.cancel(); authorizationTimer = nil
        access?.stop()
        continuation.resume(with: result)
    }
    private func finishFix(id: UUID, result: Result<LocationSample, Error>) {
        guard let (pendingID, continuation) = fixPending, pendingID == id else { return }
        fixPending = nil
        fixRetryUsed = false
        fixAwaitingAuthorization = false
        fixTimer?.cancel(); fixTimer = nil
        access?.stop()
        continuation.resume(with: result)
    }
}
