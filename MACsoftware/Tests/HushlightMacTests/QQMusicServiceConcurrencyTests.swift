import BridgeCore
import XCTest
@testable import HushlightMac

private actor HeldMusicBackend: QQMusicPlaybackProviding {
    var calls = 0
    var started = false
    var startWaiter: CheckedContinuation<Void, Never>?
    var finishWaiter: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func finish() { finishWaiter?.resume(); finishWaiter = nil }
    func read() async throws -> QQMusicPlayback { .init(playing: false, track: nil, checkedAt: Date()) }
    func perform(_ action: QQMusicPlaybackAction, authorize: @escaping @Sendable () async -> Bool) async throws -> QQMusicPlayback {
        guard await authorize() else { throw QQMusicPlaybackError.permissionRequired }
        calls += 1
        if calls == 1 {
            started = true; startWaiter?.resume(); startWaiter = nil
            await withCheckedContinuation { finishWaiter = $0 }
        }
        return .init(playing: true, track: "Synthetic", checkedAt: Date())
    }
    func count() -> Int { calls }
}

private actor HeldFinalSongGrant {
    private var calls = 0
    private var held = false
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func authorize() async -> Bool {
        calls += 1
        if calls == 3 {
            held = true
            heldWaiter?.resume(); heldWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        return true // Deliberately stale grant; service must recheck pause after this returns.
    }
    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { heldWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

private actor SongFinalGrantBackend: QQSongSearchPlaying {
    private var clicks = 0
    func clickCount() -> Int { clicks }
    func play(_ request: QQSongRequest, authorize: @escaping @Sendable () async -> Bool,
              beforePlay: @escaping @Sendable () async throws -> Void) async throws -> QQMusicPlayback {
        try await beforePlay()
        guard await authorize() else { throw QQSongSearchError.unauthorized }
        clicks += 1
        return .init(playing: true, track: request.title + " - " + (request.artist ?? "Synthetic"), checkedAt: Date())
    }
}

final class QQMusicServiceConcurrencyTests: XCTestCase {
    func testSharedServiceRejectsOverlappingControlsAndReleasesSlot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("music-service-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "music-test.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = HeldMusicBackend()
        let service = LocalBridgeService(preferences: UserDefaultsPausePreferenceStore(defaults: defaults),
            timerStorageURL: directory.appendingPathComponent("timers.json"),
            notesStorageURL: directory.appendingPathComponent("notes.json"),
            mailDraftStorageURL: directory.appendingPathComponent("drafts.json"), qqMusicPlaybackBackend: backend,
            runtimeFactory: { paused, _, _, _, _, _ in try await BridgeLocalRuntime(simulate: true, paused: paused) })
        let first = Task { try await service.performQQMusic(.play, authorize: { true }) }
        await backend.waitUntilStarted()
        do { _ = try await service.performQQMusic(.next, authorize: { true }); XCTFail("Control slot is already held") }
        catch StableErrorCode.capabilityDisabled {}
        let during = await backend.count()
        XCTAssertEqual(during, 1)
        await backend.finish()
        _ = try await first.value
        _ = try await service.performQQMusic(.pause, authorize: { true })
        let final = await backend.count()
        XCTAssertEqual(final, 2)
    }

    func testPauseDuringFinalGrantRevokesSongClickAndSharedWriteSlot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("music-song-pause-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "music-song-pause.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let song = SongFinalGrantBackend(), playback = HeldMusicBackend(), grant = HeldFinalSongGrant()
        let service = LocalBridgeService(preferences: UserDefaultsPausePreferenceStore(defaults: defaults),
            timerStorageURL: directory.appendingPathComponent("timers.json"),
            notesStorageURL: directory.appendingPathComponent("notes.json"),
            mailDraftStorageURL: directory.appendingPathComponent("drafts.json"),
            qqMusicPlaybackBackend: playback, qqSongSearchBackend: song,
            qqSongStorageURL: directory.appendingPathComponent("song"),
            runtimeFactory: { paused, _, _, _, _, _ in try await BridgeLocalRuntime(simulate: true, paused: paused) })
        let request = QQSongRequest(title: "Synthetic Song", artist: "Synthetic Artist")
        let operation = Task { try await service.searchAndPlayQQMusic(id: UUID().uuidString, request: request,
                                                                       authorize: { await grant.authorize() }) }
        await grant.waitUntilHeld()
        do {
            _ = try await service.performQQMusic(.play, authorize: { true })
            XCTFail("Song playback must hold the shared write slot")
        } catch StableErrorCode.capabilityDisabled { }
        try await service.setPaused(true)
        await grant.release()
        let result = try await operation.value
        XCTAssertEqual(result.status, "failed")
        XCTAssertEqual(result.error, "authorization_changed")
        let clicks = await song.clickCount()
        XCTAssertEqual(clicks, 0)
        let otherControls = await playback.count()
        XCTAssertEqual(otherControls, 0)
    }
}
