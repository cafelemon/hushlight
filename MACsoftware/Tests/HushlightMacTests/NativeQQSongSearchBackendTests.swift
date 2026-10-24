import CoreGraphics
import Foundation
import XCTest
@testable import HushlightMac

private actor SongTestAuthorization {
    var allowed = true
    var admissions = 0
    func grant() -> Bool { allowed }
    func revoke() { allowed = false }
    func admit() { admissions += 1 }
    func admissionCount() -> Int { admissions }
}

@MainActor
private final class SongTestSurface: QQSongNativeSurface {
    var current: QQSongNativeWindow
    var trusted = true
    var running = true
    var foreground = true
    var moveAfterSearch = false
    var loseFocusAfterSearch = false
    var failAfterClick = false
    var searches = 0
    var clicks = 0
    var queries = [String]()
    var preparations = 0

    init(_ window: QQSongNativeWindow) { current = window }

    func prepare(authorize: @escaping @Sendable () async -> Bool) async throws {
        guard await authorize() else { throw QQSongSearchError.unauthorized }
        preparations += 1
        foreground = true
    }

    func inspectWindow() throws -> QQSongNativeWindow {
        guard trusted else { throw QQSongSearchError.permissionRequired }
        guard running else { throw QQSongSearchError.notRunning }
        guard foreground else { throw QQSongSearchError.unavailableWindow }
        return current
    }

    func submitSearch(_ query: String, in window: QQSongNativeWindow,
                      authorize: @escaping @Sendable () async -> Bool) async throws {
        guard await authorize() else { throw QQSongSearchError.unauthorized }
        guard try inspectWindow() == window else { throw QQSongSearchError.unavailableWindow }
        searches += 1
        queries.append(query)
        if moveAfterSearch {
            current = QQSongNativeWindow(window: .init(id: window.window.id, pid: 999,
                                                       target: .qqMusic, width: 800, height: 600),
                                         frame: window.frame)
        }
        if loseFocusAfterSearch { foreground = false }
    }

    func doubleClick(_ region: CGRect, in window: QQSongNativeWindow,
                     authorize: @escaping @Sendable () async -> Bool) async throws {
        guard await authorize() else { throw QQSongSearchError.unauthorized }
        guard try inspectWindow() == window else { throw QQSongSearchError.unavailableWindow }
        clicks += 1
        if failAfterClick { throw QQSongSearchError.unknownOutcome }
    }
}

private actor SongTestVision: WindowVisionProviding {
    var permitted = true
    var captures = 0
    var recognitions = 0
    var loadingSamples = 0
    var ambiguousSamples = 0
    func permissionGranted() -> Bool { permitted }
    func requestPermission() -> Bool { permitted }
    func listWindows(target: WindowVisionTarget) -> [WindowVisionWindow] { [] }
    func setPermitted(_ value: Bool) { permitted = value }
    func setLoadingSamples(_ count: Int) { loadingSamples = count }
    func setAmbiguousSamples(_ count: Int) { ambiguousSamples = count }
    func capturePreview(window: WindowVisionWindow) -> WindowVisionPreview {
        captures += 1
        let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return WindowVisionPreview(window: window, checkedAt: Date(), image: context.makeImage()!)
    }
    func recognize(preview: WindowVisionPreview, region: CGRect) -> WindowVisionResult {
        recognitions += 1
        var lines: [WindowVisionLine] = recognitions <= loadingSamples ? [] : [
            .init(text: "晴天 周杰伦", confidence: 0.99,
                  rect: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.1), region: "full")]
        if recognitions <= ambiguousSamples {
            lines.append(.init(text: "晴天 周杰伦", confidence: 0.99,
                               rect: CGRect(x: 0.1, y: 0.4, width: 0.4, height: 0.1), region: "full"))
        }
        return WindowVisionResult(window: preview.window, checkedAt: preview.checkedAt,
                                  lines: lines)
    }
}

private struct SongTestSelector: QQSongSelecting {
    func choose(_ request: QQSongRequest, lines: [WindowVisionLine]) throws -> QQSongCandidate {
        if lines.isEmpty { throw QQSongSearchError.notFound }
        guard lines.count == 1 else { throw QQSongSearchError.ambiguous }
        return QQSongCandidate(title: "晴天", artist: "周杰伦", region: lines[0].rect)
    }
}

