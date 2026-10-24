import Foundation
import XCTest
@testable import HushlightMac

@MainActor
final class QQMusicPlaybackBackendTests: XCTestCase {
    func testAXSearchPolicyAcceptsExactPlaybackLabelOnGroupAndPanel() {
        for role in ["AXGroup", "AXPanel"] {
            XCTAssertTrue(QQMusicAXSearchPolicy.isPlaybackBar(role: role, identifier: nil,
                                                               title: nil, description: "播放控制栏",
                                                               roleDescription: nil))
            XCTAssertTrue(QQMusicAXSearchPolicy.isPlaybackBar(role: role, identifier: "播放控制栏",
                                                               title: nil, description: nil,
                                                               roleDescription: nil))
            XCTAssertFalse(QQMusicAXSearchPolicy.isPlaybackBar(role: role, identifier: nil,
                                                                title: "播放控制栏副本", description: nil,
                                                                roleDescription: nil))
        }
        XCTAssertFalse(QQMusicAXSearchPolicy.isPlaybackBar(role: "AXStaticText", identifier: nil,
                                                            title: "播放控制栏", description: nil,
                                                            roleDescription: nil))
    }

    func testAXSearchPolicyDoesNotReadLabelsOrDescendThroughNonContainers() {
        for role in ["AXStaticText", "AXTextField", "AXButton", "AXScrollArea"] {
            XCTAssertFalse(QQMusicAXSearchPolicy.mayInspectLabels(role: role))
            XCTAssertFalse(QQMusicAXSearchPolicy.mayDescend(role: role))
        }
        XCTAssertTrue(QQMusicAXSearchPolicy.mayDescend(role: "AXWindow"))
        XCTAssertFalse(QQMusicAXSearchPolicy.mayInspectLabels(role: "AXWindow"))
        XCTAssertTrue(QQMusicAXSearchPolicy.excludesSubtree(role: "AXGroup", identifier: nil,
                                                             title: "个人中心", description: nil,
                                                             roleDescription: nil))
    }

    func testObservedPausePlaybackAliasReadsAndPausesUsingExactControl() async throws {
        let surface = FakeQQMusicAXSurface()
        let actual = QQMusicAXSnapshot(regions: [Self.region(buttons: [Self.button("上一首"), Self.button("暂停播放"), Self.button("下一首")])])
        surface.snapshots = [actual]
        let backend = QQMusicPlaybackBackend(surface: surface)
        let read = try await backend.read()
        XCTAssertTrue(read.playing)
        surface.snapshots = [actual, actual, Self.snapshot(playing: false, track: "A - B")]
        let after = try await backend.perform(.pause, authorize: { true })
        XCTAssertFalse(after.playing)
        XCTAssertEqual(surface.pressed, ["暂停播放"])
    }

    func testDuplicatePauseAliasesAreAmbiguousAndNeverPressed() async throws {
        let surface = FakeQQMusicAXSurface()
        surface.snapshots = [.init(regions: [Self.region(buttons: [Self.button("暂停"), Self.button("暂停播放")])])]
        await assertError(.unverifiable) { _ = try await QQMusicPlaybackBackend(surface: surface).read() }
        XCTAssertTrue(surface.pressed.isEmpty)
    }

    func testReadRequiresTrustAndRunningProcess() async throws {
        let surface = FakeQQMusicAXSurface()
        let backend = QQMusicPlaybackBackend(surface: surface)
        surface.trusted = false
        await assertError(.permissionRequired) { _ = try await backend.read() }
        surface.trusted = true
        surface.running = false
        await assertError(.notRunning) { _ = try await backend.read() }
        XCTAssertEqual(surface.snapshotCalls, 0)
    }

    func testAmbiguousRegionsOrButtonsFailClosed() async throws {
        let surface = FakeQQMusicAXSurface()
        let backend = QQMusicPlaybackBackend(surface: surface)
        surface.snapshots = [.init(regions: [Self.region(), Self.region()])]
        await assertError(.unverifiable) { _ = try await backend.read() }
        surface.snapshots = [.init(regions: [Self.region(buttons: [Self.button("播放"), Self.button("暂停")])])]
        await assertError(.unverifiable) { _ = try await backend.read() }
        XCTAssertEqual(surface.pressed, [])
    }

