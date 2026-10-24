import XCTest
import CryptoKit
@testable import HushlightMac

private struct ManualWeatherKey: AutomationKeyProviding {
    func key() throws -> SymmetricKey { SymmetricKey(data: Data(repeating: 23, count: 32)) }
}
private final class ManualWeatherClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var date: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
private actor ManualWeatherInput: AutomationInputProviding {
    let clock: ManualWeatherClock
    var calls = 0
    init(_ clock: ManualWeatherClock) { self.clock = clock }
    func collect(rule: AutomationRule, cursor: String?) async throws -> AutomationInputBatch {
        calls += 1
        return .init(items: [.init(sourceID: "weather.paris.2026-10-24", occurredAt: clock.date,
            text: "Public synthetic forecast", metadata: ["day": "2026-10-24"])], nextCursor: "scheduled-cursor")
    }
}
private actor ManualWeatherAnalyzer: AutomationAnalyzing {
    let clock: ManualWeatherClock
    var delayed = false, started = false
    var needsApproval = false
    func requireApproval() { needsApproval = true }
    var continuation: CheckedContinuation<Void, Never>?
    var waiter: CheckedContinuation<Void, Never>?
    init(_ clock: ManualWeatherClock) { self.clock = clock }
    func hold() { delayed = true }
    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
    func analyze(rule: AutomationRule, item: AutomationInputItem) async throws -> [AutomationAgentDecision] {
        if delayed {
            started = true; waiter?.resume(); waiter = nil
            await withCheckedContinuation { continuation = $0 }
        }
        return rule.grantedActions.sorted(by: { $0.rawValue < $1.rawValue }).map {
            .init(action: $0, title: "Public forecast", body: "Bring an umbrella", confidence: 1, requiresApproval: needsApproval)
        }
    }
}
private actor ManualWeatherEffects: AutomationEffectDriving {
    var actions: [AutomationAction] = []
    var unknownNote = false
    var expireClock: ManualWeatherClock?
    func expireBeforeWrite(_ clock: ManualWeatherClock) { expireClock = clock }
    func failNote() { unknownNote = true }
    func apply(_ decision: AutomationAgentDecision, idempotencyKey: String, resourceID: String?,
               sourceMetadata: [String: String], authorization: AutomationEffectAuthorization) async throws -> String? {
        if let expireClock { expireClock.advance(901); self.expireClock = nil }
        guard await authorization.validate() else { throw AutomationError.unauthorized }
        actions.append(decision.action)
        if decision.action == .appendDailyNote, unknownNote { throw AutomationError.unavailableInput }
        return idempotencyKey
    }
}

