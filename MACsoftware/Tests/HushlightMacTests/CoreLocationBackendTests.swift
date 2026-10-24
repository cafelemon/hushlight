import BridgeCore
import CoreLocation
import Foundation
import XCTest
@testable import HushlightMac

@MainActor
final class CoreLocationBackendTests: XCTestCase {
    func testNativeOneShotFailuresKeepPermissionSeparateFromMissingFix() {
        func error(_ code: CLError.Code) -> NSError {
            NSError(domain: kCLErrorDomain, code: code.rawValue)
        }
        XCTAssertEqual(AppleLocationManagerAccess.mapFailure(error(.denied)), .permissionRequired)
        XCTAssertEqual(AppleLocationManagerAccess.mapFailure(error(.locationUnknown)), .resultUnverifiable)
        XCTAssertEqual(AppleLocationManagerAccess.mapFailure(error(.network)), .resultUnverifiable)
        XCTAssertEqual(AppleLocationManagerAccess.mapFailure(NSError(domain: "other", code: 1)), .resultUnverifiable)
    }

    func testPassiveStatusAndPermissionDoNotSample() async throws {
        let manager = LocationAccessFake(authorization: .notDetermined)
        let pool = LocationAccessPool([manager])
        let controller = OneShotLocationController(factory: { pool.next() })
        let backend = CoreLocationBackend(isAppBundle: true, servicesEnabled: { true },
                                          driverFactory: { controller })
        let initial = await backend.authorizationStatus()
        XCTAssertEqual(initial, .notDetermined)
        XCTAssertEqual(pool.creations, 1)
        XCTAssertEqual(manager.authorizationRequests, 0)
        XCTAssertEqual(manager.fixRequests, 0)
        do { _ = try await backend.requestLocation(); XCTFail("No implicit authorization") }
        catch StableErrorCode.permissionRequired {}
        XCTAssertEqual(pool.creations, 1)
        XCTAssertEqual(manager.authorizationRequests, 0)
        XCTAssertEqual(manager.fixRequests, 0)
        let task = Task { try await backend.requestAuthorization() }
        await manager.waitForAuthorizationStart()
        XCTAssertEqual(manager.fixRequests, 0)
        manager.setAuthorization(.authorized)
        let result = try await task.value
        XCTAssertEqual(result, .authorized)
        XCTAssertEqual(manager.authorizationRequests, 1)
        XCTAssertEqual(manager.fixRequests, 0)
    }

    func testPersistedGrantCanSampleWithoutNewPermissionRequest() async throws {
        let manager = LocationAccessFake(authorization: .authorized)
        let fix = LocationAccessFake(authorization: .authorized)
        let pool = LocationAccessPool([manager, fix])
        let controller = OneShotLocationController(factory: { pool.next() })
        let backend = CoreLocationBackend(isAppBundle: true, servicesEnabled: { true },
                                          driverFactory: { controller })
        let initial = await backend.authorizationStatus()
        XCTAssertEqual(initial, .authorized)
        XCTAssertEqual(pool.creations, 1)
        XCTAssertEqual(manager.authorizationRequests, 0)
        XCTAssertEqual(manager.fixRequests, 0)
        let task = Task { try await backend.requestLocation() }
        await fix.waitForFixStart()
        fix.emit(.success(Self.sample(12)))
        let sample = try await task.value
        XCTAssertEqual(sample.latitude, 12)
        XCTAssertEqual(manager.authorizationRequests, 0)
        XCTAssertEqual(fix.authorizationRequests, 0)
        XCTAssertEqual(pool.creations, 2)
    }

    func testInitialAuthorizationCallbackRestoresGrantWithoutPromptOrFix() async throws {
        let manager = LocationAccessFake(authorization: .notDetermined)
        let pool = LocationAccessPool([manager])
        let controller = OneShotLocationController(factory: { pool.next() })
        let backend = CoreLocationBackend(isAppBundle: true, servicesEnabled: { true }, driverFactory: { controller })
        let status = Task { await backend.authorizationStatus() }
        try await Task.sleep(for: .milliseconds(20))
        manager.setAuthorization(.authorized)
        let result = await status.value
        XCTAssertEqual(result, .authorized)
        XCTAssertEqual(pool.creations, 1)
        XCTAssertEqual(manager.authorizationRequests, 0)
        XCTAssertEqual(manager.fixRequests, 0)
    }

