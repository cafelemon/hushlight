import XCTest
@testable import HushlightMac

final class ConfirmationSecurityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_687_200)
    private let bridgeID = "bridge-mac-test"
    private let keyID = "confirmation-key-01"
    private let keyData = Data(repeating: 0x42, count: 32)
    private let digest = String(repeating: "a", count: 64)

    func testValidBoundConfirmationAllowsSingleExecution() async throws {
        let authority = makeAuthority()
        let credential = try authority.sign(makeClaims(), keyID: keyID)
        let adapter = L3CountingAdapter()
        let router = try CommandRouter(
            adapters: [adapter],
            policyEngine: PolicyEngine(confirmationVerifier: authority)
        )

        let result = await router.handle(makeCommand(confirmation: credential), now: now)
        let count = await adapter.executionCount

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(count, 1)
    }

    func testTargetOrDraftMutationInvalidatesConfirmation() async throws {
        let authority = makeAuthority()
        let credential = try authority.sign(makeClaims(), keyID: keyID)
        let adapter = L3CountingAdapter()
        let router = try CommandRouter(
            adapters: [adapter],
            policyEngine: PolicyEngine(confirmationVerifier: authority)
        )

        let result = await router.handle(
            makeCommand(
                parameters: sendParameters(targetID: "different-contact"),
                confirmation: credential
            ),
            now: now
        )
        let count = await adapter.executionCount

        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.stableError, .confirmationInvalid)
        XCTAssertEqual(count, 0)
    }

    func testTamperedSignatureIsRejected() async throws {
        let authority = makeAuthority()
        let signed = try authority.sign(makeClaims(), keyID: keyID)
        let tampered = ConfirmationCredential(
            confirmationID: signed.confirmationID,
            action: signed.action,
            issuedAt: signed.issuedAt,
            expiresAt: signed.expiresAt,
            userID: signed.userID,
            deviceID: signed.deviceID,
            bridgeID: signed.bridgeID,
            sessionID: signed.sessionID,
            provider: signed.provider,
            targetID: signed.targetID,
            draftSHA256: signed.draftSHA256,
            keyID: signed.keyID,
            signature: signed.signature + "A"
        )
        let router = try CommandRouter(
            adapters: [L3CountingAdapter()],
            policyEngine: PolicyEngine(confirmationVerifier: authority)
        )

        let result = await router.handle(makeCommand(confirmation: tampered), now: now)

        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.stableError, .confirmationInvalid)
    }

    func testExpiredAndOverlongConfirmationsAreRejected() async throws {
        let authority = makeAuthority()
        let expired = try authority.sign(
            makeClaims(
                issuedAt: now.addingTimeInterval(-60),
                expiresAt: now.addingTimeInterval(-1)
            ),
            keyID: keyID
        )
        let overlong = try authority.sign(
            makeClaims(
                issuedAt: now.addingTimeInterval(-1),
                expiresAt: now.addingTimeInterval(61)
            ),
            keyID: keyID
        )
        let router = try CommandRouter(
            adapters: [L3CountingAdapter()],
            policyEngine: PolicyEngine(confirmationVerifier: authority)
        )

        let expiredResult = await router.handle(
            makeCommand(requestID: "request-expired", confirmation: expired),
            now: now
        )
        let overlongResult = await router.handle(
            makeCommand(requestID: "request-overlong", confirmation: overlong),
            now: now
        )

        XCTAssertEqual(expiredResult.stableError, .confirmationExpired)
        XCTAssertEqual(overlongResult.stableError, .confirmationInvalid)
    }

    func testConfirmationCannotBeReusedWithDifferentRequestID() async throws {
        let authority = makeAuthority()
        let credential = try authority.sign(makeClaims(), keyID: keyID)
        let adapter = L3CountingAdapter()
        let router = try CommandRouter(
            adapters: [adapter],
            policyEngine: PolicyEngine(confirmationVerifier: authority)
        )

        let first = await router.handle(
            makeCommand(requestID: "request-one", confirmation: credential),
            now: now
        )
        let second = await router.handle(
            makeCommand(requestID: "request-two", confirmation: credential),
            now: now
        )
        let count = await adapter.executionCount

        XCTAssertEqual(first.status, .succeeded)
        XCTAssertEqual(second.status, .rejected)
        XCTAssertEqual(second.stableError, .confirmationUsed)
        XCTAssertEqual(count, 1)
    }

    func testDeviceSourceMustMatchConfirmationDevice() async throws {
        let authority = makeAuthority()
        let credential = try authority.sign(makeClaims(), keyID: keyID)
        let router = try CommandRouter(
            adapters: [L3CountingAdapter()],
            policyEngine: PolicyEngine(confirmationVerifier: authority)
        )

        let result = await router.handle(
            makeCommand(
                source: BridgeSource(kind: .device, id: "another-device"),
                confirmation: credential
            ),
            now: now
        )

        XCTAssertEqual(result.stableError, .confirmationInvalid)
    }

    private func makeAuthority() -> HMACConfirmationAuthority {
        HMACConfirmationAuthority(
            expectedBridgeID: bridgeID,
            keys: [keyID: keyData]
        )
    }

    private func makeClaims(
        issuedAt: Date? = nil,
        expiresAt: Date? = nil
    ) -> ConfirmationClaims {
        ConfirmationClaims(
            confirmationID: "018f0f4e-2f55-7f5c-8ca2-999999999999",
            action: "chat.send",
            issuedAt: issuedAt ?? now.addingTimeInterval(-1),
            expiresAt: expiresAt ?? now.addingTimeInterval(30),
            userID: "user-01",
            deviceID: "device-01",
            bridgeID: bridgeID,
            sessionID: "session-01",
            provider: "wechat",
            targetID: "contact-01",
            draftSHA256: digest
        )
    }

    private func makeCommand(
        requestID: String = "request-01",
        source: BridgeSource = BridgeSource(kind: .cloud, id: "cloud-test"),
        parameters: JSONValue? = nil,
        confirmation: ConfirmationCredential
    ) -> BridgeCommand {
        BridgeCommand(
            requestID: requestID,
            source: source,
            issuedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(30),
            action: "chat.send",
            riskLevel: .l3,
            parameters: parameters ?? sendParameters(),
            confirmation: confirmation
        )
    }

    private func sendParameters(targetID: String = "contact-01") -> JSONValue {
        .object([
            "provider": .string("wechat"),
            "user_id": .string("user-01"),
            "device_id": .string("device-01"),
            "session_id": .string("session-01"),
            "target_id": .string(targetID),
            "draft_sha256": .string(digest)
        ])
    }
}

private actor L3CountingAdapter: CommandAdapter {
    nonisolated let supportedActions: Set<String> = ["chat.send"]
    private(set) var executionCount = 0

    func execute(_ command: BridgeCommand) async throws -> AdapterExecution {
        executionCount += 1
        return .succeeded()
    }
}
