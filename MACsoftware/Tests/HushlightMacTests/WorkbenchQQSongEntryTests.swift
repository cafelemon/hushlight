import BridgeCore
import Foundation
import WorkbenchKit
import XCTest
@testable import HushlightMac

private actor QQSongEntryBridge: BridgeService {
    struct Call: Sendable {
        let id: String
        let caller: String
        let request: QQSongRequest
        let authorized: Bool
    }

    private var recorded: [Call] = []

    func snapshot() async throws -> BridgeSnapshot {
        .init(status: .localReady, permissions: [], recentActions: [])
    }

    func workbenchState() async throws -> WorkbenchServiceState {
        .init(status: "localReady", supportedActions: ["music.qq.status", "music.qq.searchPlay"],
              isSimulation: true)
    }

    func setPaused(_ paused: Bool) async throws {}
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }

    func searchAndPlayQQMusic(id: String, request: QQSongRequest,
                              authorize: @escaping @Sendable () async -> Bool) async throws -> QQSongPlayResult {
        recorded.append(Call(id: id, caller: BridgeExecutionContext.callerID,
                             request: request, authorized: await authorize()))
        return .init(requestID: id, status: "unknown", error: "result_unverifiable", playback: nil)
    }

    func calls() -> [Call] { recorded }
}

final class WorkbenchQQSongEntryTests: XCTestCase {
    func testMusicWriteGrantParametersStableIDAndAuthenticatedCaller() async throws {
        let directory = URL(fileURLWithPath: "/tmp/wb-qqsong-entry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = QQSongEntryBridge()
        let host = try WorkbenchHost(bridge: bridge, directory: directory)
        let alice = try await host.createClient(name: "Alice")
        try await host.setGrants(clientID: alice.id, grants: [.musicRead])
        let id = UUID().uuidString
        func request(_ credential: String, _ requestID: String = UUID().uuidString,
                     _ parameters: JSONValue = .object(["title": .string("晴天"),
                                                        "artist": .string("周杰伦"),
                                                        "version": .string("original")])) -> WorkbenchRequest {
            .init(requestID: requestID, operation: "action", action: "music.qq.searchPlay",
                  parameters: parameters, credential: credential)
        }

        let denied = await host.process(request(alice.credential, id))
        XCTAssertEqual(denied.error, "permission_required")
        let beforeGrant = await bridge.calls()
        XCTAssertTrue(beforeGrant.isEmpty)

        try await host.setGrants(clientID: alice.id, grants: [.musicWrite])
        for parameters: JSONValue in [
            .object(["artist": .string("周杰伦")]),
            .object(["title": .string(" 晴天")]),
            .object(["title": .string("晴天"), "version": .string("remix")]),
            .object(["title": .string("晴天"), "unexpected": .string("x")]),
            .object(["title": .string("晴天"), "artist": .number(3)])
        ] {
            let rejected = await host.process(request(alice.credential, UUID().uuidString, parameters))
            XCTAssertEqual(rejected.error, "invalid_schema")
        }
        let afterInvalid = await bridge.calls()
        XCTAssertTrue(afterInvalid.isEmpty)

        let first = await host.process(request(alice.credential, id))
        XCTAssertEqual(first.requestID, id)
        XCTAssertEqual(first.status, "unknown")
        XCTAssertEqual(first.error, "result_unverifiable")
        let replay = await host.process(request(alice.credential, id))
        XCTAssertEqual(replay.requestID, id)
        XCTAssertEqual(replay.status, "unknown")
        let aliceCalls = await bridge.calls()
        XCTAssertEqual(aliceCalls.count, 1)
        XCTAssertEqual(aliceCalls.first?.id, id)
        XCTAssertEqual(aliceCalls.first?.caller, alice.id)
        XCTAssertEqual(aliceCalls.first?.request.title, "晴天")
        XCTAssertEqual(aliceCalls.first?.request.artist, "周杰伦")
        XCTAssertEqual(aliceCalls.first?.request.version, .original)
        XCTAssertEqual(aliceCalls.first?.authorized, true)

        let bob = try await host.createClient(name: "Bob")
        try await host.setGrants(clientID: bob.id, grants: [.musicWrite])
        let bobResponse = await host.process(request(bob.credential, id))
        XCTAssertEqual(bobResponse.status, "unknown")
        let calls = await bridge.calls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.last?.caller, bob.id)
        XCTAssertEqual(calls.last?.id, id)
        let persisted = try String(contentsOf: directory.appendingPathComponent("state.json"),
                                   encoding: .utf8)
        XCTAssertFalse(persisted.contains("晴天"))
        XCTAssertFalse(persisted.contains("周杰伦"))
    }
}