    func testConcurrentPassiveStatusesShareManagerAndWaitForInitialGrant() async throws {
        let manager = LocationAccessFake(authorization: .notDetermined)
        let pool = LocationAccessPool([manager])
        let controller = OneShotLocationController(factory: { pool.next() })
        let backend = CoreLocationBackend(isAppBundle: true, servicesEnabled: { true }, driverFactory: { controller })
        let first = Task { await backend.authorizationStatus() }
        let second = Task { await backend.authorizationStatus() }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(pool.creations, 1)
        XCTAssertEqual(manager.authorizationRequests, 0)
        XCTAssertEqual(manager.fixRequests, 0)
        manager.setAuthorization(.authorized)
        let results = await (first.value, second.value)
        XCTAssertEqual(results.0, .authorized)
        XCTAssertEqual(results.1, .authorized)
        XCTAssertEqual(pool.creations, 1)
        XCTAssertEqual(manager.authorizationRequests, 0)
        XCTAssertEqual(manager.fixRequests, 0)
    }

    func testFreshFixManagerWaitsForInitialGrantWithoutPrompt() async throws {
        let passive = LocationAccessFake(authorization: .authorized)
        let fix = LocationAccessFake(authorization: .notDetermined)
        let pool = LocationAccessPool([passive, fix])
        let controller = OneShotLocationController(factory: { pool.next() })
        let backend = CoreLocationBackend(isAppBundle: true, servicesEnabled: { true }, driverFactory: { controller })
        let status = await backend.authorizationStatus()
        XCTAssertEqual(status, .authorized)
        let task = Task { try await backend.requestLocation() }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(fix.authorizationRequests, 0)
        XCTAssertEqual(fix.fixRequests, 0)
        fix.setAuthorization(.authorized)
        await fix.waitForFixStart()
        fix.emit(.success(Self.sample(14)))
        let result = try await task.value
        XCTAssertEqual(result.latitude, 14)
        XCTAssertEqual(fix.authorizationRequests, 0)
        XCTAssertEqual(fix.fixRequests, 1)
    }

    func testRetryManagerWaitsForInitialGrantButExpiredRequestCannotRestart() async throws {
        let passive = LocationAccessFake(authorization: .authorized)
        let first = LocationAccessFake(authorization: .authorized)
        let retry = LocationAccessFake(authorization: .notDetermined)
        let pool = LocationAccessPool([passive, first, retry])
        let controller = OneShotLocationController(fixTimeout: 0.02, factory: { pool.next() })
        _ = await controller.authorizationStatus()
        let task = Task { try await controller.requestLocation() }
        await first.waitForFixStart()
        first.emit(.failure(.resultUnverifiable))
        do { _ = try await task.value; XCTFail("Original deadline must end retry") }
        catch StableErrorCode.executionTimeout {}
        retry.setAuthorization(.authorized)
        try await Task.sleep(for: .milliseconds(320))
        XCTAssertEqual(retry.authorizationRequests, 0)
        XCTAssertEqual(retry.fixRequests, 0)
        XCTAssertGreaterThan(retry.stops, 0)
    }

    func testRetryManagerCanRestoreInitialGrantWithoutPrompt() async throws {
        let passive = LocationAccessFake(authorization: .authorized)
        let first = LocationAccessFake(authorization: .authorized)
        let retry = LocationAccessFake(authorization: .notDetermined)
        let pool = LocationAccessPool([passive, first, retry])
        let controller = OneShotLocationController(factory: { pool.next() })
        _ = await controller.authorizationStatus()
        let task = Task { try await controller.requestLocation() }
        await first.waitForFixStart()
        first.emit(.failure(.resultUnverifiable))
        try await Task.sleep(for: .milliseconds(20))
        retry.setAuthorization(.notDetermined) // Initial delegate callback is not a denial.
        retry.setAuthorization(.authorized)
        await retry.waitForFixStart()
        retry.emit(.success(Self.sample(15)))
        let result = try await task.value
        XCTAssertEqual(result.latitude, 15)
        XCTAssertEqual(retry.authorizationRequests, 0)
        XCTAssertEqual(retry.fixRequests, 1)
    }