@MainActor
private final class SongTestPlayback: QQMusicPlaybackProviding {
    let surface: SongTestSurface
    var wrongFirst = false
    var unreadable = false
    var trackOverride: String?
    var scriptedTracks: [String?] = []
    var reads = 0
    init(surface: SongTestSurface) { self.surface = surface }
    func read() async throws -> QQMusicPlayback {
        reads += 1
        if !scriptedTracks.isEmpty {
            guard let track = scriptedTracks.removeFirst() else { throw QQMusicPlaybackError.unverifiable }
            return QQMusicPlayback(playing: true, track: track, checkedAt: Date())
        }
        if unreadable { throw QQMusicPlaybackError.unverifiable }
        let track = trackOverride ?? (wrongFirst && surface.clicks == 1 ? "别的歌 - 别的歌手" : "晴天 - 周杰伦")
        return QQMusicPlayback(playing: true, track: track, checkedAt: Date())
    }
    func perform(_ action: QQMusicPlaybackAction,
                 authorize: @escaping @Sendable () async -> Bool) async throws -> QQMusicPlayback {
        throw QQMusicPlaybackError.unverifiable
    }
}

@MainActor
final class NativeQQSongSearchBackendTests: XCTestCase {
    private let nativeWindow = QQSongNativeWindow(
        window: .init(id: 41, pid: 101, target: .qqMusic, width: 800, height: 600),
        frame: CGRect(x: 100, y: 200, width: 800, height: 600))
    private let request = QQSongRequest(title: "晴天", artist: "周杰伦")

