import BridgeCore
import XCTest
@testable import HushlightMac

private actor QQChatPreviewBridge: BridgeService {
    var paused = false
    var calls = 0
    var started = false
    var continuation: CheckedContinuation<Void, Never>?
    var failure = false
    func snapshot() async throws -> BridgeSnapshot { .init(status: paused ? .paused : .localReady, permissions: [], recentActions: []) }
    func setPaused(_ value: Bool) async throws { paused = value }
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
    func qqChatSnapshot() async throws -> QQChatSnapshot {
        calls += 1; started = true
        await withCheckedContinuation { continuation = $0 }
        if failure { throw BridgeServiceError.notConfigured }
        return .init(conversationTitle: "Synthetic target", messages: [.init(sender: "Synthetic sender", body: "Synthetic message")], hasDraft: false, checkedAt: .distantPast)
    }
    func finish(failure: Bool = false) { self.failure = failure; continuation?.resume(); continuation = nil }
    func hasStarted() -> Bool { started }
    func count() -> Int { calls }
}

@MainActor
final class QQChatAppModelTests: XCTestCase {
    private func wait(_ bridge: QQChatPreviewBridge) async {
        for _ in 0..<1000 { if await bridge.hasStarted() { return }; await Task.yield() }
        XCTFail("Read did not start")
    }
    func testNavigationDoesNotReadAndRepeatedClickDoesNotDuplicate() async {
        let bridge = QQChatPreviewBridge(), model = AppModel(bridgeService: bridge)
        await model.refresh(); model.selectPage(.qqChat)
        let initialCalls = await bridge.count(); XCTAssertEqual(initialCalls, 0)
        let task = Task { await model.readQQChatPreview() }
        await wait(bridge)
        await model.readQQChatPreview()
        let calls = await bridge.count(); XCTAssertEqual(calls, 1)
        await bridge.finish(); await task.value
        XCTAssertEqual(model.qqChatReadback?.conversationTitle, "Synthetic target")
        model.selectPage(.overview); model.selectPage(.qqChat)
        XCTAssertNil(model.qqChatReadback)
    }
    func testLeavingOrClearingIgnoresLatePrivatePreview() async {
        for leave in [true, false] {
            let bridge = QQChatPreviewBridge(), model = AppModel(bridgeService: bridge)
            await model.refresh(); model.selectPage(.qqChat)
            let task = Task { await model.readQQChatPreview() }
            await wait(bridge)
            if leave { model.selectPage(.overview) } else { model.clearQQChatPreview() }
            await bridge.finish(); await task.value
            XCTAssertNil(model.qqChatReadback); XCTAssertNil(model.qqChatError)
        }
    }
    func testPauseThenResumeDoesNotRestoreLatePreviewAndPausedReadDoesNotStart() async {
        let bridge = QQChatPreviewBridge(), model = AppModel(bridgeService: bridge)
        await model.refresh(); model.selectPage(.qqChat)
        let task = Task { await model.readQQChatPreview() }
        await wait(bridge)
        await model.togglePause(); await model.readQQChatPreview()
        await model.togglePause(); await bridge.finish(); await task.value
        XCTAssertNil(model.qqChatReadback)
        let calls = await bridge.count(); XCTAssertEqual(calls, 1)
    }
    func testExternallyObservedPauseClearsExistingPreview() async throws {
        let bridge = QQChatPreviewBridge(), model = AppModel(bridgeService: bridge)
        await model.refresh(); model.selectPage(.qqChat)
        let task = Task { await model.readQQChatPreview() }
        await wait(bridge); await bridge.finish(); await task.value
        XCTAssertNotNil(model.qqChatReadback)
        try await bridge.setPaused(true)
        await model.refresh()
        XCTAssertTrue(model.isPaused); XCTAssertNil(model.qqChatReadback)
    }
    func testErrorDoesNotRetainOldPreviewOrLeakArbitraryDescription() async {
        let bridge = QQChatPreviewBridge(), model = AppModel(bridgeService: bridge)
        await model.refresh(); model.selectPage(.qqChat)
        let task = Task { await model.readQQChatPreview() }
        await wait(bridge); await bridge.finish(failure: true); await task.value
        XCTAssertNil(model.qqChatReadback)
        XCTAssertEqual(model.qqChatError, "无法读取QQ会话，请检查QQ窗口和辅助功能权限。")
    }
}
