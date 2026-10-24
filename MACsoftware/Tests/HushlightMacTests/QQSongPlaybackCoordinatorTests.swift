import XCTest
@testable import HushlightMac

private actor SongCoordinatorBackend: QQSongSearchPlaying {
    var calls = 0
    var unknown = false
    let activeURL: URL
    var observedWriteAhead = false
    init(_ directory: URL) { activeURL = directory.appendingPathComponent("active.json") }
    func setUnknown(_ value: Bool) { unknown = value }
    func play(_ request: QQSongRequest, authorize: @escaping @Sendable () async -> Bool,
              beforePlay: @escaping @Sendable () async throws -> Void) async throws -> QQMusicPlayback {
        try await beforePlay()
        guard await authorize() else { throw QQSongSearchError.unauthorized }
        observedWriteAhead = FileManager.default.fileExists(atPath: activeURL.path)
        calls += 1
        if unknown { throw QQSongSearchError.unknownOutcome }
        return .init(playing: true, track: request.title + " - " + (request.artist ?? "Synthetic"), checkedAt: Date())
    }
}
final class QQSongPlaybackCoordinatorTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("SongCoordinator-\(UUID().uuidString)") }
    private let song = QQSongRequest(title: "Synthetic Song", artist: "Synthetic Artist")

    func testDurableSuccessIsNotReplayedAndDigestAndCallerAreBound() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let backend = SongCoordinatorBackend(dir), id = UUID().uuidString
        let core = try QQSongPlaybackCoordinator(directory: dir, backend: backend)
        let first = await core.play(id: id, caller: "a", request: song, authorize: { true })
        XCTAssertEqual(first.status, "succeeded")
        let ahead = await backend.observedWriteAhead; XCTAssertTrue(ahead)
        let repeatResult = await core.play(id: id, caller: "a", request: song, authorize: { true })
        XCTAssertEqual(repeatResult.status, "succeeded")
        let conflict = await core.play(id: id, caller: "a", request: .init(title: "Other", artist: "Synthetic"), authorize: { true })
        XCTAssertEqual(conflict.error, "request_id_conflict")
        await core.close()
        let restored = try QQSongPlaybackCoordinator(directory: dir, backend: backend)
        let replay = await restored.play(id: id, caller: "a", request: song, authorize: { true })
        XCTAssertEqual(replay.status, "succeeded")
        let otherCaller = await restored.play(id: id, caller: "b", request: song, authorize: { true })
        XCTAssertEqual(otherCaller.status, "succeeded")
        let calls = await backend.calls; XCTAssertEqual(calls, 2)
        await restored.close()
        for path in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where path.pathExtension == "json" {
            let text = try String(contentsOf: path, encoding: .utf8)
            XCTAssertFalse(text.contains(song.title)); XCTAssertFalse(text.contains(song.artist!))
            let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
        }
    }
    func testUnknownSurvivesRestartBlocksNewRequestsAndAcknowledgmentDoesNotReplay() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let backend = SongCoordinatorBackend(dir), id = UUID().uuidString
        await backend.setUnknown(true)
        let core = try QQSongPlaybackCoordinator(directory: dir, backend: backend)
        let first = await core.play(id: id, caller: "a", request: song, authorize: { true })
        XCTAssertEqual(first.status, "unknown")
        await core.close()
        let restored = try QQSongPlaybackCoordinator(directory: dir, backend: backend)
        let replay = await restored.play(id: id, caller: "a", request: song, authorize: { true })
        XCTAssertEqual(replay.status, "unknown")
        let blocked = await restored.play(id: UUID().uuidString, caller: "b", request: song, authorize: { true })
        XCTAssertEqual(blocked.error, "unresolved_playback_requires_review")
        let pendingValue = await restored.pending(); let pending = try XCTUnwrap(pendingValue)
        try await restored.acknowledge(pending)
        let old = await restored.play(id: id, caller: "a", request: song, authorize: { true })
        XCTAssertEqual(old.status, "unknown")
        await backend.setUnknown(false)
        let next = await restored.play(id: UUID().uuidString, caller: "a", request: song, authorize: { true })
        XCTAssertEqual(next.status, "succeeded")
        let calls = await backend.calls; XCTAssertEqual(calls, 2)
        await restored.close()
    }
    func testDeniedRequestNeverReachesBackendOrAdmitsPlayback() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let backend = SongCoordinatorBackend(dir)
        let core = try QQSongPlaybackCoordinator(directory: dir, backend: backend)
        let result = await core.play(id: UUID().uuidString, caller: "a", request: song, authorize: { false })
        XCTAssertEqual(result.status, "failed")
        let calls = await backend.calls; XCTAssertEqual(calls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("active.json").path))
        await core.close()
    }
    func testExclusiveRuntimeAndCorruptActiveReceiptFailClosed() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let backend = SongCoordinatorBackend(dir)
        let core = try QQSongPlaybackCoordinator(directory: dir, backend: backend)
        XCTAssertThrowsError(try QQSongPlaybackCoordinator(directory: dir, backend: backend))
        await core.close()
        try Data("invalid".utf8).write(to: dir.appendingPathComponent("active.json"))
        let restored = try QQSongPlaybackCoordinator(directory: dir, backend: backend)
        let result = await restored.play(id: UUID().uuidString, caller: "a", request: song, authorize: { true })
        XCTAssertEqual(result.error, "playback_storage_unavailable")
        let calls = await backend.calls; XCTAssertEqual(calls, 0)
        await restored.close()
    }
}