    func testSearchFieldAndSongPointMustStayInsideVerifiedWindow() {
        let window = nativeWindow.frame
        XCTAssertTrue(QQSongGeometryPolicy.contains(CGRect(x: 120, y: 220, width: 100, height: 30), in: window))
        XCTAssertFalse(QQSongGeometryPolicy.contains(CGRect(x: 80, y: 220, width: 100, height: 30), in: window))
        XCTAssertFalse(QQSongGeometryPolicy.contains(CGRect(x: CGFloat.infinity, y: 220, width: 100, height: 30), in: window))
        XCTAssertFalse(QQSongGeometryPolicy.contains(CGRect(x: 120, y: 220, width: 0, height: 30), in: window))
        XCTAssertEqual(QQSongGeometryPolicy.point(for: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.1),
                                                  in: window), CGPoint(x: 340, y: 350))
        XCTAssertNil(QQSongGeometryPolicy.point(for: CGRect(x: 0.9, y: 0.2, width: 0.2, height: 0.1),
                                                in: window))
    }

    private func backend(_ surface: SongTestSurface, vision: SongTestVision,
                         playback: SongTestPlayback, pollAttempts: Int = 1,
                         searchSamples: Int = 1) -> NativeQQSongSearchBackend {
        NativeQQSongSearchBackend(surface: surface, vision: vision, selector: SongTestSelector(),
                                  playback: playback, pollAttempts: pollAttempts, pollInterval: .zero,
                                  searchSamples: searchSamples, searchSampleInterval: .zero)
    }

    private func expect(_ expected: QQSongSearchError,
                        _ operation: () async throws -> QQMusicPlayback) async {
        do { _ = try await operation(); XCTFail("Expected \(expected)") }
        catch let error as QQSongSearchError { XCTAssertEqual(error, expected) }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testVerifiedSearchAndReadbackSucceeds() async throws {
        let surface = SongTestSurface(nativeWindow), vision = SongTestVision()
        let reader = SongTestPlayback(surface: surface), auth = SongTestAuthorization()
        let result = try await backend(surface, vision: vision, playback: reader)
            .play(request, authorize: { await auth.grant() }, beforePlay: { await auth.admit() })
        XCTAssertEqual(result.track, "晴天 - 周杰伦")
        XCTAssertTrue(result.playing)
        XCTAssertEqual(surface.searches, 1)
        XCTAssertEqual(surface.queries, ["晴天 周杰伦"])
        XCTAssertEqual(surface.preparations, 1)
        XCTAssertEqual(surface.clicks, 1)
        let observed0 = await auth.admissionCount()
        XCTAssertEqual(observed0, 1)
        let observed1 = await vision.recognitions
        XCTAssertEqual(observed1, 1)
    }

    func testExplicitGrantPreparesAlreadyRunningQQBeforeInspectingForeground() async throws {
        let surface = SongTestSurface(nativeWindow), vision = SongTestVision()
        surface.foreground = false // Workbench is foreground when the user clicks its button.
        let reader = SongTestPlayback(surface: surface)
        let played = try await backend(surface, vision: vision, playback: reader)
            .play(request, authorize: { true }, beforePlay: { })
        XCTAssertEqual(played.track, "晴天 - 周杰伦")
        XCTAssertEqual(surface.preparations, 1)
        let denied = SongTestSurface(nativeWindow)
        denied.foreground = false
        await expect(.unauthorized) {
            try await backend(denied, vision: SongTestVision(), playback: SongTestPlayback(surface: denied))
                .play(request, authorize: { false }, beforePlay: { })
        }
        XCTAssertEqual(denied.preparations, 0)
        XCTAssertEqual(denied.searches, 0)
    }

    func testLoadingSearchResultsAreResampledReadOnlyWithoutResubmission() async throws {
        let surface = SongTestSurface(nativeWindow), vision = SongTestVision()
        await vision.setLoadingSamples(2)
        let reader = SongTestPlayback(surface: surface)
        let played = try await backend(surface, vision: vision, playback: reader, searchSamples: 3)
            .play(request, authorize: { true }, beforePlay: { })
        XCTAssertEqual(played.track, "晴天 - 周杰伦")
        XCTAssertEqual(surface.searches, 1)
        XCTAssertEqual(surface.clicks, 1)
        let captures = await vision.captures
        XCTAssertEqual(captures, 3)
        let recognitions = await vision.recognitions
        XCTAssertEqual(recognitions, 3)
    }

    func testAmbiguousFirstSampleFailsWithoutSamplingAgainOrClicking() async {
        let surface = SongTestSurface(nativeWindow), vision = SongTestVision()
        await vision.setAmbiguousSamples(1)
        let reader = SongTestPlayback(surface: surface)
        await expect(.ambiguous) {
            try await backend(surface, vision: vision, playback: reader, searchSamples: 3)
                .play(request, authorize: { true }, beforePlay: { })
        }
        XCTAssertEqual(surface.searches, 1)
        XCTAssertEqual(surface.clicks, 0)
        let captures = await vision.captures
        XCTAssertEqual(captures, 1)
        let recognitions = await vision.recognitions
        XCTAssertEqual(recognitions, 1)
    }

    func testFinalAuthorizationAfterDurableAdmissionBlocksClick() async {
        let surface = SongTestSurface(nativeWindow), vision = SongTestVision()
        let reader = SongTestPlayback(surface: surface), auth = SongTestAuthorization()
        await expect(.unauthorized) {
            try await backend(surface, vision: vision, playback: reader)
                .play(request, authorize: { await auth.grant() }, beforePlay: {
                    await auth.admit(); await auth.revoke()
                })
        }
        XCTAssertEqual(surface.clicks, 0)
        let observed2 = await auth.admissionCount()
        XCTAssertEqual(observed2, 1)
    }

    func testUnknownClickOrUnreadableResultNeverRetries() async {
        let surface = SongTestSurface(nativeWindow), vision = SongTestVision()
        let reader = SongTestPlayback(surface: surface), auth = SongTestAuthorization()
        surface.failAfterClick = true
        await expect(.unknownOutcome) {
            try await backend(surface, vision: vision, playback: reader)
                .play(request, authorize: { await auth.grant() }, beforePlay: { await auth.admit() })
        }
        XCTAssertEqual(surface.clicks, 1)
        XCTAssertEqual(surface.searches, 1)
        surface.failAfterClick = false
        reader.unreadable = true
        await expect(.unknownOutcome) {
            try await backend(surface, vision: vision, playback: reader)
                .play(request, authorize: { await auth.grant() }, beforePlay: { await auth.admit() })
        }
        XCTAssertEqual(surface.clicks, 2)
        XCTAssertEqual(surface.searches, 2)
    }

    func testVerifiedWrongTrackGetsOnlyOneFreshCorrection() async {
        let surface = SongTestSurface(nativeWindow), vision = SongTestVision()
        let reader = SongTestPlayback(surface: surface), auth = SongTestAuthorization()
        reader.wrongFirst = true
        let result = try? await backend(surface, vision: vision, playback: reader)
            .play(request, authorize: { await auth.grant() }, beforePlay: { await auth.admit() })
        XCTAssertEqual(result?.track, "晴天 - 周杰伦")
        XCTAssertEqual(surface.searches, 2)
        XCTAssertEqual(surface.clicks, 2)
        let observed3 = await auth.admissionCount()
        XCTAssertEqual(observed3, 2)
    }

    func testLiveReadbackMustHaveExplicitLiveVersion() async throws {
        let surface = SongTestSurface(nativeWindow), vision = SongTestVision()
        let reader = SongTestPlayback(surface: surface)
        reader.trackOverride = "晴天 (Live) - 周杰伦"
        let live = QQSongRequest(title: "晴天", artist: "周杰伦", version: .live)
        let played = try await backend(surface, vision: vision, playback: reader)
            .play(live, authorize: { true }, beforePlay: { })
        XCTAssertEqual(played.track, "晴天 (Live) - 周杰伦")
        await expect(.unknownOutcome) {
            try await backend(surface, vision: vision, playback: reader)
                .play(request, authorize: { true }, beforePlay: { })
        }
        XCTAssertEqual(surface.clicks, 2) // Unchanged live playback cannot trigger original retry.
    }

    func testWrongTrackThenUnreadableStatusDoesNotRetry() async {
        let surface = SongTestSurface(nativeWindow), vision = SongTestVision()
        let reader = SongTestPlayback(surface: surface)
        reader.scriptedTracks = ["旧歌 - 歌手甲", "别的歌 - 别的歌手", nil]
        await expect(.unknownOutcome) {
            try await backend(surface, vision: vision, playback: reader, pollAttempts: 2)
                .play(request, authorize: { true }, beforePlay: { })
        }
        XCTAssertEqual(surface.clicks, 1)
        XCTAssertEqual(surface.searches, 1)
    }

    func testUnchangedOldTrackAfterClickIsUnknownAndNeverRetried() async {
        let surface = SongTestSurface(nativeWindow), vision = SongTestVision()
        let reader = SongTestPlayback(surface: surface)
        reader.trackOverride = "旧歌 - 歌手甲"
        await expect(.unknownOutcome) {
            try await backend(surface, vision: vision, playback: reader)
                .play(request, authorize: { true }, beforePlay: { })
        }
        XCTAssertEqual(surface.clicks, 1)
        XCTAssertEqual(surface.searches, 1)
    }

    func testIdentityChangePermissionAndLossOfForegroundRejectBeforePlayback() async {
        let surface = SongTestSurface(nativeWindow), vision = SongTestVision()
        let reader = SongTestPlayback(surface: surface), auth = SongTestAuthorization()
        surface.moveAfterSearch = true
        await expect(.unavailableWindow) {
            try await backend(surface, vision: vision, playback: reader)
                .play(request, authorize: { await auth.grant() }, beforePlay: { await auth.admit() })
        }
        XCTAssertEqual(surface.clicks, 0)
        let observed4 = await vision.captures
        XCTAssertEqual(observed4, 0)

        let deniedSurface = SongTestSurface(nativeWindow)
        deniedSurface.trusted = false
        await expect(.permissionRequired) {
            try await backend(deniedSurface, vision: vision, playback: SongTestPlayback(surface: deniedSurface))
                .play(request, authorize: { true }, beforePlay: { })
        }
        XCTAssertEqual(deniedSurface.searches, 0)

        let lostSurface = SongTestSurface(nativeWindow)
        lostSurface.loseFocusAfterSearch = true
        await expect(.unavailableWindow) {
            try await backend(lostSurface, vision: vision, playback: SongTestPlayback(surface: lostSurface))
                .play(request, authorize: { true }, beforePlay: { })
        }
        XCTAssertEqual(lostSurface.clicks, 0)
    }
}