    func testReadParsesOnlyUniqueSong() async throws {
        let surface = FakeQQMusicAXSurface()
        surface.snapshots = [Self.snapshot(playing: false, track: "Read All About - Catalisdh Heathsak")]
        let playback = try await QQMusicPlaybackBackend(surface: surface).read()
        XCTAssertFalse(playback.playing)
        XCTAssertEqual(playback.track, "Read All About - Catalisdh Heathsak")
        XCTAssertLessThan(abs(playback.checkedAt.timeIntervalSinceNow), 5)
        XCTAssertEqual(try JSONDecoder().decode(QQMusicPlayback.self, from: JSONEncoder().encode(playback)), playback)
    }

    func testSkipWithNoSongDoesNotAuthorizeOrPress() async throws {
        let surface = FakeQQMusicAXSurface()
        surface.snapshots = [Self.snapshot(playing: false, track: nil)]
        let backend = QQMusicPlaybackBackend(surface: surface)
        let authorization = AuthorizationProbe()
        await assertError(.unverifiable) {
            _ = try await backend.perform(.next, authorize: { await authorization.call() })
        }
        let calls = await authorization.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(surface.pressed, [])
    }

    func testPlayAndPauseAreIdempotent() async throws {
        let surface = FakeQQMusicAXSurface()
        let backend = QQMusicPlaybackBackend(surface: surface)
        let authorization = AuthorizationProbe()
        surface.snapshots = [Self.snapshot(playing: true, track: "A - B")]
        let played = try await backend.perform(.play, authorize: { await authorization.call() })
        XCTAssertTrue(played.playing)
        surface.snapshots = [Self.snapshot(playing: false, track: "A - B")]
        let paused = try await backend.perform(.pause, authorize: { await authorization.call() })
        XCTAssertFalse(paused.playing)
        let calls = await authorization.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(surface.pressed, [])
    }

    func testAuthorizationRevokedBeforePress() async throws {
        let surface = FakeQQMusicAXSurface()
        surface.snapshots = [Self.snapshot(playing: false, track: "A - B")]
        let backend = QQMusicPlaybackBackend(surface: surface)
        await assertError(.permissionRequired) {
            _ = try await backend.perform(.play, authorize: {
                await MainActor.run { surface.trusted = false }
                return true
            })
        }
        XCTAssertEqual(surface.pressed, [])
    }

    func testSecondAuthorizationRevokedAfterAXScanNeverPresses() async throws {
        let surface = FakeQQMusicAXSurface()
        surface.snapshots = [Self.snapshot(playing: false, track: "A - B")]
        let backend = QQMusicPlaybackBackend(surface: surface)
        let authorization = AuthorizationProbe()
        await assertError(.permissionRequired) {
            _ = try await backend.perform(.play, authorize: {
                let call = await authorization.nextCall()
                if call == 2 { await MainActor.run { surface.trusted = false } }
                return true
            })
        }
        let calls = await authorization.calls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(surface.snapshotCalls, 2)
        XCTAssertEqual(surface.pressed, [])
    }

    func testDeniedAuthorizationNeverPresses() async throws {
        let surface = FakeQQMusicAXSurface()
        surface.snapshots = [Self.snapshot(playing: false, track: "A - B")]
        let backend = QQMusicPlaybackBackend(surface: surface)
        await assertError(.permissionRequired) { _ = try await backend.perform(.play, authorize: { false }) }
        XCTAssertEqual(surface.pressed, [])
    }

    func testPlayPressesOnceAndVerifiesPauseButton() async throws {
        let surface = FakeQQMusicAXSurface()
        surface.snapshots = [Self.snapshot(playing: false, track: "A - B"),
                             Self.snapshot(playing: false, track: "A - B"),
                             Self.snapshot(playing: true, track: "A - B")]
        let playback = try await QQMusicPlaybackBackend(surface: surface).perform(.play, authorize: { true })
        XCTAssertTrue(playback.playing)
        XCTAssertEqual(surface.pressed, ["播放"])
    }

    func testPressErrorBecomesUnknownAndIsNotRetried() async throws {
        let surface = FakeQQMusicAXSurface()
        surface.snapshots = [Self.snapshot(playing: false, track: "A - B")]
        surface.pressError = QQMusicPlaybackError.unverifiable
        let backend = QQMusicPlaybackBackend(surface: surface)
        await assertError(.unknownOutcome) { _ = try await backend.perform(.play, authorize: { true }) }
        XCTAssertEqual(surface.pressed, ["播放"])
    }

