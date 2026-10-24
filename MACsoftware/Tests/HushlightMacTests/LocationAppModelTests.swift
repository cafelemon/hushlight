import BridgeCore
import Foundation
import XCTest
@testable import HushlightMac

@MainActor
final class LocationAppModelTests: XCTestCase {
    func testPermissionCheckDoesNotSampleAndReadRefreshesHistory() async {
        let service = LocationModelFixture()
        let model = AppModel(bridgeService: service)
        await model.refresh()
        XCTAssertEqual(model.locationAuthorization, .notDetermined)
        XCTAssertNil(model.locationResult)

        await model.requestLocationPermission()
        XCTAssertEqual(model.locationAuthorization, .authorized)
        XCTAssertNil(model.locationResult)
        let readsBeforeSampling = await service.readCount
        XCTAssertEqual(readsBeforeSampling, 0)

        await model.readLocation()
        XCTAssertEqual(model.locationResult?.location?.latitude, 39.90)
        XCTAssertEqual(model.recentActions.count, 1)
        XCTAssertNil(model.locationError)
    }

    func testFailedReadClearsPreviousCoordinate() async {
        let service = LocationModelFixture(authorization: .authorized)
        let model = AppModel(bridgeService: service)
        await model.refresh()
        await model.readLocation()
        XCTAssertNotNil(model.locationResult?.location)

        await service.setReadFailure(true)
        await model.readLocation()
        XCTAssertNil(model.locationResult)
        XCTAssertTrue(model.locationError?.contains("result_unverifiable") == true)
    }

    func testBusyAndPausedOperationsDoNotReachService() async {
        let service = LocationModelFixture(authorization: .authorized, suspendRead: true)
        let model = AppModel(bridgeService: service)
        await model.refresh()
        let first = Task { await model.readLocation() }
        await service.waitForReadStart()
        await model.readLocation()
        await model.requestLocationPermission()
        let readsWhileBusy = await service.readCount
        let permissionsWhileBusy = await service.permissionCount
        XCTAssertEqual(readsWhileBusy, 1)
        XCTAssertEqual(permissionsWhileBusy, 0)
        await service.releaseRead()
        await first.value

        await model.togglePause()
        await model.readLocation()
        await model.requestLocationPermission()
        let readsWhilePaused = await service.readCount
        let permissionsWhilePaused = await service.permissionCount
        XCTAssertEqual(readsWhilePaused, 1)
        XCTAssertEqual(permissionsWhilePaused, 0)
    }

    func testRevocationAndSnapshotFailureClearCoordinate() async {
        let service = LocationModelFixture(authorization: .authorized)
        let model = AppModel(bridgeService: service)
        await model.refresh()
        await model.readLocation()
        await service.setAuthorization(.denied)
        await model.refresh()
        XCTAssertEqual(model.locationAuthorization, .denied)
        XCTAssertNil(model.locationResult)

        await service.setAuthorization(.authorized)
        await model.refresh()
        await model.readLocation()
        XCTAssertNotNil(model.locationResult)
        await service.setSnapshotFailure(true)
        await model.refresh()
        XCTAssertEqual(model.locationAuthorization, .notChecked)
        XCTAssertNil(model.locationResult)
    }

    func testForegroundPermissionRefreshClearsRevokedPositionAndWorksWhileBusy() async {
        let service = LocationModelFixture(authorization: .authorized)
        let model = AppModel(bridgeService: service)
        await model.refresh()
        await model.readLocation()
        await service.setAuthorization(.denied)
        await model.refreshLocationAuthorization()
        XCTAssertEqual(model.locationAuthorization, .denied)
        XCTAssertNil(model.locationResult)
        let reads = await service.readCount
        XCTAssertEqual(reads, 1)

        let suspended = LocationModelFixture(authorization: .authorized, suspendRead: true)
        let busyModel = AppModel(bridgeService: suspended)
        await busyModel.refresh()
        let pending = Task { await busyModel.readLocation() }
        await suspended.waitForReadStart()
        await suspended.setAuthorization(.servicesDisabled)
        await busyModel.refreshLocationAuthorization()
        XCTAssertEqual(busyModel.locationAuthorization, .servicesDisabled)
        await suspended.releaseRead()
        await pending.value
        XCTAssertNil(busyModel.locationResult)
    }

    func testClearingDisplayDoesNotChangeAuthorizationOrRequestLocation() async {
        let service = LocationModelFixture(authorization: .authorized)
        let model = AppModel(bridgeService: service)
        await model.refresh()
        await model.readLocation()
        model.clearLocation()
        XCTAssertNil(model.locationResult)
        XCTAssertEqual(model.locationAuthorization, .authorized)
        let readsAfterClearing = await service.readCount
        XCTAssertEqual(readsAfterClearing, 1)
    }
}

private actor LocationModelFixture: BridgeService {
    private var authorization: LocationAuthorization
    private var paused = false
    private var readFailure = false
    private var snapshotFailure = false
    private let suspendRead: Bool
    private var readContinuation: CheckedContinuation<Void, Never>?
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var readCount = 0
    private(set) var permissionCount = 0

    init(authorization: LocationAuthorization = .notDetermined, suspendRead: Bool = false) {
        self.authorization = authorization
        self.suspendRead = suspendRead
    }

    func snapshot() async throws -> BridgeSnapshot {
        if snapshotFailure { throw BridgeServiceError.notConfigured }
        let actions = (0..<readCount).map { _ in
            ActionRecord(name: "一次定位", outcome: .succeeded, occurredAt: Date())
        }
        return BridgeSnapshot(status: paused ? .paused : .localReady,
                              permissions: [], recentActions: actions,
                              locationAuthorization: authorization)
    }

    func setPaused(_ value: Bool) async throws { paused = value }
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
    func requestLocationPermission() async throws {
        permissionCount += 1
        authorization = .authorized
    }

    func readLocation() async throws -> LocalLocationCommandResult {
        readCount += 1
        readWaiters.forEach { $0.resume() }
        readWaiters.removeAll()
        if suspendRead { await withCheckedContinuation { readContinuation = $0 } }
        if readFailure {
            return LocalLocationCommandResult(status: "failed", stableError: "result_unverifiable",
                                              completedAt: Date())
        }
        let record = LocalLocationRecord(latitude: 39.90, longitude: 116.40,
                                         horizontalAccuracyMeters: 1_500, timestamp: Date())
        return LocalLocationCommandResult(status: "succeeded", stableError: nil,
                                          completedAt: Date(), location: record)
    }

    func setReadFailure(_ value: Bool) { readFailure = value }
    func setSnapshotFailure(_ value: Bool) { snapshotFailure = value }
    func setAuthorization(_ value: LocationAuthorization) { authorization = value }
    func waitForReadStart() async {
        if readCount > 0 { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }
    func releaseRead() { readContinuation?.resume(); readContinuation = nil }
}
