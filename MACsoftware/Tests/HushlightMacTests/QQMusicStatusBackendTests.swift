import Foundation
import XCTest
@testable import HushlightMac

final class QQMusicStatusBackendTests: XCTestCase {
    func testMissingRegistrationAndProcessReportsUnavailableMetadata() async throws {
        let status = try await backend(registeredID: nil, version: nil, runningIDs: []).status()
        XCTAssertEqual(status.bundleID, "com.tencent.QQMusicMac")
        XCTAssertFalse(status.installed)
        XCTAssertFalse(status.running)
        XCTAssertNil(status.version)
        XCTAssertEqual(status.playbackStatus, "unknown")
        XCTAssertFalse(status.controlsAvailable)
        XCTAssertLessThan(abs(status.checkedAt.timeIntervalSinceNow), 5)
    }

    func testMismatchedRegistrationCannotClaimInstallationOrVersion() async throws {
        let status = try await backend(registeredID: "com.example.Other", version: "2.3", runningIDs: []).status()
        XCTAssertFalse(status.installed)
        XCTAssertNil(status.version)
    }

    func testVerifiedRegistrationAndRunningProcessStayIndependent() async throws {
        let stopped = try await backend(registeredID: QQMusicStatus.qqMusicBundleID,
                                        version: " 9.1.0 ", runningIDs: []).status()
        XCTAssertTrue(stopped.installed)
        XCTAssertFalse(stopped.running)
        XCTAssertEqual(stopped.version, "9.1.0")

        let running = try await backend(registeredID: QQMusicStatus.qqMusicBundleID,
                                        version: "9.1.0",
                                        runningIDs: ["com.example.Other", QQMusicStatus.qqMusicBundleID]).status()
        XCTAssertTrue(running.installed)
        XCTAssertTrue(running.running)
        XCTAssertEqual(running.playbackStatus, "unknown")
        XCTAssertFalse(running.controlsAvailable)
    }

    func testRunningWithoutVerifiedRegistrationDoesNotInventInstallation() async throws {
        let status = try await backend(registeredID: nil, version: "9.1.0",
                                       runningIDs: [QQMusicStatus.qqMusicBundleID]).status()
        XCTAssertFalse(status.installed)
        XCTAssertTrue(status.running)
        XCTAssertNil(status.version)
    }

    func testMalformedVersionsAreOmitted() async throws {
        for value in ["", "   ", String(repeating: "1", count: 65), "1.0\nother"] {
            let status = try await backend(registeredID: QQMusicStatus.qqMusicBundleID,
                                           version: value, runningIDs: []).status()
            XCTAssertNil(status.version, "Unexpected version: \(value)")
        }
    }

    func testCodableKeepsReadinessConstants() async throws {
        let status = try await backend(registeredID: QQMusicStatus.qqMusicBundleID,
                                       version: "1.0", runningIDs: []).status()
        let encoded = try JSONEncoder().encode(status)
        XCTAssertEqual(try JSONDecoder().decode(QQMusicStatus.self, from: encoded), status)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["controlsAvailable"] = true
        let invalid = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(QQMusicStatus.self, from: invalid))
    }

    /// Run only with QQ_MUSIC_LIVE_STATUS_TEST=1; reads application/process metadata without launching QQ Music.
    func testOptionalLiveMetadataOnly() async throws {
        guard ProcessInfo.processInfo.environment["QQ_MUSIC_LIVE_STATUS_TEST"] == "1" else {
            throw XCTSkip("Set QQ_MUSIC_LIVE_STATUS_TEST=1 for the read-only live check")
        }
        let status = try await QQMusicStatusBackend().status()
        XCTAssertEqual(status.bundleID, QQMusicStatus.qqMusicBundleID)
        XCTAssertEqual(status.playbackStatus, "unknown")
        XCTAssertFalse(status.controlsAvailable)
        print("QQ Music metadata: installed=\(status.installed), running=\(status.running), version=\(status.version ?? "unknown")")
    }

    private func backend(registeredID: String?, version: String?, runningIDs: [String]) -> QQMusicStatusBackend {
        QQMusicStatusBackend(availability: FakeQQMusicAvailabilityProvider(
            value: QQMusicAvailability(registeredBundleID: registeredID,
                                       registeredVersion: version,
                                       runningBundleIDs: runningIDs)))
    }
}

private struct FakeQQMusicAvailabilityProvider: QQMusicAvailabilityProviding {
    let value: QQMusicAvailability

    @MainActor
    func snapshot(bundleID: String) -> QQMusicAvailability { value }
}