    func testStaleButtonBeforePressIsExplicitlyUnverifiable() async throws {
        let surface = FakeQQMusicAXSurface()
        surface.snapshots = [Self.snapshot(playing: false, track: "A - B")]
        surface.pressError = QQMusicAXPreflightError.staleButton
        let backend = QQMusicPlaybackBackend(surface: surface)
        await assertError(.unverifiable) { _ = try await backend.perform(.play, authorize: { true }) }
        XCTAssertEqual(surface.pressed, [])
    }

    func testCancellationAfterPressReturnsUnknownPromptly() async throws {
        let surface = FakeQQMusicAXSurface()
        surface.snapshots = [Self.snapshot(playing: false, track: "A - B")]
        surface.cancelCurrentTaskOnPress = true
        let backend = QQMusicPlaybackBackend(surface: surface)
        let started = Date()
        await assertError(.unknownOutcome) { _ = try await backend.perform(.play, authorize: { true }) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(surface.pressed, ["播放"])
    }

    func testNextRequiresChangedTrack() async throws {
        let surface = FakeQQMusicAXSurface()
        surface.snapshots = [Self.snapshot(playing: true, track: "A - B"),
                             Self.snapshot(playing: true, track: "A - B"),
                             Self.snapshot(playing: true, track: "C - D")]
        let playback = try await QQMusicPlaybackBackend(surface: surface).perform(.next, authorize: { true })
        XCTAssertEqual(playback.track, "C - D")
        XCTAssertEqual(surface.pressed, ["下一首"])
    }

    func testSameTrackAfterPreviousIsUnknown() async throws {
        let surface = FakeQQMusicAXSurface()
        surface.snapshots = [Self.snapshot(playing: true, track: "A - B")]
        let backend = QQMusicPlaybackBackend(surface: surface)
        await assertError(.unknownOutcome) { _ = try await backend.perform(.previous, authorize: { true }) }
        XCTAssertEqual(surface.pressed, ["上一首"])
    }

    func testCancellationBeforeAuthorizationNeverPresses() async throws {
        let surface = FakeQQMusicAXSurface()
        surface.snapshots = [Self.snapshot(playing: false, track: "A - B")]
        let backend = QQMusicPlaybackBackend(surface: surface)
        let task = Task {
            _ = try await backend.perform(.play, authorize: {
                try? await Task.sleep(for: .milliseconds(100))
                return true
            })
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(surface.pressed, [])
        }
    }

    private func assertError(_ expected: QQMusicPlaybackError,
                             _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected \(expected)") }
        catch let error as QQMusicPlaybackError { XCTAssertEqual(error, expected) }
        catch { XCTFail("Unexpected \(error)") }
    }

    private static func button(_ title: String) -> QQMusicAXButton { .init(key: title, title: title) }

    private static func region(buttons: [QQMusicAXButton] = [button("上一首"), button("播放"), button("下一首")],
                               track: String? = "A - B") -> QQMusicAXRegion {
        let texts = track.map { ["歌曲名：\($0.replacingOccurrences(of: " - ", with: " - 歌手名："))"] } ?? []
        return .init(buttons: buttons, songTexts: texts)
    }

    private static func snapshot(playing: Bool, track: String?) -> QQMusicAXSnapshot {
        .init(regions: [region(buttons: [button("上一首"), button(playing ? "暂停" : "播放"), button("下一首")], track: track)])
    }
}

@MainActor
private final class FakeQQMusicAXSurface: QQMusicAXSurface {
    var trusted = true
    var running = true
    var snapshots: [QQMusicAXSnapshot] = []
    var snapshotCalls = 0
    var pressed: [String] = []
    var pressError: Error?
    var cancelCurrentTaskOnPress = false

    func isTrusted() -> Bool { trusted }
    func isRunning() -> Bool { running }
    func snapshot() throws -> QQMusicAXSnapshot {
        snapshotCalls += 1
        guard let first = snapshots.first else { throw QQMusicPlaybackError.unverifiable }
        if snapshots.count > 1 { snapshots.removeFirst() }
        return first
    }
    func press(buttonKey: String, expectedTitle: String) throws {
        if pressError is QQMusicAXPreflightError { throw pressError! }
        pressed.append(buttonKey)
        if cancelCurrentTaskOnPress { withUnsafeCurrentTask { $0?.cancel() } }
        if let pressError { throw pressError }
    }
}

private actor AuthorizationProbe {
    var calls = 0
    func call() -> Bool { calls += 1; return true }
    func nextCall() -> Int { calls += 1; return calls }
}
