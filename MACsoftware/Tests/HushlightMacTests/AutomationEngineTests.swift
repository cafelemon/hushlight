import XCTest
import CryptoKit
import BridgeCore
@testable import HushlightMac

private struct TestAutomationKey: AutomationKeyProviding {
    func key() throws -> SymmetricKey { SymmetricKey(data: Data(repeating: 7, count: 32)) }
}

private actor TestAutomationInput: AutomationInputProviding {
    var calls = 0
    let item: AutomationInputItem
    init(_ item: AutomationInputItem) { self.item = item }
    func collect(rule: AutomationRule, cursor: String?) async throws -> AutomationInputBatch {
        calls += 1
        return AutomationInputBatch(items: [item], nextCursor: "cursor-1")
    }
}

private struct TestAutomationAnalyzer: AutomationAnalyzing {
    let decisions: [AutomationAgentDecision]
    func analyze(rule: AutomationRule, item: AutomationInputItem) async throws -> [AutomationAgentDecision] { decisions }
}

private actor FlakyAutomationAnalyzer: AutomationAnalyzing {
    var calls = 0
    func analyze(rule: AutomationRule, item: AutomationInputItem) async throws -> [AutomationAgentDecision] {
        calls += 1
        if calls == 1 { throw CodexAutomationError.unavailable }
        return [.init(action: .notify, title: "Mail", body: "Important", confidence: 1)]
    }
}

private actor TestAutomationEffect: AutomationEffectDriving {
    var calls = 0
    func apply(_ decision: AutomationAgentDecision, idempotencyKey: String, resourceID: String?,
               sourceMetadata: [String: String], authorization: AutomationEffectAuthorization) async throws -> String? {
        guard await authorization.validate() else { throw AutomationError.unauthorized }
        calls += 1
        return idempotencyKey
    }
}

private actor DelayedAutomationEffect: AutomationEffectDriving {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false
    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
    func apply(_ decision: AutomationAgentDecision, idempotencyKey: String, resourceID: String?,
               sourceMetadata: [String: String], authorization: AutomationEffectAuthorization) async throws -> String? {
        guard await authorization.validate() else { throw AutomationError.unauthorized }
        didStart = true
        started?.resume(); started = nil
        await withCheckedContinuation { continuation = $0 }
        return idempotencyKey
    }
}

private actor PagedAutomationInput: AutomationInputProviding {
    var calls = 0
    var failNext = false
    func failOnce() { failNext = true }
    func count() -> Int { calls }
    func collect(rule: AutomationRule, cursor: String?) async throws -> AutomationInputBatch {
        calls += 1
        if failNext { failNext = false; throw AutomationError.unavailableInput }
        return AutomationInputBatch(items: [], nextCursor: "page-\(calls)", hasMore: calls == 1)
    }
}

