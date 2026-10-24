import Foundation
import XCTest
import BridgeCore
@testable import HushlightMac

private actor IncrementalFakeRunner: MailScopeScriptRunning {
    var rows: [[String]] = []
    var polls = 0
    var since: Date?
    var until: Date?
    var afterID: UInt64?
    func configure(_ rows: [[String]]) { self.rows = rows }
    func run(operation: String, scope: MailScopeKey?) async throws -> [[String]] {
        if operation == "list" || operation == "verify" { return [["account", "Account", "a@example.com", "Inbox"]] }
        return []
    }
    func incremental(scope: MailScopeKey, since: Date, until: Date, afterID: UInt64) async throws -> [[String]] {
        polls += 1
        self.since = since
        self.until = until
        self.afterID = afterID
        let matching = rows.filter {
            guard let id = UInt64($0[0]), let epoch = Double($0[3]) else { return false }
            return id > afterID && epoch > since.timeIntervalSince1970 && epoch <= until.timeIntervalSince1970
        }.sorted { UInt64($0[0])! < UInt64($1[0])! }
        return [["page", matching.count > 10 ? "1" : "0"]] + Array(matching.prefix(10))
    }
    func count() -> Int { polls }
    func cutoff() -> Date? { since }
}

final class MailIncrementalBackendTests: XCTestCase {
    private func fixture() async throws -> (AppleMailScopeBackend, IncrementalFakeRunner, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-incremental-\(UUID())")
        let runner = IncrementalFakeRunner()
        let backend = AppleMailScopeBackend(storageURL: root.appendingPathComponent("scope.json"), runner: runner)
        try await backend.choose(.init(accountID: "account", mailboxPath: ["Inbox"]))
        return (backend, runner, root)
    }

