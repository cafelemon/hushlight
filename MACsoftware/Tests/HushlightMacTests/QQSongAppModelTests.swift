import BridgeCore
import XCTest
@testable import HushlightMac

private actor SongModelBridge: BridgeService {
    var paused = false
    var calls = 0
    var started = false
    var waiter: CheckedContinuation<Void, Never>?
    var release: CheckedContinuation<Void, Never>?
    var pending: QQSongPending?
    func snapshot() async throws -> BridgeSnapshot { .init(status: paused ? .paused : .localReady, permissions: [], recentActions: []) }
    func setPaused(_ value: Bool) async throws { paused = value }
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
    func waitForStart() async { if started { return }; await withCheckedContinuation { waiter = $0 } }
    func finish() { release?.resume(); release = nil }
    func searchAndPlayQQMusic(id: String, request: QQSongRequest, authorize: @escaping @Sendable () async -> Bool) async throws -> QQSongPlayResult {
        calls += 1; started = true; waiter?.resume(); waiter = nil
        await withCheckedContinuation { release = $0 }
        guard await authorize(), !paused else { return .init(requestID: id, status: "failed", error: "authorization_changed", playback: nil) }
        pending = .init(requestID: id, callerID: "local_ui")
        return .init(requestID: id, status: "unknown", error: "result_unverifiable", playback: nil)
    }
    func pendingQQSong() async throws -> QQSongPending? { pending }
    func acknowledgeQQSong(_ value: QQSongPending) async throws { if pending == value { pending = nil } }
}

@MainActor
final class QQSongAppModelTests: XCTestCase {
    func testDuplicateClickAndUnknownBlockUntilExplicitReviewWhilePageDraftSurvives() async throws {
        let bridge = SongModelBridge(), model = AppModel(bridgeService: bridge)
        await model.refresh()
        model.songTitle = "Synthetic Song"; model.songArtist = "Synthetic Artist"
        let request = QQSongRequest(title: model.songTitle, artist: model.songArtist)
        let first = Task { await model.searchAndPlayQQSong(request) }
        await bridge.waitForStart()
        await model.searchAndPlayQQSong(request)
        model.selectPage(.overview); model.selectPage(.music)
        XCTAssertEqual(model.songTitle, "Synthetic Song")
        await bridge.finish(); await first.value
        XCTAssertEqual(model.songPlayResult?.status, "unknown")
        XCTAssertNotNil(model.songPending)
        await model.searchAndPlayQQSong(request)
        let calls = await bridge.calls; XCTAssertEqual(calls, 1)
        await model.acknowledgeQQSong()
        XCTAssertNil(model.songPending)
        XCTAssertEqual(model.songPlayResult?.status, "unknown")
    }
    func testPauseWhileSearchInFlightRefusesFinalAdmission() async throws {
        let bridge = SongModelBridge(), model = AppModel(bridgeService: bridge)
        await model.refresh()
        let first = Task { await model.searchAndPlayQQSong(.init(title: "Synthetic", artist: nil)) }
        await bridge.waitForStart()
        await model.togglePause()
        await bridge.finish(); await first.value
        XCTAssertEqual(model.songPlayResult?.status, "failed")
        XCTAssertTrue(model.isPaused)
        XCTAssertNil(model.songPending)
    }
}
