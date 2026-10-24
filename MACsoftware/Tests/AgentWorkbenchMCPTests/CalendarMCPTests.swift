import Foundation
import XCTest
import WorkbenchKit
@testable import AgentWorkbenchMCP

final class CalendarMCPTests: XCTestCase {
    private func rpc(_ method: String, params: String = "{}") -> Data {
        Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"\(method)\",\"params\":\(params)}".utf8)
    }

    func testCalendarToolsOnlyAppearWithGrantAndReadyAction() throws {
        var ready = false
        let server = MCPServer { operation, _, _, _ in
            XCTAssertEqual(operation, "capabilities")
            return .init(requestID: "capabilities", status: "succeeded", result: .object([
                "grants": .array([.string("calendar.read"), .string("calendar.write")]),
                "actions": .array(ready ? ["calendar.list", "calendar.create", "calendar.update", "calendar.cancel"].map(JSONValue.string) : [])
            ]))
        }
        let unavailable = String(decoding: try XCTUnwrap(server.process(rpc("tools/list"))), as: UTF8.self)
        XCTAssertFalse(unavailable.contains("workbench_calendar_create"))
        ready = true
        let available = String(decoding: try XCTUnwrap(server.process(rpc("tools/list"))), as: UTF8.self)
        XCTAssertTrue(available.contains("workbench_calendar_list"))
        XCTAssertTrue(available.contains("workbench_calendar_create"))
        XCTAssertTrue(available.contains("workbench_calendar_update"))
        XCTAssertTrue(available.contains("workbench_calendar_cancel"))
        XCTAssertFalse(available.contains("calendar_enable"))
    }

    func testCalendarCreateRequiresStableRequestAndBoundedHTTPSSource() throws {
        var actionCalls = 0
        let server = MCPServer { operation, action, parameters, requestID in
            if operation == "capabilities" {
                return .init(requestID: "capabilities", status: "succeeded", result: .object([
                    "grants": .array([.string("calendar.write")]), "actions": .array([.string("calendar.create")])
                ]))
            }
            actionCalls += 1
            XCTAssertEqual(action, "calendar.create")
            XCTAssertNotNil(requestID.flatMap(UUID.init(uuidString:)))
            guard case .object(let fields) = parameters else { return .init(requestID: "bad", status: "failed") }
            XCTAssertNil(fields["request_id"])
            XCTAssertEqual(fields["source_url"], .string("https://example.com/meeting"))
            return .init(requestID: requestID ?? "", status: "succeeded")
        }
        let fields = "\"event_id\":\"event-1\",\"title\":\"Meeting\",\"start_at\":\"2030-01-01T10:00:00Z\",\"end_at\":\"2030-01-01T11:00:00Z\""
        let missing = rpc("tools/call", params: "{\"name\":\"workbench_calendar_create\",\"arguments\":{\(fields)}}")
        XCTAssertTrue(String(decoding: try XCTUnwrap(server.process(missing)), as: UTF8.self).contains("Invalid tool arguments"))
        let unsafe = rpc("tools/call", params: "{\"name\":\"workbench_calendar_create\",\"arguments\":{\(fields),\"request_id\":\"\(UUID().uuidString)\",\"source_url\":\"file:///tmp/private\"}}")
        XCTAssertTrue(String(decoding: try XCTUnwrap(server.process(unsafe)), as: UTF8.self).contains("Invalid tool arguments"))
        XCTAssertEqual(actionCalls, 0)
        let valid = rpc("tools/call", params: "{\"name\":\"workbench_calendar_create\",\"arguments\":{\(fields),\"request_id\":\"\(UUID().uuidString)\",\"source_url\":\"https://example.com/meeting\"}}")
        XCTAssertTrue(String(decoding: try XCTUnwrap(server.process(valid)), as: UTF8.self).contains("succeeded"))
        XCTAssertEqual(actionCalls, 1)
    }
}
