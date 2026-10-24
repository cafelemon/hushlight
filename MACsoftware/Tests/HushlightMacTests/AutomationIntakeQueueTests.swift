import XCTest
import CryptoKit
@testable import HushlightMac

private struct IntakeKey: AutomationKeyProviding {
    func key() throws -> SymmetricKey { SymmetricKey(data: Data(repeating: 9, count: 32)) }
}

private actor IntakeInput: AutomationInputProviding {
    var batches: [String: AutomationInputBatch] = [:]
    var authorized = true
    var calls: [String] = []
    func set(_ batch: AutomationInputBatch, for ruleID: String) { batches[ruleID] = batch }
    func revoke() { authorized = false }
    func collect(rule: AutomationRule, cursor: String?) async throws -> AutomationInputBatch {
        calls.append(rule.id)
        return batches[rule.id] ?? AutomationInputBatch(items: [], nextCursor: nil)
    }
    func authorize(rule: AutomationRule) async throws {
        if !authorized { throw AutomationError.unauthorized }
    }
}

private actor IntakeAnalyzer: AutomationAnalyzing {
    var calls: [String] = []
    var alwaysFail = false
    func fail() { alwaysFail = true }
    func recover() { alwaysFail = false }
    func analyze(rule: AutomationRule, item: AutomationInputItem) async throws -> [AutomationAgentDecision] {
        calls.append("\(rule.id):\(item.sourceID)")
        if alwaysFail { throw AutomationError.unavailableInput }
        return [.init(action: .notify, title: "Result", body: "summary", confidence: 1)]
    }
}

private actor IntakeEffects: AutomationEffectDriving {
    func apply(_ decision: AutomationAgentDecision, idempotencyKey: String, resourceID: String?,
               sourceMetadata: [String: String], authorization: AutomationEffectAuthorization) async throws -> String? {
        guard await authorization.validate() else { throw AutomationError.unauthorized }
        return idempotencyKey
    }
}

private final class IntakeClock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

