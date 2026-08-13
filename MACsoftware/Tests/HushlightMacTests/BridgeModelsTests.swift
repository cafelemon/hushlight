import XCTest
@testable import HushlightMac

final class BridgeModelsTests: XCTestCase {
    func testPlaceholderStartsNotConfiguredWithNoPermissionsOrActions() async throws {
        let service = PlaceholderBridgeService()

        let snapshot = try await service.snapshot()

        XCTAssertEqual(snapshot.status, .notConfigured)
        XCTAssertEqual(snapshot.permissions.count, PermissionKind.allCases.count)
        XCTAssertTrue(snapshot.permissions.allSatisfy { $0.state == .notRequested })
        XCTAssertTrue(snapshot.recentActions.isEmpty)
    }

    func testPauseStateRoundTripsThroughService() async throws {
        let service = PlaceholderBridgeService()

        try await service.setPaused(true)
        let pausedSnapshot = try await service.snapshot()

        XCTAssertEqual(pausedSnapshot.status, .paused)

        try await service.setPaused(false)
        let resumedSnapshot = try await service.snapshot()

        XCTAssertEqual(resumedSnapshot.status, .notConfigured)
    }
}
