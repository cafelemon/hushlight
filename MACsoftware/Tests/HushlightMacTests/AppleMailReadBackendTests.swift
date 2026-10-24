import Foundation
import XCTest
import BridgeCore
@testable import HushlightMac

private actor FakeMailReadRunner: MailScopeScriptRunning {
    var rows: [[String]] = []
    var calls: [(String, MailScopeKey?, String)] = []
    var failure: MailScopeError?
    var pauseNext = false
    var pending: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?

    func configure(_ rows: [[String]]) { self.rows = rows }
    func fail(_ error: MailScopeError?) { failure = error }
    func pauseNextRead() { pauseNext = true }
    func waitForReadStart() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func resumeRead() { pending?.resume(); pending = nil }

    func run(operation: String, scope: MailScopeKey?) async throws -> [[String]] {
        calls.append((operation, scope, ""))
        if operation == "list" { return [["account-1", "Account", "a@example.com", "Inbox"],
                                         ["account-2", "Account", "b@example.com", "Inbox"]] }
        if operation == "verify", let scope {
            return [[scope.accountID, "Account", "a@example.com"] + scope.mailboxPath]
        }
        return []
    }

    func run(operation: String, scope: MailScopeKey, query: String, unreadOnly: Bool, messageID: String) async throws -> [[String]] {
        calls.append((operation, scope, messageID))
        if pauseNext {
            pauseNext = false
            await withCheckedContinuation { continuation in
                pending = continuation
                started?.resume()
                started = nil
            }
        }
        if let failure { throw failure }
        return rows
    }

    func operations() -> [String] { calls.map(\.0) }
}

final class AppleMailReadBackendTests: XCTestCase {
    private let keyA = MailScopeKey(accountID: "account-1", mailboxPath: ["Inbox"])
    private let keyB = MailScopeKey(accountID: "account-2", mailboxPath: ["Inbox"])

    private func backend(_ runner: FakeMailReadRunner) -> (AppleMailScopeBackend, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-read-\(UUID())")
        return (AppleMailScopeBackend(storageURL: root.appendingPathComponent("scope.json"), runner: runner), root)
    }

    func testSearchAndReadBindIDsToExactScope() async throws {
        let runner = FakeMailReadRunner()
        let (backend, url) = backend(runner)
        defer { try? FileManager.default.removeItem(at: url) }
        try await backend.choose(keyA)
        let scopeID = try await backend.scopeID()
        XCTAssertEqual(scopeID, keyA.scopeID)
        await runner.configure([["42", "Hello", "Sender <s@example.com>", "1700000000", "1"]])
        let results = try await backend.search(query: "hello", unreadOnly: true)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "mail.\(keyA.scopeID).42")
        XCTAssertTrue(results[0].isUnread)
        await runner.configure([["42", "Hello", "Sender <s@example.com>", "1700000000", "1", "Plain message"]])
        let content = try await backend.read(id: results[0].id)
        XCTAssertEqual(content.message, results[0])
        XCTAssertEqual(content.text, "Plain message")
        let initialOperations = await runner.operations()
        XCTAssertEqual(initialOperations, ["list", "verify", "search", "read"])
        try await backend.choose(keyB)
        do { _ = try await backend.read(id: results[0].id); XCTFail("Old scope ID must fail") }
        catch StableErrorCode.invalidSchema {}
        let finalOperations = await runner.operations()
        XCTAssertEqual(finalOperations, ["list", "verify", "search", "read", "list", "verify"])
    }

    func testTaskLocalScopeGuardBlocksWrongGrantBeforeRunner() async throws {
        let runner = FakeMailReadRunner()
        let (backend, url) = backend(runner)
        defer { try? FileManager.default.removeItem(at: url) }
        try await backend.choose(keyA)
        do {
            _ = try await BridgeExecutionContext.$mailScopeID.withValue(keyB.scopeID) {
                try await backend.search(query: "", unreadOnly: false)
            }
            XCTFail("Wrong grant must fail")
        } catch StableErrorCode.capabilityDisabled {}
        let operations = await runner.operations()
        XCTAssertEqual(operations, ["list", "verify"])
    }

    func testMalformedAndOversizedResultsFailClosed() async throws {
        let runner = FakeMailReadRunner()
        let (backend, url) = backend(runner)
        defer { try? FileManager.default.removeItem(at: url) }
        try await backend.choose(keyA)
        await runner.configure(Array(repeating: ["42", "Hi", "Sender", "1700000000", "0"], count: 51))
        do { _ = try await backend.search(query: "", unreadOnly: false); XCTFail("Capacity") }
        catch StableErrorCode.capabilityDisabled {}
        await runner.configure([["42", "Hi", "Sender", "not a date", "0"]])
        do { _ = try await backend.search(query: "", unreadOnly: false); XCTFail("Malformed date") }
        catch StableErrorCode.resultUnverifiable {}
        await runner.configure([["42", "Hi", "Sender", "1700000000", "0", String(repeating: "x", count: 24_001)]])
        do { _ = try await backend.read(id: "mail.\(keyA.scopeID).42"); XCTFail("Oversized body") }
        catch StableErrorCode.resultUnverifiable {}
    }

    func testScopeSwitchWhileRunnerWaitsRejectsSearchAndReadPayload() async throws {
        let runner = FakeMailReadRunner()
        let (backend, url) = backend(runner)
        defer { try? FileManager.default.removeItem(at: url) }
        try await backend.choose(keyA)
        await runner.configure([["42", "Private", "Sender", "1700000000", "1"]])
        await runner.pauseNextRead()
        let search = Task { try await backend.search(query: "Private", unreadOnly: false) }
        await runner.waitForReadStart()
        try await backend.choose(keyB)
        await runner.resumeRead()
        do { _ = try await search.value; XCTFail("Old search payload must not escape") }
        catch StableErrorCode.capabilityDisabled {}

        try await backend.choose(keyA)
        await runner.configure([["42", "Private", "Sender", "1700000000", "1", "Secret body"]])
        await runner.pauseNextRead()
        let readID = "mail.\(keyA.scopeID).42"
        let read = Task { try await backend.read(id: readID) }
        await runner.waitForReadStart()
        try await backend.choose(keyB)
        await runner.resumeRead()
        do { _ = try await read.value; XCTFail("Old read payload must not escape") }
        catch StableErrorCode.capabilityDisabled {}
    }

    func testRunnerFailuresMapToStableCodes() async throws {
        let runner = FakeMailReadRunner()
        let (backend, url) = backend(runner)
        defer { try? FileManager.default.removeItem(at: url) }
        try await backend.choose(keyA)
        let cases: [(MailScopeError, StableErrorCode)] = [
            (.permissionRequired, .permissionRequired),
            (.invalidScope, .capabilityDisabled),
            (.corruptState, .capabilityDisabled),
            (.requiresApp, .capabilityDisabled),
            (.capacityExceeded, .capabilityDisabled),
            (.invalidMessageID, .invalidSchema),
            (.messageUnavailable, .invalidSchema),
            (.unavailable, .resultUnverifiable),
            (.invalidResponse, .resultUnverifiable)
        ]
        for (failure, expected) in cases {
            await runner.fail(failure)
            do { _ = try await backend.search(query: "", unreadOnly: false); XCTFail("Expected \(failure)") }
            catch let actual as StableErrorCode { XCTAssertEqual(actual, expected) }
        }
        await runner.fail(nil)
    }
}
