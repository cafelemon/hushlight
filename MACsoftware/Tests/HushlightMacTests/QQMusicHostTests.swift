import BridgeCore
import WorkbenchKit
import XCTest
@testable import HushlightMac

private actor MusicBridge: BridgeService {
    var paused = false
    var reads = 0
    func snapshot() async throws -> BridgeSnapshot { .init(status: .localReady, permissions: [], recentActions: []) }
    func workbenchState() async throws -> WorkbenchServiceState { .init(status: paused ? "paused" : "localReady", supportedActions: ["music.qq.status"], isSimulation: false) }
    func setPaused(_ value: Bool) async throws { paused = value }
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
    func qqMusicStatus() async throws -> QQMusicStatus {
        reads += 1
        return .init(installed: true, running: false, version: "synthetic", checkedAt: Date())
    }
    func count() -> Int { reads }
}

final class QQMusicHostTests: XCTestCase {
    func testStatusRequiresIndependentGrantAndSharedPause() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qq-host-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = MusicBridge(), host = try WorkbenchHost(bridge: bridge, directory: directory)
        let client = try await host.createClient(name: "Music")
        func request() async -> WorkbenchResponse {
            await host.process(.init(requestID: UUID().uuidString, operation: "action", action: "music.qq.status", credential: client.credential))
        }
        let initial = await request()
        XCTAssertEqual(initial.status, "rejected")
        try await host.setGrants(clientID: client.id, grants: [.musicRead])
        let granted = await request()
        XCTAssertEqual(granted.status, "succeeded")
        guard case .object(let fields) = granted.result else { return XCTFail("Missing metadata") }
        XCTAssertEqual(fields["playbackStatus"], .string("unknown"))
        XCTAssertEqual(fields["controlsAvailable"], .bool(false))
        try await bridge.setPaused(true)
        let paused = await request()
        XCTAssertEqual(paused.status, "rejected")
        try await bridge.setPaused(false)
        try await host.setGrants(clientID: client.id, grants: [])
        let withdrawn = await request()
        XCTAssertEqual(withdrawn.status, "rejected")
        let reads = await bridge.count()
        XCTAssertEqual(reads, 1)
    }
}

private actor MusicControlBridge: BridgeService {
    var calls = 0
    var failAfterPress = false
    func failUnknown() { failAfterPress = true }
    func snapshot() async throws -> BridgeSnapshot { .init(status: .localReady, permissions: [], recentActions: []) }
    func workbenchState() async throws -> WorkbenchServiceState { .init(status: "localReady", supportedActions: ["music.qq.play", "music.qq.playback"], isSimulation: false) }
    func setPaused(_ value: Bool) async throws {}
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
    func qqMusicPlayback() async throws -> QQMusicPlayback { .init(playing: false, track: "Synthetic - Track", checkedAt: Date()) }
    func performQQMusic(_ action: QQMusicPlaybackAction, authorize: @escaping @Sendable () async -> Bool) async throws -> QQMusicPlayback {
        guard await authorize() else { throw QQMusicPlaybackError.permissionRequired }
        calls += 1
        if failAfterPress { throw QQMusicPlaybackError.unknownOutcome }
        return .init(playing: true, track: "Synthetic - Track", checkedAt: Date())
    }
    func count() -> Int { calls }
}

extension QQMusicHostTests {
    func testUnknownControlIsJournaledAndNeverPressedAgainForSameRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qq-control-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = MusicControlBridge()
        let host = try WorkbenchHost(bridge: bridge, directory: directory)
        let client = try await host.createClient(name: "Control")
        let id = UUID().uuidString
        let command = WorkbenchRequest(requestID: id, operation: "action", action: "music.qq.play", credential: client.credential)
        let ungranted = await host.process(command)
        XCTAssertEqual(ungranted.status, "rejected")
        try await host.setGrants(clientID: client.id, grants: [.musicWrite])
        await bridge.failUnknown()
        let unknown = await host.process(command)
        XCTAssertEqual(unknown.status, "unknown")
        let replay = await host.process(command)
        XCTAssertEqual(replay.status, "unknown")
        let result = await host.process(.init(requestID: UUID().uuidString, operation: "result", parameters: .object(["request_id": .string(id)]), credential: client.credential))
        XCTAssertEqual(result.status, "succeeded")
        guard case .object(let resultFields) = result.result else { return XCTFail("Missing journal result") }
        XCTAssertEqual(resultFields["status"], .string("unknown"))
        let calls = await bridge.count()
        XCTAssertEqual(calls, 1)
        let readWithoutGrant = await host.process(.init(requestID: UUID().uuidString, operation: "action", action: "music.qq.playback", credential: client.credential))
        XCTAssertEqual(readWithoutGrant.status, "rejected")
    }
}
