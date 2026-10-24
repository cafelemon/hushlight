import BridgeCore
import XCTest
@testable import HushlightMac

private actor QQChatServiceFixture: QQChatReading {
    var calls = 0
    var started = false
    var waiter: CheckedContinuation<Void, Never>?
    func snapshot() async throws -> QQChatSnapshot {
        calls += 1; started = true
        await withCheckedContinuation { waiter = $0 }
        return .init(conversationTitle: "Synthetic", messages: [], hasDraft: false, checkedAt: .distantPast)
    }
    func isStarted() -> Bool { started }
    func count() -> Int { calls }
    func finish() { waiter?.resume(); waiter = nil }
}

final class QQChatBridgeServiceTests: XCTestCase {
    func testSharedPauseRejectsReadBeforeNativeAccessAndAfterResume() async throws {
        let suite = "qqchat.service.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = QQChatServiceFixture()
        let service = LocalBridgeService(preferences: UserDefaultsPausePreferenceStore(defaults: defaults),
                                         qqChatBackend: backend,
                                         runtimeFactory: { paused, _, _, _, _, _ in
            try await BridgeLocalRuntime(simulate: true, paused: paused)
        })
        try await service.setPaused(true)
        do { _ = try await service.qqChatSnapshot(); XCTFail("Paused read should fail") }
        catch { XCTAssertEqual(error as? StableErrorCode, .bridgePaused) }
        let before = await backend.count(); XCTAssertEqual(before, 0)
        try await service.setPaused(false)
        let read = Task { try await service.qqChatSnapshot() }
        for _ in 0..<1000 { if await backend.isStarted() { break }; await Task.yield() }
        let started = await backend.isStarted(); XCTAssertTrue(started)
        try await service.setPaused(true); try await service.setPaused(false)
        await backend.finish()
        do { _ = try await read.value; XCTFail("Changed pause epoch must discard late read") }
        catch { XCTAssertEqual(error as? StableErrorCode, .bridgePaused) }
    }
}
