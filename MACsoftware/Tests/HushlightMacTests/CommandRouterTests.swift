import XCTest
@testable import HushlightMac

final class CommandRouterTests: XCTestCase {
    func testPausedRouterRejectsWithoutCallingAdapter() async throws {
        let adapter = CountingAdapter(actions: ["system.volume.get"])
        let router = try CommandRouter(adapters: [adapter])
        await router.setPaused(true)

        let result = await router.handle(makeCommand())
        let executionCount = await adapter.executionCount

        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.stableError, .bridgePaused)
        XCTAssertEqual(executionCount, 0)
    }

    func testRiskMismatchIsRejected() async throws {
        let adapter = CountingAdapter(actions: ["system.volume.get"])
        let router = try CommandRouter(adapters: [adapter])

        let result = await router.handle(makeCommand(riskLevel: .l1))
        let executionCount = await adapter.executionCount

        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.stableError, .invalidSchema)
        XCTAssertEqual(executionCount, 0)
    }

    func testL3RequiresConfirmation() async throws {
        let adapter = CountingAdapter(actions: ["chat.send"])
        let router = try CommandRouter(adapters: [adapter])

        let result = await router.handle(
            makeCommand(action: "chat.send", riskLevel: .l3)
        )
        let executionCount = await adapter.executionCount

        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.stableError, .confirmationRequired)
        XCTAssertEqual(executionCount, 0)
    }

    func testDuplicateInFlightRequestExecutesAdapterOnce() async throws {
        let adapter = CountingAdapter(
            actions: ["system.volume.get"],
            delayNanoseconds: 30_000_000
        )
        let router = try CommandRouter(adapters: [adapter])
        let command = makeCommand()

        async let first = router.handle(command)
        async let second = router.handle(command)
        let results = await [first, second]
        let executionCount = await adapter.executionCount

        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(results[0].status, .succeeded)
        XCTAssertEqual(executionCount, 1)
    }

    func testCompletedRequestReturnsCachedResultWithoutSecondExecution() async throws {
        let adapter = CountingAdapter(actions: ["system.volume.get"])
        let router = try CommandRouter(adapters: [adapter])
        let command = makeCommand()

        let first = await router.handle(command)
        let second = await router.handle(command)
        let executionCount = await adapter.executionCount
        let cachedResult = await router.cachedResult(for: command.requestID)

        XCTAssertEqual(first, second)
        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(cachedResult, first)
    }

    func testUnknownOrUnimplementedCapabilityFailsClosed() async throws {
        let router = try CommandRouter()

        let result = await router.handle(makeCommand(action: "system.volume.get"))

        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.stableError, .capabilityDisabled)
    }

    func testInconsistentAdapterSuccessFailsClosed() async throws {
        let router = try CommandRouter(adapters: [InconsistentAdapter()])

        let result = await router.handle(makeCommand())

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.stableError, .internalError)
    }

    func testThrownExecutionTimeoutIsUnknown() async throws {
        let router = try CommandRouter(adapters: [TimeoutAdapter()])

        let result = await router.handle(makeCommand())

        XCTAssertEqual(result.status, .unknown)
        XCTAssertEqual(result.stableError, .executionTimeout)
    }

    private func makeCommand(
        requestID: String = UUID().uuidString,
        action: String = "system.volume.get",
        riskLevel: RiskLevel = .l0,
        confirmation: ConfirmationCredential? = nil
    ) -> BridgeCommand {
        let now = Date()
        return BridgeCommand(
            requestID: requestID,
            source: BridgeSource(kind: .debugConsole, id: "unit-test"),
            issuedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(30),
            action: action,
            riskLevel: riskLevel,
            parameters: .emptyObject,
            confirmation: confirmation
        )
    }
}

private struct InconsistentAdapter: CommandAdapter {
    let supportedActions: Set<String> = ["system.volume.get"]

    func execute(_ command: BridgeCommand) async throws -> AdapterExecution {
        AdapterExecution(
            status: .succeeded,
            stableError: .resultUnverifiable,
            summary: .emptyObject
        )
    }
}

private struct TimeoutAdapter: CommandAdapter {
    let supportedActions: Set<String> = ["system.volume.get"]

    func execute(_ command: BridgeCommand) async throws -> AdapterExecution {
        throw StableErrorCode.executionTimeout
    }
}

private actor CountingAdapter: CommandAdapter {
    nonisolated let supportedActions: Set<String>
    private(set) var executionCount = 0
    private let delayNanoseconds: UInt64

    init(actions: Set<String>, delayNanoseconds: UInt64 = 0) {
        supportedActions = actions
        self.delayNanoseconds = delayNanoseconds
    }

    func execute(_ command: BridgeCommand) async throws -> AdapterExecution {
        executionCount += 1
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return .succeeded(summary: .object(["executed": .bool(true)]))
    }
}