    func testGrantRevokedAfterPassiveStatusDoesNotSampleOrPrompt() async throws {
        let initial = LocationAccessFake(authorization: .authorized)
        let pool = LocationAccessPool([initial])
        let controller = OneShotLocationController(factory: { pool.next() })
        let backend = CoreLocationBackend(isAppBundle: true, servicesEnabled: { true },
                                          driverFactory: { controller })
        let status = await backend.authorizationStatus()
        XCTAssertEqual(status, .authorized)
        initial.setAuthorization(.denied)
        do { _ = try await backend.requestLocation(); XCTFail("Revocation must prevent sampling") }
        catch StableErrorCode.permissionRequired {}
        XCTAssertEqual(initial.fixRequests, 0)
        XCTAssertEqual(initial.authorizationRequests, 0)
    }

    func testUnbundledAndServicesDisabledNeverCreateDriver() async throws {
        let manager = LocationAccessFake(authorization: .authorized)
        let pool = LocationAccessPool([manager])
        let controller = OneShotLocationController(factory: { pool.next() })
        let unbundled = CoreLocationBackend(isAppBundle: false, servicesEnabled: { XCTFail("Must not query system"); return true },
                                            driverFactory: { XCTFail("Must not create driver"); return controller })
        let state = await unbundled.authorizationStatus()
        XCTAssertEqual(state, .unavailable)
        do { _ = try await unbundled.requestAuthorization(); XCTFail("App required") }
        catch StableErrorCode.capabilityDisabled {}
        let disabled = CoreLocationBackend(isAppBundle: true, servicesEnabled: { false }, driverFactory: { controller })
        let denied = try await disabled.requestAuthorization()
        XCTAssertEqual(denied, .servicesDisabled)
        XCTAssertEqual(pool.creations, 0)
    }

    func testStatusSeesSystemServicesTurnedOffWithoutCreatingAnotherManager() async throws {
        let manager = LocationAccessFake(authorization: .authorized)
        let pool = LocationAccessPool([manager])
        let controller = OneShotLocationController(factory: { pool.next() })
        let services = LocationServiceToggle()
        let backend = CoreLocationBackend(isAppBundle: true, servicesEnabled: { services.enabled() }, driverFactory: { controller })
        _ = try await backend.requestAuthorization()
        services.setEnabled(false)
        let disabled = await backend.authorizationStatus()
        XCTAssertEqual(disabled, .servicesDisabled)
        XCTAssertEqual(pool.creations, 1)
        XCTAssertEqual(manager.fixRequests, 0)
        services.setEnabled(true)
        let authorized = await backend.authorizationStatus()
        XCTAssertEqual(authorized, .authorized)
        XCTAssertEqual(pool.creations, 1)
    }

    func testServicesDisabledDuringAcquisitionPreventsBackendDelivery() async throws {
        let authorization = LocationAccessFake(authorization: .authorized)
        let fix = LocationAccessFake(authorization: .authorized)
        let pool = LocationAccessPool([authorization, fix])
        let controller = OneShotLocationController(factory: { pool.next() })
        let services = LocationServiceToggle()
        let backend = CoreLocationBackend(isAppBundle: true, servicesEnabled: { services.enabled() }, driverFactory: { controller })
        _ = try await backend.requestAuthorization()
        let task = Task { try await backend.requestLocation() }
        await fix.waitForFixStart()
        services.setEnabled(false)
        fix.emit(.success(Self.sample(20)))
        do { _ = try await task.value; XCTFail("System revocation must prevent sample delivery") }
        catch StableErrorCode.permissionRequired {}
        let status = await backend.authorizationStatus()
        XCTAssertEqual(status, .servicesDisabled)
        XCTAssertGreaterThan(fix.stops, 0)
    }

