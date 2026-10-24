import Foundation
import Darwin
import XCTest
@testable import HushlightMac

private actor FakeMailScopeRunner: MailScopeScriptRunning {
    var rows: [[String]] = []
    var verification: [[String]] = []
    var operations: [String] = []

    func configure(rows: [[String]], verification: [[String]]) {
        self.rows = rows
        self.verification = verification
    }

    func run(operation: String, scope: MailScopeKey?) async throws -> [[String]] {
        operations.append(operation)
        if operation == "verify" { return verification }
        return rows
    }

    func called() -> [String] { operations }
}

final class AppleMailScopeBackendTests: XCTestCase {
    func testExplicitSelectionPersistsOnlyScopeAndRechecksIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-scope-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("scope.json")
        let runner = FakeMailScopeRunner()
        await runner.configure(rows: [["account-1", "Google", "mailbox@example.com", "收件箱"],
                                      ["account-2", "Other", "another@example.com", "收件箱"]],
                               verification: [["account-1", "Google", "mailbox@example.com", "收件箱"]])
        let backend = AppleMailScopeBackend(storageURL: file, runner: runner)
        let initial = try await backend.selectedScope()
        XCTAssertNil(initial)
        let options = try await backend.availableScopes()
        XCTAssertEqual(options.count, 2)
        XCTAssertTrue(options.contains { $0.accountAddresses.contains("mailbox@example.com") })
        try await backend.choose(MailScopeKey(accountID: "account-1", mailboxPath: ["收件箱"]))
        let selected = try await backend.selectedScope()
        XCTAssertEqual(selected, MailScopeKey(accountID: "account-1", mailboxPath: ["收件箱"]))
        let saved = try Data(contentsOf: file)
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("Google"))
        var attrs = stat()
        XCTAssertEqual(stat(file.path, &attrs), 0)
        XCTAssertEqual(attrs.st_mode & 0o777, 0o600)
        let reloaded = AppleMailScopeBackend(storageURL: file, runner: runner)
        let restored = try await reloaded.selectedScope()
        XCTAssertEqual(restored, selected)
        let called = await runner.called()
        XCTAssertEqual(called, ["list", "list", "verify"])
    }

    func testAmbiguousOrChangedMailboxNeverBecomesSelected() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mail-scope-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let runner = FakeMailScopeRunner()
        await runner.configure(rows: [["account-1", "Google", "address@example.com", "收件箱"],
                                      ["account-1", "Google", "address@example.com", "收件箱"]],
                               verification: [])
        let backend = AppleMailScopeBackend(storageURL: file, runner: runner)
        do { _ = try await backend.availableScopes(); XCTFail("Ambiguous path") }
        catch MailScopeError.invalidScope {}
        await runner.configure(rows: [["account-1", "Google", "address@example.com", "收件箱"]], verification: [])
        do { try await backend.choose(MailScopeKey(accountID: "account-1", mailboxPath: ["收件箱"])); XCTFail("Changed mailbox") }
        catch MailScopeError.invalidScope {}
        let selected = try await backend.selectedScope()
        XCTAssertNil(selected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testCorruptSavedScopePreservedAndFailsClosed() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mail-scope-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("{bad".utf8).write(to: file)
        let backend = AppleMailScopeBackend(storageURL: file, runner: FakeMailScopeRunner())
        do { _ = try await backend.selectedScope(); XCTFail("Expected corrupt state") }
        catch MailScopeError.corruptState {}
        XCTAssertEqual(try Data(contentsOf: file), Data("{bad".utf8))
    }
}
