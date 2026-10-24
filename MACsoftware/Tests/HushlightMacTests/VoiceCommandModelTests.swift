import Foundation
import XCTest
@testable import HushlightMac

@MainActor
final class VoiceCommandModelTests: XCTestCase {
    func testAnalysisOnlyProducesReviewAndRequiresConfirmation() async {
        let planner = VoicePlannerFixture(), executor = VoiceExecutorFixture()
        let model = VoiceCommandModel(planner: planner, executor: executor)
        model.inputChanged("读取当前音量")
        XCTAssertEqual(planner.calls, 0)
        await model.confirm()
        XCTAssertEqual(executor.calls, 0)
        await prepareAndAnalyze(model, "读取当前音量")
        XCTAssertEqual(planner.calls, 1)
        XCTAssertTrue(model.canConfirm)
        XCTAssertEqual(executor.calls, 0)
        await model.confirm()
        XCTAssertEqual(executor.calls, 1)
        XCTAssertEqual(model.result?.outcome, .succeeded)
        await model.confirm()
        XCTAssertEqual(executor.calls, 1)
    }

    func testEditedInputInvalidatesReadyProposal() async {
        let planner = VoicePlannerFixture(), executor = VoiceExecutorFixture()
        let model = VoiceCommandModel(planner: planner, executor: executor)
        await prepareAndAnalyze(model, "读取当前音量")
        model.inputChanged("改查巴黎天气")
        XCTAssertNil(model.proposal)
        XCTAssertFalse(model.canConfirm)
        await model.confirm()
        XCTAssertEqual(executor.calls, 0)
    }

    func testDelayedAnalysisCannotOverwriteNewerInput() async {
        let planner = VoicePlannerFixture(), executor = VoiceExecutorFixture()
        let model = VoiceCommandModel(planner: planner, executor: executor)
        model.inputChanged("旧输入")
        model.inputChanged("新输入")
        await model.analyze(text: "旧输入")
        XCTAssertEqual(planner.calls, 0)
        XCTAssertNil(model.proposal)
        await prepareAndAnalyze(model, "新输入")
        XCTAssertEqual(planner.calls, 1)
    }

    func testCurrentSourceProviderRecheckedBeforeConfirmation() async {
        let planner = VoicePlannerFixture(), executor = VoiceExecutorFixture()
        var actualText = "读取当前音量"
        let model = VoiceCommandModel(planner: planner, executor: executor, inputProvider: { actualText })
        await prepareAndAnalyze(model, actualText)
        actualText = "已改为另一条输入"
        XCTAssertFalse(model.canConfirm)
        await model.confirm()
        XCTAssertEqual(executor.calls, 0)
    }

    func testPauseCancelsAnalysisAndDropsLateProposal() async {
        let planner = VoicePlannerFixture(), executor = VoiceExecutorFixture()
        planner.hold = true
        let model = VoiceCommandModel(planner: planner, executor: executor)
        let pending = Task { await prepareAndAnalyze(model, "读取当前音量") }
        await planner.waitUntilHeld()
        model.setPaused(true)
        planner.finish()
        await pending.value
        XCTAssertTrue(planner.cancelled)
        XCTAssertNil(model.proposal)
        XCTAssertFalse(model.canConfirm)
        XCTAssertEqual(executor.calls, 0)
    }

    func testRepeatedClickAndSourceChangeBeforeAdmission() async {
        let planner = VoicePlannerFixture(), executor = VoiceExecutorFixture()
        executor.hold = true
        let model = VoiceCommandModel(planner: planner, executor: executor)
        await prepareAndAnalyze(model, "读取当前音量")
        let pending = Task { await model.confirm() }
        await executor.waitUntilHeld()
        await model.confirm()
        model.inputChanged("另一条输入")
        executor.finish()
        await pending.value
        XCTAssertEqual(executor.calls, 1)
        XCTAssertFalse(executor.authorized)
        XCTAssertEqual(model.result?.outcome, .denied)
    }

    func testAlreadyAdmittedOutcomeSurvivesNavigationAndPause() async {
        let planner = VoicePlannerFixture(), executor = VoiceExecutorFixture()
        executor.hold = true
        executor.authorizeBeforeHold = true
        let model = VoiceCommandModel(planner: planner, executor: executor)
        await prepareAndAnalyze(model, "读取当前音量")
        let pending = Task { await model.confirm() }
        await executor.waitUntilHeld()
        XCTAssertTrue(executor.authorized)
        model.invalidatePlanning()
        model.setPaused(true)
        executor.finish()
        await pending.value
        XCTAssertEqual(model.result?.outcome, .succeeded)
        XCTAssertFalse(model.canConfirm)
    }