    func testSuccessFailureAndRevocationStopOneShot() async throws {
        let authorization = LocationAccessFake(authorization: .authorized)
        let first = LocationAccessFake(authorization: .authorized)
        let second = LocationAccessFake(authorization: .authorized)
        let third = LocationAccessFake(authorization: .authorized)
        let pool = LocationAccessPool([authorization, first, second, third])
        let controller = OneShotLocationController(factory: { pool.next() })
        _ = try await controller.requestAuthorization()
        let success = Task { try await controller.requestLocation() }
        await first.waitForFixStart()
        first.emit(.success(Self.sample(12)))
        let value = try await success.value
        XCTAssertEqual(value.latitude, 12)
        XCTAssertGreaterThan(first.stops, 0)
        let failure = Task { try await controller.requestLocation() }
        await second.waitForFixStart()
        second.emit(.failure(.capabilityDisabled))
        do { _ = try await failure.value; XCTFail("Expected failure") } catch StableErrorCode.capabilityDisabled {}
        XCTAssertGreaterThan(second.stops, 0)
        let revoked = Task { try await controller.requestLocation() }
        await third.waitForFixStart()
        third.setAuthorization(.denied)
        third.emit(.success(Self.sample(90)))
        do { _ = try await revoked.value; XCTFail("Revocation must win") } catch StableErrorCode.permissionRequired {}
        XCTAssertGreaterThan(third.stops, 0)
    }

    func testTimeoutAndLateCallbackCannotSatisfyNewGeneration() async throws {
        let auth = LocationAccessFake(authorization: .authorized)
        let timedOut = LocationAccessFake(authorization: .authorized)
        let fresh = LocationAccessFake(authorization: .authorized)
        let pool = LocationAccessPool([auth, timedOut, fresh])
        let controller = OneShotLocationController(fixTimeout: 0.02, factory: { pool.next() })
        _ = try await controller.requestAuthorization()
        let first = Task { try await controller.requestLocation() }
        await timedOut.waitForFixStart()
        let oldCallback = try XCTUnwrap(timedOut.onLocation)
        do { _ = try await first.value; XCTFail("Expected timeout") } catch StableErrorCode.executionTimeout {}
        XCTAssertGreaterThan(timedOut.stops, 0)
        let next = Task { try await controller.requestLocation() }
        await fresh.waitForFixStart()
        oldCallback(.success(Self.sample(88)))
        fresh.emit(.success(Self.sample(13)))
        let value = try await next.value
        XCTAssertEqual(value.latitude, 13)
        fresh.emit(.success(Self.sample(80))) // Duplicate callback is ignored after completion.
    }

    func testStaleFirstSampleRetriesOnceAndDiscardsOldCallbacks() async throws {
        let auth = LocationAccessFake(authorization: .authorized)
        let stale = LocationAccessFake(authorization: .authorized)
        let fresh = LocationAccessFake(authorization: .authorized)
        let pool = LocationAccessPool([auth, stale, fresh])
        let controller = OneShotLocationController(factory: { pool.next() })
        _ = try await controller.requestAuthorization()
        let task = Task { try await controller.requestLocation() }
        await stale.waitForFixStart()
        let oldCallback = try XCTUnwrap(stale.onLocation)
        stale.emit(.success(.init(latitude: 12, longitude: 120, horizontalAccuracyMeters: 100,
                                  timestamp: Date().addingTimeInterval(-120))))
        await fresh.waitForFixStart()
        oldCallback(.success(Self.sample(88)))
        fresh.emit(.success(Self.sample(13)))
        let value = try await task.value
        XCTAssertEqual(value.latitude, 13)
        XCTAssertEqual(pool.creations, 3)
        XCTAssertGreaterThan(stale.stops, 0)
        XCTAssertGreaterThan(fresh.stops, 0)
    }

    func testTransientFailureRetriesWithinOriginalTimeoutButDenialDoesNot() async throws {
        let auth = LocationAccessFake(authorization: .authorized)
        let transient = LocationAccessFake(authorization: .authorized)
        let retry = LocationAccessFake(authorization: .authorized)
        let pool = LocationAccessPool([auth, transient, retry])
        let controller = OneShotLocationController(fixTimeout: 0.02, factory: { pool.next() })
        _ = try await controller.requestAuthorization()
        let task = Task { try await controller.requestLocation() }
        await transient.waitForFixStart()
        transient.emit(.failure(.resultUnverifiable))
        await retry.waitForFixStart()
        do { _ = try await task.value; XCTFail("Original deadline must end retry") }
        catch StableErrorCode.executionTimeout {}
        XCTAssertEqual(pool.creations, 3)
        XCTAssertGreaterThan(retry.stops, 0)

        let denied = LocationAccessFake(authorization: .authorized)
        let noRetry = LocationAccessPool([denied])
        let deniedController = OneShotLocationController(factory: { noRetry.next() })
        let deniedTask = Task { try await deniedController.requestLocation() }
        await denied.waitForFixStart()
        denied.emit(.failure(.permissionRequired))
        do { _ = try await deniedTask.value; XCTFail("Permission denial must finish immediately") }
        catch StableErrorCode.permissionRequired {}
        XCTAssertEqual(noRetry.creations, 1)
    }