final class AutomationIntakeQueueTests: XCTestCase {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AutomationIntake-\(UUID().uuidString)/state.json")
    }
    private func mailRule() -> AutomationRule {
        .init(id: "mail", title: "Mail", trigger: .mailPoll(scopeID: "scope", intervalSeconds: 300),
              grantedActions: [.notify], enabled: true)
    }
    private func item(_ source: String, _ date: Date) -> AutomationInputItem {
        .init(sourceID: source, occurredAt: date, text: "private body \(source)")
    }

    func testPageAckPersistsAllEncryptedInputsAndRestartDrainsOnePerTick() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000), file = file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let input = IntakeInput(), analyzer = IntakeAnalyzer(), effects = IntakeEffects()
        await input.set(.init(items: [item("1", date), item("2", date), item("3", date)], nextCursor: "page-1"), for: "mail")
        func engine() throws -> AutomationEngine {
            try AutomationEngine(storageURL: file, keyProvider: IntakeKey(), input: input,
                analyzer: analyzer, effectDriver: effects, now: { date })
        }
        let first = try engine()
        try await first.install(rule: mailRule())
        await first.tick(paused: false)
        let snapshot = await first.snapshot()
        XCTAssertEqual(snapshot.rules[0].cursor, "page-1")
        XCTAssertEqual(snapshot.queuedInputCounts["mail"], 2)
        XCTAssertNil(snapshot.retryInputCounts["mail"])
        let firstCalls = await analyzer.calls
        XCTAssertEqual(firstCalls.count, 1)
        let disk = try AutomationStorage(url: file, keyProvider: IntakeKey()).load()
        XCTAssertEqual(disk.intakeInputs.count, 2)
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("private body"))
        let restored = try engine()
        await restored.tick(paused: false)
        let secondCalls = await analyzer.calls
        XCTAssertEqual(secondCalls.count, 2)
        await restored.tick(paused: false)
        let thirdCalls = await analyzer.calls
        XCTAssertEqual(thirdCalls.count, 3)
        XCTAssertTrue(try AutomationStorage(url: file, keyProvider: IntakeKey()).load().intakeInputs.isEmpty)
    }

    func testWeatherGetsFirstAnalysisEvenWhenMailInstalledFirst() async throws {
        let date = ISO8601DateFormatter().date(from: "2026-10-23T06:15:00+08:00")!
        let input = IntakeInput(), analyzer = IntakeAnalyzer()
        await input.set(.init(items: [item("mail-1", date)], nextCursor: "m"), for: "mail")
        await input.set(.init(items: [item("weather-1", date)], nextCursor: "w"), for: "weather")
        let engine = try AutomationEngine(storageURL: file(), keyProvider: IntakeKey(), input: input,
            analyzer: analyzer, effectDriver: IntakeEffects(), now: { date },
            localTimeZone: { TimeZone(identifier: "Asia/Shanghai")! })
        try await engine.install(rule: mailRule())
        try await engine.install(rule: .init(id: "weather", title: "Weather", trigger: .morningWeather(
            cityID: "paris", timeZoneID: "Asia/Shanghai"), grantedActions: [.notify], enabled: true))
        await engine.tick(paused: false)
        let calls = await analyzer.calls
        XCTAssertEqual(calls, ["weather:weather-1", "mail:mail-1"])
    }

    func testFailedAnalysisBacksOffThenRetainsExhaustedRetryForManualRecovery() async throws {
        let clock = IntakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let input = IntakeInput(), analyzer = IntakeAnalyzer(), file = file()
        await analyzer.fail()
        await input.set(.init(items: [item("1", clock.date), item("2", clock.date)], nextCursor: "p"), for: "mail")
        let engine = try AutomationEngine(storageURL: file, keyProvider: IntakeKey(), input: input,
            analyzer: analyzer, effectDriver: IntakeEffects(), now: { clock.date })
        try await engine.install(rule: mailRule())
        await engine.tick(paused: false)
        let firstCalls = await analyzer.calls
        XCTAssertEqual(firstCalls, ["mail:1"])
        await engine.tick(paused: false)
        let backedOffCalls = await analyzer.calls
        XCTAssertEqual(backedOffCalls.count, 1)
        clock.date.addTimeInterval(301)
        await engine.tick(paused: false)
        clock.date.addTimeInterval(301)
        await engine.tick(paused: false)
        let exhaustedCalls = await analyzer.calls
        XCTAssertEqual(exhaustedCalls, ["mail:1", "mail:1", "mail:1"])
        let exhaustedSnapshot = await engine.snapshot()
        XCTAssertEqual(exhaustedSnapshot.runs.last?.failureCode, "analysis_retry_exhausted")
        XCTAssertEqual(exhaustedSnapshot.retryInputCounts["mail"], 1)
        XCTAssertEqual(exhaustedSnapshot.queuedInputCounts["mail"], 1)
        let disk = try AutomationStorage(url: file, keyProvider: IntakeKey()).load()
        XCTAssertEqual(disk.retryInputs.count, 1)
        clock.date.addTimeInterval(301)
        await engine.tick(paused: false)
        let resumedCalls = await analyzer.calls
        XCTAssertEqual(resumedCalls.last, "mail:2")
        await analyzer.recover()
        await engine.retryPendingAnalysis()
        let recovered = await engine.snapshot()
        XCTAssertTrue(recovered.effects.contains(where: { $0.status == .succeeded }))
        XCTAssertEqual(try AutomationStorage(url: file, keyProvider: IntakeKey()).load().retryInputs.count, 1)
    }

    func testFullPageDoesNotPartiallyAckOrDrop() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000), file = file()
        let input = IntakeInput(), analyzer = IntakeAnalyzer()
        await input.set(.init(items: (0..<201).map { item("\($0)", date) }, nextCursor: "too-far"), for: "mail")
        let engine = try AutomationEngine(storageURL: file, keyProvider: IntakeKey(), input: input,
            analyzer: analyzer, effectDriver: IntakeEffects(), now: { date })
        try await engine.install(rule: mailRule())
        await engine.tick(paused: false)
        let snapshot = await engine.snapshot()
        XCTAssertNil(snapshot.rules[0].cursor)
        XCTAssertEqual(snapshot.rules[0].lastErrorCode, "input_or_analysis_incomplete")
        XCTAssertTrue(try AutomationStorage(url: file, keyProvider: IntakeKey()).load().intakeInputs.isEmpty)
        let calls = await analyzer.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testRevokedScopeBlocksSavedIntake() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000), file = file()
        let input = IntakeInput(), analyzer = IntakeAnalyzer()
        await input.set(.init(items: [item("1", date), item("2", date)], nextCursor: "p"), for: "mail")
        let engine = try AutomationEngine(storageURL: file, keyProvider: IntakeKey(), input: input,
            analyzer: analyzer, effectDriver: IntakeEffects(), now: { date })
        try await engine.install(rule: mailRule())
        await engine.tick(paused: false)
        await input.revoke()
        await engine.tick(paused: false)
        let calls = await analyzer.calls
        XCTAssertEqual(calls.count, 1)
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.rules[0].lastErrorCode, "scope_or_permission_requires_repair")
    }

    func testMorningRetryDoesNotIssueStaleAdviceAfterEight() async throws {
        let clock = IntakeClock(ISO8601DateFormatter().date(from: "2026-10-23T07:55:00+08:00")!)
        let input = IntakeInput(), analyzer = IntakeAnalyzer()
        await analyzer.fail()
        await input.set(.init(items: [item("weather", clock.date)], nextCursor: nil), for: "weather")
        let engine = try AutomationEngine(storageURL: file(), keyProvider: IntakeKey(), input: input,
            analyzer: analyzer, effectDriver: IntakeEffects(), now: { clock.date },
            localTimeZone: { TimeZone(identifier: "Asia/Shanghai")! })
        try await engine.install(rule: .init(id: "weather", title: "Weather", trigger: .morningWeather(cityID: "paris", timeZoneID: "Asia/Shanghai"), grantedActions: [.notify], enabled: true))
        await engine.tick(paused: false)
        clock.date.addTimeInterval(600)
        await analyzer.recover()
        await engine.tick(paused: false)
        await engine.retryPendingAnalysis()
        let calls = await analyzer.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testLegacyStateWithoutIntakeFieldsLoadsAsEmpty() throws {
        let state = AutomationDiskState()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        object.removeValue(forKey: "intakeInputs")
        object.removeValue(forKey: "intakeSequence")
        let decoded = try JSONDecoder().decode(AutomationDiskState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.intakeInputs.isEmpty)
        XCTAssertEqual(decoded.intakeSequence, 0)
    }
}