final class AutomationEngineTests: XCTestCase {
    func testBacklogResumesAfterRestartButFailureKeepsFiveMinuteBackoff() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let file = url()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let input = PagedAutomationInput()
        func makeEngine() throws -> AutomationEngine {
            try AutomationEngine(storageURL: file, keyProvider: TestAutomationKey(), input: input,
                analyzer: TestAutomationAnalyzer(decisions: []), effectDriver: TestAutomationEffect(), now: { clock.date })
        }
        let engine = try makeEngine()
        try await engine.install(rule: AutomationRule(id: "mail-pages", title: "Mail", trigger: .mailPoll(scopeID: "test", intervalSeconds: 300), grantedActions: [.notify], enabled: true))
        await engine.tick(paused: false)
        let first = await engine.snapshot()
        XCTAssertTrue(first.rules[0].moreInputPending)
        let restored = try makeEngine()
        clock.date.addTimeInterval(16)
        await input.failOnce()
        await restored.tick(paused: false)
        let afterFailure = await input.count()
        XCTAssertEqual(afterFailure, 2)
        clock.date.addTimeInterval(16)
        await restored.tick(paused: false)
        let backedOff = await input.count()
        XCTAssertEqual(backedOff, 2)
        clock.date.addTimeInterval(300)
        await restored.tick(paused: false)
        let completed = await restored.snapshot()
        XCTAssertFalse(completed.rules[0].moreInputPending)
        XCTAssertEqual(completed.rules[0].cursor, "page-3")
        clock.date.addTimeInterval(16)
        await restored.tick(paused: false)
        let idle = await input.count()
        XCTAssertEqual(idle, 3)
    }

    private func url() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AutomationTests-\(UUID().uuidString)/state.json")
    }

    func testWeatherRunsOnlyOnceForSameSourceAndCommitsCursor() async throws {
        let date = ISO8601DateFormatter().date(from: "2026-10-23T06:15:00+08:00")!
        let input = TestAutomationInput(.init(sourceID: "weather:Paris:2026-10-23", occurredAt: date,
                                              text: "Paris, 12C"))
        let effect = TestAutomationEffect()
        let rule = AutomationRule(id: "morning", title: "Weather", trigger: .morningWeather(
            cityID: "Paris", timeZoneID: "Asia/Shanghai"), grantedActions: [.notify], enabled: true)
        let engine = try AutomationEngine(storageURL: url(), keyProvider: TestAutomationKey(), input: input,
            analyzer: TestAutomationAnalyzer(decisions: [.init(action: .notify, title: "天气", body: "12C", confidence: 1)]),
            effectDriver: effect, now: { date }, localTimeZone: { TimeZone(identifier: "Asia/Shanghai")! })
        try await engine.install(rule: rule)
        await engine.tick(paused: false)
        await engine.tick(paused: false)
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.runs.count, 1)
        XCTAssertEqual(snapshot.effects.count, 1)
        XCTAssertEqual(snapshot.effects.first?.status, .succeeded)
        XCTAssertEqual(snapshot.rules.first?.cursor, "cursor-1")
        let calls = await effect.calls
        XCTAssertEqual(calls, 1)
    }

    func testPendingPayloadEncryptedAndExpiresAfterSevenDays() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TestClock(date)
        let file = url()
        let input = TestAutomationInput(.init(sourceID: "mail-1", occurredAt: date, text: "Meet at 9 AM UTC 2027-01-01"))
        let rule = AutomationRule(id: "mail", title: "Mail", trigger: .mailPoll(scopeID: "scope", intervalSeconds: 300),
                                  grantedActions: [.createCalendar], resourceIDs: [.createCalendar: "calendar-1"], enabled: true)
        let decision = AutomationAgentDecision(action: .createCalendar, title: "Meeting", body: "secret-body",
            confidence: 1, sourceExcerpt: "Meet at 9 AM UTC 2027-01-01", eventAt: date.addingTimeInterval(3600),
            timeZoneID: "UTC", requiresApproval: true)
        let engine = try AutomationEngine(storageURL: file, keyProvider: TestAutomationKey(), input: input,
            analyzer: TestAutomationAnalyzer(decisions: [decision]), effectDriver: TestAutomationEffect(), now: { clock.date })
        try await engine.install(rule: rule)
        await engine.tick(paused: false)
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.runs.first?.status, .pendingApproval)
        let bytes = try Data(contentsOf: file)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("secret-body"))
        clock.date = date.addingTimeInterval(7 * 24 * 3600 + 1)
        do { try await engine.resolve(runID: snapshot.runs[0].id, approve: true); XCTFail("Expired") }
        catch AutomationError.expiredApproval {}
    }

    func testCodexRunnerDisablesModelTools() {
        let args = CodexAutomationRunner.fixedArguments
        XCTAssertTrue(args.contains("features.shell_tool=false"))
        XCTAssertTrue(args.contains("features.apps=false"))
        XCTAssertTrue(args.contains("web_search=\"disabled\""))
        XCTAssertTrue(args.contains("--ignore-user-config"))
        XCTAssertTrue(args.contains("--ignore-rules"))
        XCTAssertTrue(args.contains("--ephemeral"))
    }

    func testLateEffectResultAfterPauseRemainsUnknownAndIsNotReplayed() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let delayed = DelayedAutomationEffect()
        let engine = try AutomationEngine(storageURL: url(), keyProvider: TestAutomationKey(),
            input: TestAutomationInput(.init(sourceID: "mail-2", occurredAt: date, text: "Important")),
            analyzer: TestAutomationAnalyzer(decisions: [.init(action: .notify, title: "Mail", body: "Important", confidence: 1)]),
            effectDriver: delayed, now: { date })
        try await engine.install(rule: .init(id: "mail", title: "Mail", trigger: .mailPoll(scopeID: "scope", intervalSeconds: 300),
                                             grantedActions: [.notify], enabled: true))
        let task = Task { await engine.tick(paused: false) }
        await delayed.waitUntilStarted()
        await engine.setPaused(true)
        await delayed.finish()
        await task.value
        let result = await engine.snapshot()
        XCTAssertEqual(result.effects.first?.status, .unknown)
        XCTAssertEqual(result.runs.first?.status, .unknown)
        await engine.tick(paused: false)
        let again = await engine.snapshot()
        XCTAssertEqual(again.effects.count, 1)
    }

    func testFailedAnalysisRetriesFromEncryptedInputWithoutDuplicateEffect() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let file = url()
        let analyzer = FlakyAutomationAnalyzer()
        let effect = TestAutomationEffect()
        let engine = try AutomationEngine(storageURL: file, keyProvider: TestAutomationKey(),
            input: TestAutomationInput(.init(sourceID: "mail-3", occurredAt: date, text: "private text")),
            analyzer: analyzer, effectDriver: effect, now: { date })
        try await engine.install(rule: .init(id: "mail", title: "Mail", trigger: .mailPoll(scopeID: "scope", intervalSeconds: 300),
                                             grantedActions: [.notify], enabled: true))
        await engine.tick(paused: false)
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("private text"))
        let beforeRetry = await analyzer.calls
        XCTAssertEqual(beforeRetry, 1, "Automatic retry must back off")
        await engine.retryPendingAnalysis()
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.effects.count, 1)
        XCTAssertEqual(snapshot.effects.first?.status, .succeeded)
        let calls = await analyzer.calls
        XCTAssertEqual(calls, 2)
    }

    func testOneUnknownEffectDoesNotReplayOrBlockOtherEffectsAfterRestart() async throws {
        let file = url(), date = Date(timeIntervalSince1970: 1_800_000_000)
        let driver = PartiallyFailingEffects()
        let input = TestAutomationInput(.init(sourceID: "mail-partial", occurredAt: date, text: "Important"))
        let analyzer = TestAutomationAnalyzer(decisions: [
            .init(action: .notify, title: "Important", body: "summary", confidence: 1),
            .init(action: .appendDailyNote, title: "Summary", body: "summary", confidence: 1)])
        let engine = try AutomationEngine(storageURL: file, keyProvider: TestAutomationKey(), input: input, analyzer: analyzer, effectDriver: driver, now: { date })
        try await engine.install(rule: .init(id: "mail", title: "Mail", trigger: .mailPoll(scopeID: "scope", intervalSeconds: 300),
            grantedActions: [.notify, .appendDailyNote], resourceIDs: [.appendDailyNote: "folder"], enabled: true))
        await engine.tick(paused: false)
        let first = await engine.snapshot()
        XCTAssertEqual(first.effects.map(\.status), [.unknown, .succeeded])
        let restored = try AutomationEngine(storageURL: file, keyProvider: TestAutomationKey(), input: input, analyzer: analyzer, effectDriver: driver, now: { date.addingTimeInterval(600) })
        await restored.tick(paused: false)
        let calls = await driver.calls
        XCTAssertEqual(calls, [.notify, .appendDailyNote])
    }

    func testAmbiguousEventStaysPendingAndExplicitEvidenceCreates() async throws {
        let date = ISO8601DateFormatter().date(from: "2026-10-24T09:00:00Z")!
        let text = "2026-10-24 09:00 to 10:00 UTC project review"
        let effect = TestAutomationEffect()
        let engine = try AutomationEngine(storageURL: url(), keyProvider: TestAutomationKey(),
            input: TestAutomationInput(.init(sourceID: "explicit", occurredAt: date, text: text)),
            analyzer: TestAutomationAnalyzer(decisions: [
                .init(action: .createCalendar, title: "project review", body: "Review", confidence: 1,
                      sourceExcerpt: text, eventAt: date, eventEndAt: date.addingTimeInterval(3600), timeZoneID: "UTC"),
                .init(action: .createReminder, title: "Ambiguous", body: "Tomorrow", confidence: 1)]), effectDriver: effect, now: { date })
        try await engine.install(rule: .init(id: "mail", title: "Mail", trigger: .mailPoll(scopeID: "scope", intervalSeconds: 300),
            grantedActions: [.createCalendar, .createReminder], resourceIDs: [.createCalendar: "calendar", .createReminder: "reminders"], enabled: true))
        await engine.tick(paused: false)
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.effects.count, 1)
        XCTAssertEqual(snapshot.effects.first?.action, .createCalendar)
        let pending = try await engine.pendingReview()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.decision.action, .createReminder)
    }

    func testMissedWeatherAndDuplicateRules() async throws {
        let date = ISO8601DateFormatter().date(from: "2026-10-23T08:01:00Z")!
        let input = TestAutomationInput(.init(sourceID: "unused", occurredAt: date, text: "forecast"))
        let engine = try AutomationEngine(storageURL: url(), keyProvider: TestAutomationKey(), input: input,
            analyzer: TestAutomationAnalyzer(decisions: []), effectDriver: TestAutomationEffect(), now: { date }, localTimeZone: { TimeZone(secondsFromGMT: 0)! })
        let rule = AutomationRule(id: "weather", title: "Weather", trigger: .morningWeather(cityID: "paris", timeZoneID: "Europe/Paris"), grantedActions: [.notify], enabled: true)
        try await engine.install(rule: rule)
        do {
            try await engine.install(rule: .init(id: "duplicate", title: "Weather", trigger: rule.trigger, grantedActions: [.notify], enabled: true))
            XCTFail("Duplicate active sources must reject")
        } catch AutomationError.duplicate {}
        await engine.tick(paused: false); await engine.tick(paused: false)
        let snapshot = await engine.snapshot(), calls = await input.calls
        XCTAssertEqual(snapshot.runs.count, 1)
        XCTAssertEqual(snapshot.runs.first?.failureCode, "weather_window_missed")
        XCTAssertEqual(calls, 0)
    }

    func testCancelledAnalysisDoesNotSendWeatherFallback() async throws {
        let date = ISO8601DateFormatter().date(from: "2026-10-23T06:15:00Z")!
        let city = WeatherCities.byID("paris")!
        let point = WeatherPoint(time: date, temperatureC: 12, relativeHumidityPercent: 50, windSpeedMS: 1, symbol: "rain")
        let report = WeatherReport(city: city, modelUpdatedAt: date, fetchedAt: date, current: point, hourly: [], isCached: false)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let driver = TestAutomationEffect()
        let engine = try AutomationEngine(storageURL: url(), keyProvider: TestAutomationKey(),
            input: TestAutomationInput(.init(sourceID: "weather.cancelled", occurredAt: date, text: String(decoding: try encoder.encode(report), as: UTF8.self))),
            analyzer: CancelledAutomationAnalyzer(), effectDriver: driver, now: { date }, localTimeZone: { TimeZone(secondsFromGMT: 0)! })
        try await engine.install(rule: .init(id: "weather", title: "Weather", trigger: .morningWeather(cityID: "paris", timeZoneID: "Europe/Paris"), grantedActions: [.notify], enabled: true))
        await engine.tick(paused: false)
        let snapshot = await engine.snapshot(), calls = await driver.calls
        XCTAssertEqual(snapshot.runs.first?.failureCode, "analysis_cancelled")
        XCTAssertTrue(snapshot.effects.isEmpty)
        XCTAssertEqual(calls, 0)
    }

    func testAdmissionStorageFailureDoesNotLeavePhantomRunOrAdvanceCursor() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let file = url()
        let engine = try AutomationEngine(storageURL: file, keyProvider: TestAutomationKey(),
            input: TestAutomationInput(.init(sourceID: "mail-4", occurredAt: date, text: "message")),
            analyzer: TestAutomationAnalyzer(decisions: [.init(action: .notify, title: "Mail", body: "summary", confidence: 1)]),
            effectDriver: TestAutomationEffect(), now: { date })
        try await engine.install(rule: .init(id: "mail", title: "Mail", trigger: .mailPoll(scopeID: "scope", intervalSeconds: 300),
                                             grantedActions: [.notify], enabled: true))
        let parent = file.deletingLastPathComponent()
        try FileManager.default.removeItem(at: parent)
        try Data("block directory".utf8).write(to: parent)
        await engine.tick(paused: false)
        let snapshot = await engine.snapshot()
        XCTAssertTrue(snapshot.runs.isEmpty)
        XCTAssertTrue(snapshot.effects.isEmpty)
        XCTAssertNil(snapshot.rules.first?.cursor)
    }
}

private final class TestClock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private actor PartiallyFailingEffects: AutomationEffectDriving {
    var calls: [AutomationAction] = []
    func apply(_ decision: AutomationAgentDecision, idempotencyKey: String, resourceID: String?, sourceMetadata: [String: String], authorization: AutomationEffectAuthorization) async throws -> String? {
        guard await authorization.validate() else { throw AutomationError.unauthorized }
        calls.append(decision.action)
        if decision.action == .notify { throw AutomationError.unavailableInput }
        return idempotencyKey
    }
}

private struct CancelledAutomationAnalyzer: AutomationAnalyzing {
    func analyze(rule: AutomationRule, item: AutomationInputItem) async throws -> [AutomationAgentDecision] { throw CancellationError() }
}