final class AutomationManualWeatherTests: XCTestCase {
    private let zone = TimeZone(secondsFromGMT: 0)!
    private func date(_ time: String = "12:00") -> Date {
        ISO8601DateFormatter().date(from: "2026-10-24T\(time):00Z")!
    }
    private func rule(enabled: Bool = true, note: Bool = true) -> AutomationRule {
        .init(id: "weather", title: "Weather", trigger: .morningWeather(cityID: "paris", timeZoneID: "Europe/Paris"),
              grantedActions: note ? [.notify, .appendDailyNote] : [.notify],
              resourceIDs: note ? [.appendDailyNote: "owned-folder"] : [:], enabled: enabled)
    }
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ManualWeather-\(UUID().uuidString)/state.json")
    }
    private func engine(_ file: URL, _ clock: ManualWeatherClock, _ input: ManualWeatherInput,
                        _ analyzer: ManualWeatherAnalyzer, _ effects: ManualWeatherEffects) throws -> AutomationEngine {
        try AutomationEngine(storageURL: file, keyProvider: ManualWeatherKey(), input: input,
            analyzer: analyzer, effectDriver: effects, now: { clock.date }, localTimeZone: { TimeZone(secondsFromGMT: 0)! })
    }
    func testNoonTrialPersistsAndNeverReplaysAfterDuplicateOrRestart() async throws {
        let f = file(); defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        let clock = ManualWeatherClock(date()), input = ManualWeatherInput(clock)
        let analyzer = ManualWeatherAnalyzer(clock), effects = ManualWeatherEffects()
        let core = try engine(f, clock, input, analyzer, effects)
        try await core.install(rule: rule())
        await core.setPaused(false)
        try await core.runWeatherNow(ruleID: "weather")
        let snapshot = await core.snapshot()
        XCTAssertEqual(snapshot.effects.count, 2)
        XCTAssertTrue(snapshot.effects.allSatisfy { $0.status == .succeeded })
        XCTAssertTrue(snapshot.runs.allSatisfy { $0.scheduleNote == "manual_weather_check" })
        XCTAssertNil(snapshot.rules[0].lastPolledAt)
        XCTAssertNil(snapshot.rules[0].cursor)
        do { try await core.runWeatherNow(ruleID: "weather"); XCTFail("Duplicate admitted") }
        catch { XCTAssertEqual(error as? AutomationError, .duplicate) }
        let restored = try engine(f, clock, input, analyzer, effects)
        await restored.setPaused(false)
        do { try await restored.runWeatherNow(ruleID: "weather"); XCTFail("Restart replayed") }
        catch { XCTAssertEqual(error as? AutomationError, .duplicate) }
        let actions = await effects.actions, calls = await input.calls
        XCTAssertEqual(actions.count, 2); XCTAssertEqual(calls, 1)
    }
    func testTrialBeforeSixDoesNotConsumeScheduledWeatherAndNotifyOnlyStaysScoped() async throws {
        let f = file(); defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        let clock = ManualWeatherClock(date("05:30")), input = ManualWeatherInput(clock)
        let effects = ManualWeatherEffects(), analyzer = ManualWeatherAnalyzer(clock)
        let core = try engine(f, clock, input, analyzer, effects)
        try await core.install(rule: rule(note: false)); await core.setPaused(false)
        try await core.runWeatherNow(ruleID: "weather")
        clock.advance(1800); await core.tick(paused: false); await core.tick(paused: false)
        let actions = await effects.actions, snapshot = await core.snapshot()
        XCTAssertEqual(actions, [.notify, .notify])
        XCTAssertEqual(Set(snapshot.runs.map(\.sourceID)).count, 2)
        XCTAssertEqual(snapshot.rules[0].cursor, "scheduled-cursor")
    }
    func testPausedDisabledAndMailRulesCannotBeInvokedAsWeather() async throws {
        let f = file(); defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        let clock = ManualWeatherClock(date()), input = ManualWeatherInput(clock)
        let core = try engine(f, clock, input, ManualWeatherAnalyzer(clock), ManualWeatherEffects())
        try await core.install(rule: rule(enabled: false))
        do { try await core.runWeatherNow(ruleID: "weather"); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .unauthorized) }
        await core.setPaused(false)
        do { try await core.runWeatherNow(ruleID: "weather"); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .invalidRule) }
        try await core.install(rule: .init(id: "mail", title: "Mail", trigger: .mailPoll(scopeID: "scope", intervalSeconds: 300), grantedActions: [.notify], enabled: true))
        do { try await core.runWeatherNow(ruleID: "mail"); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .invalidRule) }
        let calls = await input.calls; XCTAssertEqual(calls, 0)
    }
    func testPauseDuringAnalysisInvalidatesAndConcurrentInvocationIsRejected() async throws {
        let f = file(); defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        let clock = ManualWeatherClock(date()), input = ManualWeatherInput(clock)
        let analyzer = ManualWeatherAnalyzer(clock), effects = ManualWeatherEffects()
        await analyzer.hold()
        let core = try engine(f, clock, input, analyzer, effects)
        try await core.install(rule: rule()); await core.setPaused(false)
        let first = Task { try await core.runWeatherNow(ruleID: "weather") }
        await analyzer.waitForStart()
        do { try await core.runWeatherNow(ruleID: "weather"); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .runInProgress) }
        await core.tick(paused: false)
        await core.setPaused(true); await analyzer.finish()
        do { try await first.value; XCTFail() } catch {}
        let actions = await effects.actions, calls = await input.calls
        let state = await core.snapshot()
        XCTAssertTrue(state.rules[0].enabled)
        XCTAssertTrue(actions.isEmpty); XCTAssertEqual(calls, 1)
    }
    func testAnalysisPastFifteenMinutesCannotWriteOrRetryStaleAdvice() async throws {
        let f = file(); defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        let clock = ManualWeatherClock(date()), input = ManualWeatherInput(clock)
        let analyzer = ManualWeatherAnalyzer(clock), effects = ManualWeatherEffects()
        await analyzer.hold()
        let core = try engine(f, clock, input, analyzer, effects)
        try await core.install(rule: rule()); await core.setPaused(false)
        let task = Task { try await core.runWeatherNow(ruleID: "weather") }
        await analyzer.waitForStart(); clock.advance(901); await analyzer.finish()
        do { try await task.value; XCTFail() } catch {}
        await core.retryPendingAnalysis()
        let actions = await effects.actions; XCTAssertTrue(actions.isEmpty)
        let state = await core.snapshot(); XCTAssertTrue(state.rules[0].enabled)
    }
    func testUnknownPartialEffectNeverReplaysAndOtherGrantedEffectCompletes() async throws {
        let f = file(); defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        let clock = ManualWeatherClock(date()), input = ManualWeatherInput(clock)
        let analyzer = ManualWeatherAnalyzer(clock), effects = ManualWeatherEffects()
        await effects.failNote()
        let core = try engine(f, clock, input, analyzer, effects)
        try await core.install(rule: rule()); await core.setPaused(false)
        try await core.runWeatherNow(ruleID: "weather")
        let snapshot = await core.snapshot()
        XCTAssertEqual(Set(snapshot.effects.map(\.status)), [.succeeded, .unknown])
        let restored = try engine(f, clock, input, analyzer, effects)
        await restored.setPaused(false); await restored.retryPendingAnalysis()
        let actions = await effects.actions; XCTAssertEqual(actions.count, 2)
    }
    func testFinalEffectLeaseChecksDeadlineAfterReservation() async throws {
        let f = file(); defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        let clock = ManualWeatherClock(date()), input = ManualWeatherInput(clock)
        let effects = ManualWeatherEffects()
        await effects.expireBeforeWrite(clock)
        let core = try engine(f, clock, input, ManualWeatherAnalyzer(clock), effects)
        try await core.install(rule: rule(note: false)); await core.setPaused(false)
        try await core.runWeatherNow(ruleID: "weather")
        let state = await core.snapshot(), actions = await effects.actions
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(state.effects.first?.status, .rejected)
        XCTAssertTrue(state.rules[0].enabled)
    }
    func testMidnightAnalysisCannotWriteYesterdaysAdvice() async throws {
        let f = file(); defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        let clock = ManualWeatherClock(date("23:59")), input = ManualWeatherInput(clock)
        let analyzer = ManualWeatherAnalyzer(clock), effects = ManualWeatherEffects()
        await analyzer.hold()
        let core = try engine(f, clock, input, analyzer, effects)
        try await core.install(rule: rule()); await core.setPaused(false)
        let task = Task { try await core.runWeatherNow(ruleID: "weather") }
        await analyzer.waitForStart(); clock.advance(61); await analyzer.finish()
        do { try await task.value; XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .staleInput) }
        let state = await core.snapshot(), actions = await effects.actions
        XCTAssertTrue(actions.isEmpty); XCTAssertTrue(state.rules[0].enabled)
        XCTAssertEqual(state.runs.first?.failureCode, "weather_input_expired")
    }

    func testPendingManualAdviceExpiresWithFifteenMinuteDeadline() async throws {
        let f = file(); defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        let clock = ManualWeatherClock(date()), input = ManualWeatherInput(clock)
        let analyzer = ManualWeatherAnalyzer(clock), effects = ManualWeatherEffects()
        await analyzer.requireApproval()
        let core = try engine(f, clock, input, analyzer, effects)
        try await core.install(rule: rule(note: false)); await core.setPaused(false)
        try await core.runWeatherNow(ruleID: "weather")
        let pending = try await core.pendingReview()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].expiresAt, clock.date.addingTimeInterval(900))
        clock.advance(901)
        do { try await core.resolve(runID: pending[0].runID, approve: true); XCTFail() }
        catch { XCTAssertEqual(error as? AutomationError, .expiredApproval) }
        let remaining = try await core.pendingReview(), actions = await effects.actions
        XCTAssertTrue(remaining.isEmpty); XCTAssertTrue(actions.isEmpty)
        let state = await core.snapshot(); XCTAssertTrue(state.rules[0].enabled)
    }

}
