import XCTest
@testable import HushlightMac

private actor ChatTestVerifier: ChatTargetVerifying {
    var target: ChatTarget
    private var delayedResult: ChatTarget?
    private var delayedContinuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var isWaiting = false
    init(_ target: ChatTarget) { self.target = target }
    func verifiedTarget() async throws -> ChatTarget {
        if let delayedResult {
            self.delayedResult = nil
            isWaiting = true
            started?.resume(); started = nil
            await withCheckedContinuation { delayedContinuation = $0 }
            return delayedResult
        }
        return target
    }
    func change(to target: ChatTarget) { self.target = target }
    func delayNext(result: ChatTarget) { delayedResult = result }
    func waitUntilDelayed() async {
        if isWaiting { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { delayedContinuation?.resume(); delayedContinuation = nil; isWaiting = false }
}

private actor ChatPauseFlag {
    var paused = false
    func set(_ value: Bool) { paused = value }
    func get() -> Bool { paused }
}

private actor ChatTestAnalyzer: ChatAnalyzing {
    var calls = 0
    var replyText: String? = "hello"
    var suspended = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func suspend() { suspended = true }
    func waitUntilStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { suspended = false; continuation?.resume(); continuation = nil }
    func reply(to message: ChatIncomingMessage) async throws -> String? {
        calls += 1
        started?.resume(); started = nil
        if suspended { await withCheckedContinuation { continuation = $0 } }
        return replyText // Intentionally ignores cancellation to test late callbacks.
    }
}

private actor ChatTestSender: ChatSending {
    var calls = 0
    var sentIDs = [String]()
    var observedTarget: ChatTarget?
    var result: ChatSendOutcome = .sent
    var suspended = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func suspend() { suspended = true }
    func setObservedTarget(_ target: ChatTarget) { observedTarget = target }
    func setResult(_ outcome: ChatSendOutcome) { result = outcome }
    func waitUntilStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { suspended = false; continuation?.resume(); continuation = nil }
    func send(_ request: ChatSendRequest,
              authorization: @escaping @Sendable (ChatTarget) async -> Bool) async -> ChatSendOutcome {
        calls += 1
        started?.resume(); started = nil
        if suspended { await withCheckedContinuation { continuation = $0 } }
        guard await authorization(observedTarget ?? request.target) else { return .rejected }
        sentIDs.append(request.messageRequestID)
        return result
    }
}

final class ChatSessionCoordinatorTests: XCTestCase {
    private let group = ChatTarget(accountID: "account-1", groupID: "group-1")
    private let otherGroup = ChatTarget(accountID: "account-1", groupID: "group-2")

    private func message(_ id: String, target: ChatTarget? = nil, caller: String = "user") -> ChatIncomingMessage {
        ChatIncomingMessage(messageRequestID: id, callerID: caller, target: target ?? group, body: "incoming")
    }

    private func start(_ coordinator: ChatSessionCoordinator, target: ChatTarget? = nil) async throws {
        try await coordinator.start(ChatStartRequest(intent: .explicitUserAuthorization,
                                                    callerID: "user", target: target ?? group))
    }

    func testStartBindsVerifiedAccountGroupAndCaller() async throws {
        let verifier = ChatTestVerifier(group)
        let sender = ChatTestSender()
        let coordinator = ChatSessionCoordinator(verifier: verifier, analyzer: ChatTestAnalyzer(),
                                                 sender: sender, isSharedPaused: { false })
        let observed0 = await coordinator.isActive()
        XCTAssertFalse(observed0)
        try await start(coordinator)
        let observed1 = await coordinator.handle(message("wrong-caller", caller: "someone-else"))
        XCTAssertEqual(observed1, .wrongTarget)
        let observed2 = await coordinator.handle(message("wrong-group", target: otherGroup))
        XCTAssertEqual(observed2, .wrongTarget)
        let observed3 = await coordinator.handle(message("one"))
        XCTAssertEqual(observed3, .sent)
        let observed4 = await sender.sentIDs
        XCTAssertEqual(observed4, ["one"])
    }

    func testStartRejectsUnverifiedTargetAndRestartHasNoSession() async throws {
        let verifier = ChatTestVerifier(group)
        let analyzer = ChatTestAnalyzer()
        let sender = ChatTestSender()
        let coordinator = ChatSessionCoordinator(verifier: verifier, analyzer: analyzer,
                                                 sender: sender, isSharedPaused: { false })
        do {
            try await start(coordinator, target: otherGroup)
            XCTFail("Unverified target was accepted")
        } catch ChatSessionError.targetMismatch { }
        let restarted = ChatSessionCoordinator(verifier: verifier, analyzer: analyzer,
                                               sender: sender, isSharedPaused: { false })
        let observed5 = await restarted.handle(message("never-authorized"))
        XCTAssertEqual(observed5, .stopped)
    }

    func testStopCancelsSlowAnalysisAndRejectsLateReply() async throws {
        let analyzer = ChatTestAnalyzer()
        await analyzer.suspend()
        let sender = ChatTestSender()
        let coordinator = ChatSessionCoordinator(verifier: ChatTestVerifier(group), analyzer: analyzer,
                                                 sender: sender, isSharedPaused: { false })
        try await start(coordinator)
        let incoming = message("slow")
        let processing = Task { await coordinator.handle(incoming) }
        await analyzer.waitUntilStarted()
        await coordinator.stop()
        await analyzer.release()
        let observed6 = await processing.value
        XCTAssertEqual(observed6, .stopped)
        let observed7 = await coordinator.handle(message("later"))
        XCTAssertEqual(observed7, .stopped)
        let observed8 = await sender.calls
        XCTAssertEqual(observed8, 0)
    }

    func testStopBeforeFinalSendRejectsAndCannotRetractCompletedSend() async throws {
        let sender = ChatTestSender()
        await sender.suspend()
        let coordinator = ChatSessionCoordinator(verifier: ChatTestVerifier(group), analyzer: ChatTestAnalyzer(),
                                                 sender: sender, isSharedPaused: { false })
        try await start(coordinator)
        let incoming = message("waiting-send")
        let processing = Task { await coordinator.handle(incoming) }
        await sender.waitUntilStarted()
        await coordinator.stop()
        await sender.release()
        let observed9 = await processing.value
        XCTAssertEqual(observed9, .sendRejected)
        let observed10 = await sender.sentIDs.isEmpty
        XCTAssertTrue(observed10)
        try await start(coordinator)
        let observed11 = await coordinator.handle(message("completed"))
        XCTAssertEqual(observed11, .sent)
        await coordinator.stop()
        let observed12 = await sender.sentIDs
        XCTAssertEqual(observed12, ["completed"])
    }

    func testAccountOrGroupChangeAndSharedPauseBlockSending() async throws {
        let verifier = ChatTestVerifier(group)
        let sender = ChatTestSender()
        let coordinator = ChatSessionCoordinator(verifier: verifier, analyzer: ChatTestAnalyzer(),
                                                 sender: sender, isSharedPaused: { false })
        try await start(coordinator)
        await verifier.change(to: ChatTarget(accountID: "account-2", groupID: "group-1"))
        let observed13 = await coordinator.handle(message("changed-account"))
        XCTAssertEqual(observed13, .wrongTarget)
        let observed14 = await coordinator.handle(message("after-change"))
        XCTAssertEqual(observed14, .stopped)
        await verifier.change(to: group)
        try await start(coordinator)
        await sender.suspend()
        let incoming = message("changed-group")
        let processing = Task { await coordinator.handle(incoming) }
        await sender.waitUntilStarted()
        await sender.setObservedTarget(otherGroup)
        await sender.release()
        let observed15 = await processing.value
        XCTAssertEqual(observed15, .sendRejected)
        await coordinator.pause()
        let observed16 = await coordinator.handle(message("paused"))
        XCTAssertEqual(observed16, .stopped)
    }

    func testConcurrentRequestsDeduplicateAndUnknownIsNeverRetried() async throws {
        let analyzer = ChatTestAnalyzer()
        await analyzer.suspend()
        let sender = ChatTestSender()
        let coordinator = ChatSessionCoordinator(verifier: ChatTestVerifier(group), analyzer: analyzer,
                                                 sender: sender, isSharedPaused: { false })
        try await start(coordinator)
        let incoming = message("stable-id")
        let first = Task { await coordinator.handle(incoming) }
        await analyzer.waitUntilStarted()
        let observed17 = await coordinator.handle(message("stable-id"))
        XCTAssertEqual(observed17, .duplicate)
        let observed18 = await coordinator.handle(message("other-id"))
        XCTAssertEqual(observed18, .busy)
        await analyzer.release()
        let observed19 = await first.value
        XCTAssertEqual(observed19, .sent)
        let observed20 = await coordinator.handle(message("stable-id"))
        XCTAssertEqual(observed20, .duplicate)
        let observed21 = await sender.sentIDs
        XCTAssertEqual(observed21, ["stable-id"])

        await sender.setResult(.unknown)
        let observed22 = await coordinator.handle(message("unknown-id"))
        XCTAssertEqual(observed22, .deliveryUnknown)
        let observed23 = await coordinator.handle(message("unknown-id"))
        XCTAssertEqual(observed23, .duplicate)
        let observed24 = await sender.sentIDs
        XCTAssertEqual(observed24, ["stable-id", "unknown-id"])
    }

    func testLateOldTargetMismatchDoesNotStopNewSession() async throws {
        let verifier = ChatTestVerifier(group)
        let coordinator = ChatSessionCoordinator(verifier: verifier, analyzer: ChatTestAnalyzer(),
                                                 sender: ChatTestSender(), isSharedPaused: { false })
        try await start(coordinator)
        await verifier.delayNext(result: otherGroup)
        let oldMessage = message("old")
        let old = Task { await coordinator.handle(oldMessage) }
        await verifier.waitUntilDelayed()
        await coordinator.stop()
        try await start(coordinator)
        await verifier.release()
        let oldOutcome = await old.value
        XCTAssertEqual(oldOutcome, .wrongTarget)
        let active = await coordinator.isActive()
        XCTAssertTrue(active)
        let newOutcome = await coordinator.handle(message("new"))
        XCTAssertEqual(newOutcome, .sent)
    }

    func testStopDuringStartCannotActivateLateAuthorization() async throws {
        let verifier = ChatTestVerifier(group)
        await verifier.delayNext(result: group)
        let coordinator = ChatSessionCoordinator(verifier: verifier, analyzer: ChatTestAnalyzer(),
                                                 sender: ChatTestSender(), isSharedPaused: { false })
        let request = ChatStartRequest(intent: .explicitUserAuthorization, callerID: "user", target: group)
        let opening = Task { try await coordinator.start(request) }
        await verifier.waitUntilDelayed()
        await coordinator.stop()
        await verifier.release()
        do {
            try await opening.value
            XCTFail("Late authorization reopened a stopped session")
        } catch ChatSessionError.invalidRequest { }
        let active = await coordinator.isActive()
        XCTAssertFalse(active)
    }

    func testAsyncSharedPauseStopsFinalAuthorization() async throws {
        let flag = ChatPauseFlag()
        let sender = ChatTestSender()
        await sender.suspend()
        let coordinator = ChatSessionCoordinator(verifier: ChatTestVerifier(group), analyzer: ChatTestAnalyzer(),
                                                 sender: sender, isSharedPaused: { await flag.get() })
        try await start(coordinator)
        let incoming = message("pause-at-send")
        let processing = Task { await coordinator.handle(incoming) }
        await sender.waitUntilStarted()
        await flag.set(true)
        await sender.release()
        let outcome = await processing.value
        XCTAssertEqual(outcome, .sendRejected)
        let sentIDs = await sender.sentIDs
        XCTAssertTrue(sentIDs.isEmpty)
    }

    func testSameNativeMessageIDIsIndependentAcrossVerifiedGroups() async throws {
        let verifier = ChatTestVerifier(group)
        let sender = ChatTestSender()
        let coordinator = ChatSessionCoordinator(verifier: verifier, analyzer: ChatTestAnalyzer(),
                                                 sender: sender, isSharedPaused: { false })
        try await start(coordinator)
        let first = await coordinator.handle(message("local-7"))
        XCTAssertEqual(first, .sent)
        await coordinator.stop()
        await verifier.change(to: otherGroup)
        try await start(coordinator, target: otherGroup)
        let second = await coordinator.handle(message("local-7", target: otherGroup))
        XCTAssertEqual(second, .sent)
        await sender.setResult(.unknown)
        let unknown = await coordinator.handle(message("local-8", target: otherGroup))
        XCTAssertEqual(unknown, .deliveryUnknown)
        await coordinator.stop()
        try await start(coordinator, target: otherGroup)
        let replay = await coordinator.handle(message("local-8", target: otherGroup))
        XCTAssertEqual(replay, .duplicate)
        let sentIDs = await sender.sentIDs
        XCTAssertEqual(sentIDs, ["local-7", "local-7", "local-8"])
    }
}
