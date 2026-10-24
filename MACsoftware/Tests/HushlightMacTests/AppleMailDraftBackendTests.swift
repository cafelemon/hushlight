import BridgeCore
import Foundation
import XCTest
@testable import HushlightMac

private actor FakeMailDraftRunner: MailDraftScriptRunning {
    var rows: [[String]] = []
    var calls: [MailDraftScriptRequest] = []
    func setRows(_ value: [[String]]) { rows = value }
    func run(_ request: MailDraftScriptRequest) async throws -> [[String]] {
        calls.append(request)
        return rows
    }
    func requests() -> [MailDraftScriptRequest] { calls }
}

final class AppleMailDraftBackendTests: XCTestCase {
    private let scope = MailScopeKey(accountID: "account-1", mailboxPath: ["Inbox"])
    private let input = MailDraftInput(sender: "sender@example.com", to: ["one@example.com", "two@example.com"],
                                       cc: ["copy@example.com"], bcc: ["blind@example.com"],
                                       subject: "Subject", text: "Plain body")

    private func snapshot() -> [[String]] {
        [["42", input.sender, input.to.joined(separator: "\u{1f}"), input.cc.joined(separator: "\u{1f}"),
          input.bcc.joined(separator: "\u{1f}"), input.subject, input.text, "0"]]
    }

    func testCreateReadAndSendUseSameScopeBoundSnapshot() async throws {
        let runner = FakeMailDraftRunner()
        let backend = AppleMailDraftBackend(runner: runner)
        await runner.setRows(snapshot())
        let created = try await backend.create(scope: scope, input: input)
        XCTAssertEqual(created.id, "mail.draft.\(scope.scopeID).42")
        XCTAssertEqual(created.revision, AppleMailDraftBackend.revision(input))
        let read = try await backend.read(scope: scope, id: created.id)
        XCTAssertEqual(read, created)
        await runner.setRows([["status", "submitted"]])
        let outcome = try await backend.send(scope: scope, draft: created)
        XCTAssertEqual(outcome, .submitted)
        let calls = await runner.requests()
        XCTAssertEqual(calls.map(\.operation), ["create", "read", "send"])
        XCTAssertEqual(calls.map(\.accountID), Array(repeating: scope.accountID, count: 3))
        XCTAssertEqual(calls[2].bcc, input.bcc)
        XCTAssertEqual(calls[2].text, input.text)
    }

    func testChangedReadbackAndAttachmentsFailClosed() async throws {
        let runner = FakeMailDraftRunner()
        let backend = AppleMailDraftBackend(runner: runner)
        var changed = snapshot()
        changed[0][4] = "changed@example.com"
        await runner.setRows(changed)
        do { _ = try await backend.create(scope: scope, input: input); XCTFail("Changed Bcc") }
        catch StableErrorCode.resultUnverifiable {}
        changed = snapshot()
        changed[0][7] = "1"
        await runner.setRows(changed)
        do { _ = try await backend.create(scope: scope, input: input); XCTFail("Attachment") }
        catch StableErrorCode.resultUnverifiable {}
    }

    func testWrongScopeOrRevisionNeverCallsScript() async throws {
        let runner = FakeMailDraftRunner()
        let backend = AppleMailDraftBackend(runner: runner)
        let draft = MailDraftContent(id: "mail.draft.\(scope.scopeID).42", scopeID: scope.scopeID,
                                     sender: input.sender, to: input.to, cc: input.cc, bcc: input.bcc,
                                     subject: input.subject, text: input.text, revision: "wrong")
        do { _ = try await backend.send(scope: scope, draft: draft); XCTFail("Revision") }
        catch StableErrorCode.invalidSchema {}
        let other = MailScopeKey(accountID: "account-2", mailboxPath: ["Inbox"])
        do { _ = try await backend.read(scope: other, id: draft.id); XCTFail("Scope") }
        catch StableErrorCode.invalidSchema {}
        let calls = await runner.requests()
        XCTAssertTrue(calls.isEmpty)
    }

    func testAmbiguousScriptResultCannotBecomeSubmitted() async throws {
        let runner = FakeMailDraftRunner()
        let backend = AppleMailDraftBackend(runner: runner)
        let draft = MailDraftContent(id: "mail.draft.\(scope.scopeID).42", scopeID: scope.scopeID,
                                     sender: input.sender, to: input.to, cc: input.cc, bcc: input.bcc,
                                     subject: input.subject, text: input.text,
                                     revision: AppleMailDraftBackend.revision(input))
        await runner.setRows([["status", "unknown"]])
        let outcome = try await backend.send(scope: scope, draft: draft)
        XCTAssertEqual(outcome, .unknown)
        await runner.setRows([["status", "delivered"]])
        do { _ = try await backend.send(scope: scope, draft: draft); XCTFail("Unexpected status") }
        catch StableErrorCode.resultUnverifiable {}
    }
}