    func testCancellationAndAuthorizationTimeoutAreCleanedUp() async throws {
        let pendingAuth = LocationAccessFake(authorization: .notDetermined)
        let authPool = LocationAccessPool([pendingAuth])
        let authController = OneShotLocationController(authorizationTimeout: 0.02, factory: { authPool.next() })
        do { _ = try await authController.requestAuthorization(); XCTFail("Expected auth timeout") }
        catch StableErrorCode.executionTimeout {}
        XCTAssertGreaterThan(pendingAuth.stops, 0)
        let cancelAuth = LocationAccessFake(authorization: .notDetermined)
        let cancelPool = LocationAccessPool([cancelAuth])
        let cancelController = OneShotLocationController(factory: { cancelPool.next() })
        let cancelledAuth = Task { try await cancelController.requestAuthorization() }
        await cancelAuth.waitForAuthorizationStart()
        cancelledAuth.cancel()
        do { _ = try await cancelledAuth.value; XCTFail("Expected authorization cancellation") } catch is CancellationError {}
        cancelAuth.setAuthorization(.authorized)
        XCTAssertEqual(cancelAuth.fixRequests, 0)
        XCTAssertGreaterThan(cancelAuth.stops, 0)
        let auth = LocationAccessFake(authorization: .authorized)
        let fix = LocationAccessFake(authorization: .authorized)
        let pool = LocationAccessPool([auth, fix])
        let controller = OneShotLocationController(factory: { pool.next() })
        _ = try await controller.requestAuthorization()
        let task = Task { try await controller.requestLocation() }
        await fix.waitForFixStart()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertGreaterThan(fix.stops, 0)
    }

    private static func sample(_ latitude: Double) -> LocationSample {
        .init(latitude: latitude, longitude: 120.123456, horizontalAccuracyMeters: 20, timestamp: Date())
    }
}

@MainActor
final class LocationAccessPool {
    private var managers: [LocationAccessFake]
    private(set) var creations = 0
    init(_ managers: [LocationAccessFake]) { self.managers = managers }
    func next() -> any LocationManagerAccess {
        creations += 1
        precondition(!managers.isEmpty, "Unexpected manager creation")
        return managers.removeFirst()
    }
}

@MainActor
final class LocationAccessFake: LocationManagerAccess {
    var authorization: LocationAuthorization
    var onAuthorization: (@MainActor @Sendable (LocationAuthorization) -> Void)?
    var onLocation: (@MainActor @Sendable (Result<LocationSample, StableErrorCode>) -> Void)?
    private(set) var authorizationRequests = 0
    private(set) var fixRequests = 0
    private(set) var stops = 0
    private var fixStarted: CheckedContinuation<Void, Never>?
    private var authStarted: CheckedContinuation<Void, Never>?
    init(authorization: LocationAuthorization) { self.authorization = authorization }
    func requestAuthorization() { authorizationRequests += 1; authStarted?.resume(); authStarted = nil }
    func requestOneShot() { fixRequests += 1; fixStarted?.resume(); fixStarted = nil }
    func stop() { stops += 1 }
    func waitForFixStart() async {
        if fixRequests > 0 { return }
        await withCheckedContinuation { fixStarted = $0 }
    }
    func waitForAuthorizationStart() async {
        if authorizationRequests > 0 { return }
        await withCheckedContinuation { authStarted = $0 }
    }
    func emit(_ result: Result<LocationSample, StableErrorCode>) { onLocation?(result) }
    func setAuthorization(_ value: LocationAuthorization) { authorization = value; onAuthorization?(value) }
}

private final class LocationServiceToggle: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    func enabled() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func setEnabled(_ value: Bool) { lock.lock(); defer { lock.unlock() }; self.value = value }
}