    func testExpiredAndUnsupportedProposalsNeverExecute() async {
        let planner = VoicePlannerFixture(), executor = VoiceExecutorFixture(), clock = VoiceClockFixture()
        let model = VoiceCommandModel(planner: planner, executor: executor, now: { clock.value })
        await prepareAndAnalyze(model, "读取当前音量")
        clock.value = clock.value.addingTimeInterval(301)
        await model.confirm()
        XCTAssertEqual(executor.calls, 0)
        XCTAssertNotNil(model.error)
        planner.action = .unsupported(reason: "当前范围不支持")
        await prepareAndAnalyze(model, "发送消息")
        XCTAssertFalse(model.canConfirm)
        await model.confirm()
        XCTAssertEqual(executor.calls, 0)
    }

    func testAcknowledgementDoesNotReplayUnknownAction() async {
        let planner = VoicePlannerFixture(), executor = VoiceExecutorFixture()
        executor.outcome = .unknown
        let model = VoiceCommandModel(planner: planner, executor: executor)
        await prepareAndAnalyze(model, "读取当前音量")
        await model.confirm()
        let id = try! XCTUnwrap(executor.lastID)
        executor.uncertain = [id]
        await model.refreshUncertainTimers()
        XCTAssertEqual(model.unresolvedTimerIDs, [id])
        await model.acknowledgeUnknown(id)
        XCTAssertTrue(model.unresolvedTimerIDs.isEmpty)
        await model.confirm()
        XCTAssertEqual(executor.calls, 1)
    }
}

@MainActor
private final class VoiceClockFixture { var value = Date() }

@MainActor
private final class VoicePlannerFixture: VoiceCommandPlanning {
    var calls = 0
    var hold = false
    var cancelled = false
    var action: VoiceCommandAction = .volumeRead
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func propose(text: String) async throws -> VoiceCommandAction {
        calls += 1
        if hold {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                waiter?.resume(); waiter = nil
            }
        }
        cancelled = Task.isCancelled
        return action
    }
    func waitUntilHeld() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class VoiceExecutorFixture: VoiceCommandExecuting {
    var calls = 0
    var hold = false
    var authorizeBeforeHold = false
    var authorized = false
    var outcome: VoiceCommandOutcome = .succeeded
    var lastID: UUID?
    var uncertain: [UUID] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func execute(id: UUID, action: VoiceCommandAction, authorize: @escaping @Sendable () async -> Bool) async -> VoiceCommandExecutionResult {
        calls += 1
        lastID = id
        if authorizeBeforeHold { authorized = await authorize() }
        if hold {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                waiter?.resume(); waiter = nil
            }
        }
        if !authorizeBeforeHold { authorized = await authorize() }
        return .init(id: id, outcome: authorized ? outcome : .denied, message: "测试结果", completedAt: Date(), isSimulation: false, timerID: nil)
    }
    func unresolvedTimerIDs() async -> [UUID] { uncertain }
    func acknowledgeUnknown(id: UUID) async -> Bool { uncertain.removeAll { $0 == id }; return true }
    func waitUntilHeld() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
}

@MainActor
private func prepareAndAnalyze(_ model: VoiceCommandModel, _ text: String) async {
    model.inputChanged(text)
    await model.analyze(text: text)
}

extension VoiceCommandModelTests {
    func testExplicitSongExecutesWithoutConfirmationAndBlocksRepeatedClick() async {
        let planner = VoicePlannerFixture(),executor = VoiceExecutorFixture()
        planner.action = .songPlay(.init(title:"Synthetic",artist:nil));executor.hold = true
        let model = VoiceCommandModel(planner:planner,executor:executor)
        let task = Task { await prepareAndAnalyze(model,"播放Synthetic") }
        await executor.waitUntilHeld()
        await model.analyze(text:"播放Synthetic")
        await model.confirm()
        XCTAssertEqual(executor.calls,1)
        XCTAssertFalse(model.canConfirm)
        executor.finish();await task.value
        XCTAssertEqual(model.result?.outcome,.succeeded)
        XCTAssertTrue(executor.authorized)
    }
    func testSongLateAnalysisAndPreAdmissionInputChangeCannotPlay() async {
        let planner = VoicePlannerFixture(),executor = VoiceExecutorFixture()
        planner.action = .songPlay(.init(title:"Synthetic",artist:nil));planner.hold = true
        let model = VoiceCommandModel(planner:planner,executor:executor)
        let old = Task { await prepareAndAnalyze(model,"播放Synthetic") }
        await planner.waitUntilHeld();model.inputChanged("不要播放");planner.finish();await old.value
        XCTAssertEqual(executor.calls,0)
        planner.hold = false;executor.hold = true
        let next = Task { await prepareAndAnalyze(model,"播放Synthetic") }
        await executor.waitUntilHeld();model.setPaused(true);executor.finish();await next.value
        XCTAssertEqual(model.result?.outcome,.denied)
        XCTAssertFalse(executor.authorized)
    }
}