    func testBaselineDoesNotScanAndCursorWaitsForCallerAcknowledgement() async throws {
        let (backend, runner, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = try await backend.makeIncrementalBaseline(now: Date(timeIntervalSince1970: 1_700_000_000))
        let initialCount = await runner.count()
        XCTAssertEqual(initialCount, 0)
        await runner.configure([["41", "Earlier", "Sender", "1699999999", "1"],
                                ["42", "New", "Sender", "1700000010", "1"]])
        let first = try await backend.pollIncremental(after: baseline, now: Date(timeIntervalSince1970: 1_700_000_020))
        XCTAssertEqual(first.messages.map(\.subject), ["New"])
        let firstCount = await runner.count()
        let cutoff = await runner.cutoff()
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(cutoff, Date(timeIntervalSince1970: 1_699_999_880))
        let replay = try await backend.pollIncremental(after: baseline, now: Date(timeIntervalSince1970: 1_700_000_020))
        XCTAssertEqual(replay.messages.map(\.id), first.messages.map(\.id))
        let acknowledged = try await backend.pollIncremental(after: first.nextCursor, now: Date(timeIntervalSince1970: 1_700_000_021))
        XCTAssertTrue(acknowledged.messages.isEmpty)
    }

    func testPageAndScopeMismatch() async throws {
        let (backend, runner, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = try await backend.makeIncrementalBaseline(now: Date(timeIntervalSince1970: 1_700_000_000))
        await runner.configure((1...201).map { [String($0), "Hello", "Sender", "1700000010", "1"] })
        let first = try await backend.pollIncremental(after: baseline, now: Date(timeIntervalSince1970: 1_700_000_020))
        XCTAssertEqual(first.messages.count, 10)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.nextCursor.watermark, baseline.watermark)
        XCTAssertEqual(first.nextCursor.pending?.afterID, 10)
        let second = try await backend.pollIncremental(after: first.nextCursor, now: Date(timeIntervalSince1970: 1_700_000_021))
        XCTAssertEqual(second.messages.first?.id.hasSuffix(".11"), true)
        XCTAssertEqual(second.nextCursor.pending?.until, first.nextCursor.pending?.until)
        let wrong = MailIncrementalCursor(scopeID: "wrong", baselineAt: baseline.baselineAt,
                                          watermark: baseline.watermark, recent: [])
        do { _ = try await backend.pollIncremental(after: wrong); XCTFail("Wrong scope") }
        catch MailScopeError.invalidScope {}
        let count = await runner.count()
        XCTAssertEqual(count, 2)
    }

    func testSameTimestampBacklogCompletesWithoutAdvancingWindowEarly() async throws {
        let (backend, runner, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = try await backend.makeIncrementalBaseline(now: Date(timeIntervalSince1970: 1_700_000_000))
        await runner.configure((1...201).reversed().map { [String($0), "Same second", "Sender", "1700000010", "1"] })
        var cursor = baseline
        var delivered: [String] = []
        for page in 0..<21 {
            let poll = try await backend.pollIncremental(after: cursor,
                now: Date(timeIntervalSince1970: 1_700_000_020 + Double(page)))
            delivered += poll.messages.map(\.id)
            cursor = poll.nextCursor
            if page < 20 {
                XCTAssertTrue(poll.hasMore)
                XCTAssertEqual(cursor.watermark, baseline.watermark)
                XCTAssertEqual(cursor.pending?.until, Date(timeIntervalSince1970: 1_700_000_020))
            } else {
                XCTAssertFalse(poll.hasMore)
                XCTAssertNil(cursor.pending)
                XCTAssertEqual(cursor.watermark, Date(timeIntervalSince1970: 1_700_000_020))
            }
        }
        XCTAssertEqual(Set(delivered).count, 201)
        XCTAssertEqual(delivered.count, 201)
        let replay = try await backend.pollIncremental(after: cursor, now: Date(timeIntervalSince1970: 1_700_000_050))
        XCTAssertTrue(replay.messages.isEmpty)
    }

    func testLegacyCursorDecodesWithoutPendingWindow() async throws {
        let (backend, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = try await backend.makeIncrementalBaseline(now: Date(timeIntervalSince1970: 1_700_000_000))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(baseline)) as? [String: Any])
        object.removeValue(forKey: "pending")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(MailIncrementalCursor.self, from: legacy)
        XCTAssertNil(decoded.pending)
        XCTAssertEqual(decoded.watermark, baseline.watermark)
    }

    func testOverlapKeepsMoreThanFiveHundredIDsAndRejectsRetentionOverflow() async throws {
        let (backend, runner, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = try await backend.makeIncrementalBaseline(now: Date(timeIntervalSince1970: 1_700_000_000))
        let seen = (1...500).map { MailIncrementalSeen(id: "mail.\(baseline.scopeID).\($0)",
                                                        receivedAt: Date(timeIntervalSince1970: 1_700_000_010)) }
        let cursor = MailIncrementalCursor(scopeID: baseline.scopeID, baselineAt: baseline.baselineAt,
                                           watermark: baseline.baselineAt, recent: seen)
        await runner.configure([["1", "Repeated", "Sender", "1700000010", "1"],
                                ["501", "Fresh", "Sender", "1700000010", "1"]])
        let poll = try await backend.pollIncremental(after: cursor, now: Date(timeIntervalSince1970: 1_700_000_020))
        XCTAssertEqual(poll.messages.map(\.subject), ["Fresh"])
        XCTAssertEqual(poll.nextCursor.recent.count, 501)

        let full = (1...20_000).map { MailIncrementalSeen(id: "mail.\(baseline.scopeID).\($0)",
                                                         receivedAt: Date(timeIntervalSince1970: 1_700_000_010)) }
        let fullCursor = MailIncrementalCursor(scopeID: baseline.scopeID, baselineAt: baseline.baselineAt,
                                               watermark: baseline.baselineAt, recent: full)
        await runner.configure([["20001", "Overflow", "Sender", "1700000010", "1"]])
        do { _ = try await backend.pollIncremental(after: fullCursor, now: Date(timeIntervalSince1970: 1_700_000_020)); XCTFail("Must not drop dedupe state") }
        catch MailScopeError.capacityExceeded {}
    }
}
