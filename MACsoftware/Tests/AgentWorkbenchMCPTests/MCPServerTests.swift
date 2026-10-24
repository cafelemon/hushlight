import XCTest
@testable import AgentWorkbenchMCP
import WorkbenchKit

final class MCPServerTests: XCTestCase {
    private func request(_ method: String, params: String = "{}") -> Data {
        Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"\(method)\",\"params\":\(params)}".utf8)
    }

    private func object(_ data: Data?) throws -> [String: JSONValue] {
        guard let data, case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw TestFailure.invalidResponse
        }
        return object
    }

    func testAnalysisWorkerUsesAuthenticatedOperationsWithoutActionEnvelope() throws {
        var forwarded = false
        let server = MCPServer { operation, action, _, _ in
            if operation == "capabilities" {
                return .init(requestID: "discovery", status: "succeeded", result: .object([
                    "grants": .array([.string("automation.worker")]),
                    "actions": .array([.string("automation.claim"), .string("automation.submit")])]))
            }
            XCTAssertEqual(operation, "automation.claim")
            XCTAssertNil(action)
            forwarded = true
            return .init(requestID: "claim", status: "succeeded", result: .object(["job": .null]))
        }
        _ = try object(server.process(request("tools/call", params: "{\"name\":\"workbench_automation_claim\",\"arguments\":{}}")))
        XCTAssertTrue(forwarded)
    }

    func testQQMusicToolIsReadOnlyAndForwardsOnlyTheStatusAction() throws {
        var forwarded = false
        let server = MCPServer { operation, action, parameters, _ in
            if operation == "capabilities" {
                return .init(requestID: "discovery", status: "succeeded", result: .object([
                    "grants": .array([.string("music.read")]), "actions": .array([.string("music.qq.status")])]))
            }
            XCTAssertEqual(operation, "action")
            XCTAssertEqual(action, "music.qq.status")
            XCTAssertEqual(parameters, .object([:]))
            forwarded = true
            return .init(requestID: "status", status: "succeeded", result: .object(["playbackStatus": .string("unknown")]))
        }
        let tool = try XCTUnwrap(MCPTools.all.first { $0.name == "workbench_qqmusic_status" })
        XCTAssertFalse(tool.isWrite)
        _ = try object(server.process(request("tools/call", params: "{\"name\":\"workbench_qqmusic_status\",\"arguments\":{}}")))
        XCTAssertTrue(forwarded)
    }

    func testQQMusicControlRequiresStableWriteIDAndDoesNotConvertUnknown() throws {
        var calls = 0
        let server = MCPServer { operation, action, _, requestID in
            if operation == "capabilities" {
                return .init(requestID: "capabilities", status: "succeeded", result: .object([
                    "grants": .array([.string("music.write")]), "actions": .array([.string("music.qq.play")])]))
            }
            XCTAssertEqual(action, "music.qq.play")
            let requestID = try XCTUnwrap(requestID)
            XCTAssertNotNil(UUID(uuidString: requestID))
            calls += 1
            return .init(requestID: requestID, status: "unknown", error: "result_unverifiable")
        }
        let tool = try XCTUnwrap(MCPTools.all.first { $0.name == "workbench_qqmusic_play" })
        XCTAssertTrue(tool.isWrite)
        let missing = try object(server.process(request("tools/call", params: "{\"name\":\"workbench_qqmusic_play\",\"arguments\":{}}")))
        XCTAssertNotNil(missing["error"])
        XCTAssertEqual(calls, 0)
        let requestID = UUID().uuidString
        let response = try object(server.process(request("tools/call", params: "{\"name\":\"workbench_qqmusic_play\",\"arguments\":{\"request_id\":\"\(requestID)\"}}")))
        XCTAssertTrue(String(describing: response).contains("unknown"))
        XCTAssertEqual(calls, 1)
    }

    func testQQSongSearchPlaySchemaAndStableRequestForwarding() throws {
        let tool = try XCTUnwrap(MCPTools.all.first { $0.name == "workbench_qqmusic_search_play" })
        XCTAssertTrue(tool.isWrite)
        XCTAssertEqual(tool.action, "music.qq.searchPlay")
        XCTAssertEqual(tool.grant, "music.write")
        guard case .object(let schema) = tool.schema,
              case .array(let required)? = schema["required"],
              case .object(let properties)? = schema["properties"],
              case .object(let version)? = properties["version"] else {
            return XCTFail("Missing search-play schema")
        }
        let requiredNames = required.compactMap { value -> String? in
            if case .string(let name) = value { return name }
            return nil
        }
        XCTAssertEqual(Set(requiredNames), Set(["request_id", "title"]))
        XCTAssertEqual(version["enum"], .array([.string("original"), .string("live")]))
        XCTAssertEqual(schema["additionalProperties"], .bool(false))

        let id = UUID().uuidString
        var forwarded = [(String?, JSONValue, String?)]()
        let server = MCPServer { operation, action, parameters, requestID in
            if operation == "capabilities" {
                return .init(requestID: "discovery", status: "succeeded", result: .object([
                    "grants": .array([.string("music.write")]),
                    "actions": .array([.string("music.qq.searchPlay")])]))
            }
            forwarded.append((action, parameters, requestID))
            return .init(requestID: requestID ?? "", status: "unknown", error: "result_unverifiable")
        }
        let missing = try object(server.process(request("tools/call", params:
            "{\"name\":\"workbench_qqmusic_search_play\",\"arguments\":{\"title\":\"晴天\"}}")))
        XCTAssertNotNil(missing["error"])
        XCTAssertTrue(forwarded.isEmpty)

        let params = "{\"name\":\"workbench_qqmusic_search_play\",\"arguments\":{\"request_id\":\"\(id)\",\"title\":\"晴天\",\"artist\":\"周杰伦\",\"version\":\"original\"}}"
        let response = try object(server.process(request("tools/call", params: params)))
        XCTAssertTrue(String(describing: response).contains("unknown"))
        XCTAssertEqual(forwarded.count, 1)
        XCTAssertEqual(forwarded[0].0, "music.qq.searchPlay")
        XCTAssertEqual(forwarded[0].2, id)
        XCTAssertEqual(forwarded[0].1, .object(["title": .string("晴天"),
                                              "artist": .string("周杰伦"),
                                              "version": .string("original")]))
    }

    func testInitializeAndPingDoNotContactHost() throws {
        let server = MCPServer { _, _, _, _ in XCTFail("Host should not be called"); throw TestFailure.unexpectedCall }
        let initialized = try object(server.process(request("initialize")))
        guard case .object(let result)? = initialized["result"] else { return XCTFail("Missing result") }
        XCTAssertEqual(result["protocolVersion"], .string("2025-06-18"))
        XCTAssertNotNil(try object(server.process(request("ping")))["result"])
    }

    func testDraftWriteAcceptsRecipientArraysAndSendRequestNeverApproves() throws {
        var actions: [String] = []
        let server = MCPServer { operation, action, parameters, _ in
            if operation == "capabilities" {
                return .init(requestID: "discovery", status: "succeeded", result: .object([
                    "grants": .array([.string("mail.write"), .string("mail.send.request")]),
                    "actions": .array([.string("mail.draft.create"), .string("mail.send.request")])]))
            }
            actions.append(action ?? "")
            if action == "mail.draft.create", case .object(let fields) = parameters {
                XCTAssertEqual(fields["to"], .array([.string("to@example.com")]))
                XCTAssertNil(fields["request_id"])
            }
            return .init(requestID: "write", status: "succeeded", result: .object(["send_state": .string("awaiting_confirmation")]))
        }
        let uuid = UUID().uuidString
        let create = request("tools/call", params: "{\"name\":\"workbench_mail_draft_create\",\"arguments\":{\"request_id\":\"\(uuid)\",\"draft_id\":\"draft\",\"sender\":\"sender@example.com\",\"to\":[\"to@example.com\"],\"subject\":\"test\",\"text\":\"body\"}}")
        XCTAssertNotNil(try object(server.process(create))["result"])
        let send = request("tools/call", params: "{\"name\":\"workbench_mail_send_request\",\"arguments\":{\"request_id\":\"\(UUID().uuidString)\",\"draft_id\":\"draft\",\"expected_revision\":\"\(String(repeating: "a", count: 64))\"}}")
        let response = try object(server.process(send))
        XCTAssertTrue(String(describing: response).contains("awaiting_confirmation"))
        XCTAssertEqual(actions, ["mail.draft.create", "mail.send.request"])
        let forged = request("tools/call", params: "{\"name\":\"workbench_mail_send_request\",\"arguments\":{\"confirmed\":true}}")
        XCTAssertNotNil(try object(server.process(forged))["error"])
        XCTAssertFalse(MCPTools.all.contains { $0.action == "mail.send" || $0.name.contains("confirm") })
    }

    func testListFiltersToolsByCurrentGrants() throws {
        let server = MCPServer { operation, _, _, _ in
            XCTAssertEqual(operation, "capabilities")
            return WorkbenchResponse(requestID: "test", status: "succeeded", result: .object([
                "grants": .array([.string("volume.read")]),
                "actions": .array([.string("system.volume.get")])
            ]))
        }
        let response = try object(server.process(request("tools/list")))
        guard case .object(let result)? = response["result"],
              case .array(let tools)? = result["tools"] else { return XCTFail("Missing tools") }
        let names = tools.compactMap { tool -> String? in
            guard case .object(let fields) = tool, case .string(let name)? = fields["name"] else { return nil }
            return name
        }
        XCTAssertTrue(names.contains("workbench_volume_get"))
        XCTAssertTrue(names.contains("workbench_status"))
        XCTAssertFalse(names.contains("workbench_note_append"))
    }

    func testMailToolsRequireBothGrantAndCurrentScopeActions() throws {
        var enabled = true
        let server = MCPServer { operation, _, _, _ in
            XCTAssertEqual(operation, "capabilities")
            return .init(requestID: "test", status: "succeeded", result: .object([
                "grants": .array([.string("mail.read")]),
                "actions": .array(enabled ? [.string("mail.search"), .string("mail.read")] : [])
            ]))
        }
        func names() throws -> String {
            String(decoding: try XCTUnwrap(server.process(request("tools/list"))), as: UTF8.self)
        }
        XCTAssertTrue(try names().contains("workbench_mail_search"))
        enabled = false
        XCTAssertFalse(try names().contains("workbench_mail_read"))
    }

    func testCallRechecksGrantAndPreservesUnknownStatus() throws {
        var grants = ["note.write"]
        var actionCalls = 0
        let server = MCPServer { operation, action, _, _ in
            if operation == "capabilities" {
                return WorkbenchResponse(requestID: "test", status: "succeeded", result: .object([
                    "grants": .array(grants.map(JSONValue.string)), "actions": .array([.string("note.append")])
                ]))
            }
            actionCalls += 1
            XCTAssertEqual(action, "note.append")
            return WorkbenchResponse(requestID: "test", status: "unknown", error: "result_unverifiable")
        }
        let arguments = "{\"request_id\":\"00000000-0000-0000-0000-000000000001\",\"note_id\":\"a\",\"text\":\"hello\",\"expected_revision\":\"\(String(repeating: "a", count: 64))\"}"
        let call = request("tools/call", params: "{\"name\":\"workbench_note_append\",\"arguments\":\(arguments)}")
        let first = try object(server.process(call))
        guard case .object(let firstResult)? = first["result"],
              case .object(let structured)? = firstResult["structuredContent"] else { return XCTFail("Missing result") }
        XCTAssertEqual(firstResult["isError"], .bool(true))
        XCTAssertEqual(structured["status"], .string("unknown"))
        XCTAssertEqual(structured["error"], .string("result_unverifiable"))
        grants = []
        let second = try object(server.process(call))
        guard case .object(let secondResult)? = second["result"] else { return XCTFail("Missing result") }
        XCTAssertEqual(secondResult["isError"], .bool(true))
        XCTAssertEqual(actionCalls, 1)
    }

    func testInvalidArgumentsNeverReachHost() throws {
        let server = MCPServer { _, _, _, _ in XCTFail("Host should not be called"); throw TestFailure.unexpectedCall }
        let response = try object(server.process(request("tools/call", params: "{\"name\":\"workbench_timer_create\",\"arguments\":{}}")))
        guard case .object(let error)? = response["error"] else { return XCTFail("Missing error") }
        XCTAssertEqual(error["code"], .number(-32602))
    }

    func testWriteRequiresStableIDAndEchoesItOnTransportFailure() throws {
        let id = UUID().uuidString
        var submittedIDs: [String] = []
        let server = MCPServer { operation, _, parameters, requestID in
            if operation == "capabilities" {
                return .init(requestID: "capabilities", status: "succeeded", result: .object([
                    "grants": .array([.string("timer.write")]), "actions": .array([.string("timer.cancel")])
                ]))
            }
            submittedIDs.append(requestID ?? "missing")
            XCTAssertEqual(parameters, .object(["timer_id": .string("timer")]))
            throw TestFailure.unexpectedCall
        }
        let missing = try object(server.process(request("tools/call", params: "{\"name\":\"workbench_timer_cancel\",\"arguments\":{\"timer_id\":\"timer\"}}")))
        XCTAssertNotNil(missing["error"])
        XCTAssertTrue(submittedIDs.isEmpty)
        let call = request("tools/call", params: "{\"name\":\"workbench_timer_cancel\",\"arguments\":{\"timer_id\":\"timer\",\"request_id\":\"\(id)\"}}")
        for _ in 0..<2 {
            let response = try object(server.process(call))
            let result = try XCTUnwrap(response["result"])
            guard case .object(let fields) = result, case .object(let structured)? = fields["structuredContent"] else { return XCTFail("Missing structured content") }
            XCTAssertEqual(structured["request_id"], .string(id))
            XCTAssertEqual(structured["status"], .string("unknown"))
        }
        XCTAssertEqual(submittedIDs, [id, id])
    }

    private enum TestFailure: Error { case invalidResponse, unexpectedCall }
}
