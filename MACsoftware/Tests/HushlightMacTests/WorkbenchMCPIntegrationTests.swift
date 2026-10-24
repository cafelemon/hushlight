import XCTest
import Foundation
import WorkbenchKit
import BridgeCore
@testable import HushlightMac

final class WorkbenchMCPIntegrationTests: XCTestCase {
    func testMailMCPProcessSearchAndReadUseScopedHostWithoutPersistingContent() async throws {
        let executable = try executable()
        let root = URL(fileURLWithPath: "/tmp/wb-mail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try WorkbenchHost(bridge: MCPMailIntegrationBridge(), directory: root)
        let client = try await host.createClient(name: "Mail fake integration")
        try await host.setGrants(clientID: client.id, grants: [.mailRead])
        try await host.start()
        let replies = try await runMCP(executable: executable, credential: root.appendingPathComponent(client.id + ".credential"),
            socket: root.appendingPathComponent("workbench.sock"), requests: [
                ["jsonrpc": "2.0", "id": 1, "method": "initialize"],
                ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
                ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "workbench_mail_search", "arguments": ["query": "test", "unread_only": true]]],
                ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "workbench_mail_read", "arguments": ["message_id": "fake-mail-id"]]]
            ])
        await host.stop()
        for index in [2, 3] {
            let structured = (replies[index]["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            XCTAssertEqual(structured?["status"] as? String, "succeeded")
            XCTAssertEqual((structured?["result"] as? [String: Any])?["simulation"] as? Bool, true)
        }
        let encoded = try Data(contentsOf: root.appendingPathComponent("state.json"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("fake-private-mail"))
    }
    private func executable() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent(".build/debug/agent-workbench-mcp")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw XCTSkip("Build agent-workbench-mcp before process integration") }
        return url
    }

    private func runMCP(executable: URL, credential: URL, socket: URL, requests: [[String: Any]]) async throws -> [[String: Any]] {
        let inputData = try requests.reduce(into: Data()) { result, request in
            result.append(try JSONSerialization.data(withJSONObject: request)); result.append(10)
        }
        let data = try await Task.detached {
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = executable
            process.arguments = ["--credential-file", credential.path, "--socket", socket.path]
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: inputData)
            try input.fileHandleForWriting.close()
            let result = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NSError(domain: "MCPProcess", code: Int(process.terminationStatus)) }
            return result
        }.value
        return try data.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
    }

    func testMCPProcessUsesHostGrantAndDeduplicatesWrite() async throws {
        let executable = try executable()
        let root = URL(fileURLWithPath: "/tmp/wb-e2e-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = MCPIntegrationBridge()
        let host = try WorkbenchHost(bridge: bridge, directory: root)
        let client = try await host.createClient(name: "MCP integration")
        try await host.setGrants(clientID: client.id, grants: [.timerWrite, .timerRead])
        try await host.start()
        let id = UUID().uuidString
        let write: [String: Any] = ["name": "workbench_timer_create", "arguments": ["request_id": id, "timer_id": "test", "fire_at": "2030-01-01T00:00:00Z", "label": "fake timer"]]
        let requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": write],
            ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": write],
            ["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "workbench_result", "arguments": ["request_id": id]]]
        ]
        let replies = try await runMCP(executable: executable, credential: root.appendingPathComponent(client.id + ".credential"), socket: root.appendingPathComponent("workbench.sock"), requests: requests)
        await host.stop()
        XCTAssertEqual(replies.count, 5)
        let count = await bridge.creates
        XCTAssertEqual(count, 1)
        let tools = ((replies[1]["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(tools.contains("workbench_timer_create"))
        XCTAssertFalse(tools.contains("workbench_note_read"))
        for index in [2, 3] {
            let structured = (replies[index]["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            XCTAssertEqual(structured?["status"] as? String, "succeeded")
            XCTAssertEqual(structured?["request_id"] as? String, id)
            if index == 2 { XCTAssertEqual((structured?["result"] as? [String: Any])?["simulation"] as? Bool, true) }
        }
    }

    func testLiveCoreAudioThroughMCPAndHost() async throws {
        guard ProcessInfo.processInfo.environment["HUSHLIGHT_LIVE_VOLUME_SMOKE"] == "1" else { throw XCTSkip("Opt-in real read-only Core Audio smoke") }
        let executable = try executable()
        let root = URL(fileURLWithPath: "/tmp/wb-live-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = LocalBridgeService(timerStorageURL: root.appendingPathComponent("timers.json"), notesStorageURL: root.appendingPathComponent("notes.json"))
        let host = try WorkbenchHost(bridge: bridge, directory: root)
        let client = try await host.createClient(name: "Read-only Core Audio smoke")
        try await host.setGrants(clientID: client.id, grants: [.volumeRead])
        try await host.start()
        let replies = try await runMCP(executable: executable, credential: root.appendingPathComponent(client.id + ".credential"), socket: root.appendingPathComponent("workbench.sock"), requests: [
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "workbench_volume_get", "arguments": [:]]]
        ])
        await host.stop()
        let structured = (replies.first?["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
        XCTAssertEqual(structured?["status"] as? String, "succeeded")
        let result = structured?["result"] as? [String: Any]
        XCTAssertEqual(result?["simulation"] as? Bool, false)
        XCTAssertNotNil(result?["value"] as? Double)
        let state = try await bridge.workbenchState()
        XCTAssertEqual(state.recentActions.first?.callerID, client.id)
    }
}

private actor MCPMailIntegrationBridge: BridgeService {
    func snapshot() async throws -> BridgeSnapshot { .init(status: .localReady, permissions: [], recentActions: []) }
    func workbenchState() async throws -> WorkbenchServiceState {
        .init(status: "localReady", supportedActions: ["mail.search", "mail.read"], isSimulation: true, mailScopeID: "test-scope")
    }
    func setPaused(_ paused: Bool) async throws {}
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
    func searchMail(query: String, unreadOnly: Bool) async throws -> LocalMailCommandResult {
        .init(status: "succeeded", messages: [.init(id: "fake-mail-id", subject: "test", sender: "sender@example.com", receivedAt: Date(), isUnread: true)], isSimulation: true)
    }
    func readMail(id: String) async throws -> LocalMailCommandResult {
        .init(status: "succeeded", mail: .init(message: .init(id: id, subject: "test", sender: "sender@example.com", receivedAt: Date(), isUnread: true), text: "fake-private-mail"), isSimulation: true)
    }
}

private actor MCPIntegrationBridge: BridgeService {
    var creates = 0
    func snapshot() async throws -> BridgeSnapshot { .init(status: .localReady, permissions: [], recentActions: []) }
    func workbenchState() async throws -> WorkbenchServiceState { .init(status: "localReady", supportedActions: ["timer.create"], isSimulation: true) }
    func setPaused(_ paused: Bool) async throws {}
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
    func createTimer(id: String, fireAt: Date, label: String) async throws -> TimerActionReadback {
        creates += 1
        return .init(outcome: .succeeded, stableError: nil, completedAt: Date())
    }
}
