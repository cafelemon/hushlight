import XCTest
@testable import HushlightMac

final class AppleEventPermissionTests: XCTestCase {
    func testUnbundledProcessCannotClaimAutomationGrant() {
        XCTAssertEqual(AppleEventPermission.status(bundleID: "com.apple.Notes"), .unavailable)
    }

    func testPreparationAttemptsHiddenLaunchOnlyOncePerTarget() async {
        let counter = LaunchCounter()
        let preparation = AppleEventTargetPreparation(isRunning: { _ in false },
            launch: { _ in
                await counter.increment()
                try? await Task.sleep(for: .milliseconds(30))
                return false
            }, status: { _ in .unavailable })
        async let first = preparation.prepare(bundleID: "com.apple.Notes")
        async let second = preparation.prepare(bundleID: "com.apple.Notes")
        let results = await [first, second]
        XCTAssertEqual(results, [.unavailable, .unavailable])
        let third = await preparation.prepare(bundleID: "com.apple.Notes")
        XCTAssertEqual(third, .unavailable)
        let attempts = await counter.value
        XCTAssertEqual(attempts, 1)
    }

    func testAlreadyRunningTargetDoesNotLaunch() async {
        let counter = LaunchCounter()
        let preparation = AppleEventTargetPreparation(isRunning: { _ in true },
            launch: { _ in await counter.increment(); return true },
            status: { _ in .granted })
        let result = await preparation.prepare(bundleID: "com.apple.mail")
        XCTAssertEqual(result, .granted)
        let attempts = await counter.value
        XCTAssertEqual(attempts, 0)
    }
}

private actor LaunchCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
