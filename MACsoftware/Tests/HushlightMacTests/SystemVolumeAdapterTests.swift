import Foundation
import XCTest
@testable import BridgeCore

final class SystemVolumeAdapterTests: XCTestCase {
    func testReadReturnsActualValueAndMuteWithoutWriting() async throws {
        let backend = VolumeFixture(value: 0.42, muted: true)
        let result = try await SystemVolumeAdapter(backend: backend).execute(command("system.volume.get"))
        XCTAssertEqual(result.status, .succeeded)
        guard case let .object(summary) = result.summary, case let .number(value)? = summary["value"] else {
            return XCTFail("Expected volume readback")
        }
        XCTAssertEqual(value, 42, accuracy: 0.001)
        XCTAssertEqual(summary["muted"], .bool(true))
        XCTAssertEqual(summary["evidence"], .string("core_audio_readback"))
        XCTAssertEqual(backend.writeCount, 0)
    }

    func testReadOnlyAdapterDoesNotRegisterOrExecuteWrites() async throws {
        let backend = VolumeFixture()
        let adapter = SystemVolumeAdapter(readOnly: true, backend: backend)
        XCTAssertEqual(adapter.supportedActions, ["system.volume.get"])
        do {
            _ = try await adapter.execute(command("system.volume.set", parameters: ["value": .number(10)]))
            XCTFail("Read-only adapter accepted write")
        } catch let error as StableErrorCode {
            XCTAssertEqual(error, .capabilityDisabled)
        }
        XCTAssertEqual(backend.writeCount, 0)
    }

    func testSetAndClampedAdjustReadBackActualValue() async throws {
        let backend = VolumeFixture()
        let adapter = SystemVolumeAdapter(backend: backend)
        let set = try await adapter.execute(command("system.volume.set", parameters: ["value": .number(75)]))
        XCTAssertEqual(set.status, .succeeded)
        let upper = try await adapter.execute(command("system.volume.adjust", parameters: ["delta": .number(40)]))
        XCTAssertEqual(upper.status, .succeeded)
        XCTAssertEqual(backend.value, 1)
        let lower = try await adapter.execute(command("system.volume.adjust", parameters: ["delta": .number(-100)]))
        XCTAssertEqual(lower.status, .succeeded)
        XCTAssertEqual(backend.value, 0)
        XCTAssertEqual(backend.writeCount, 3)
    }

    func testInvalidParametersNeverWriteEvenWhenCalledDirectly() async throws {
        let backend = VolumeFixture()
        do {
            _ = try await SystemVolumeAdapter(backend: backend).execute(
                command("system.volume.set", parameters: ["value": .number(101)])
            )
            XCTFail("Expected invalid schema")
        } catch let error as StableErrorCode {
            XCTAssertEqual(error, .invalidSchema)
        }
        XCTAssertEqual(backend.writeCount, 0)
    }

    func testUnsupportedOrUnavailableOutputDoesNotSucceed() async throws {
        for error in [VolumeBackendError.unsupported, .noOutputDevice, .readFailed] {
            let backend = VolumeFixture(readError: error)
            let result = try await SystemVolumeAdapter(backend: backend).execute(command("system.volume.get"))
            XCTAssertEqual(result.status, .failed)
            XCTAssertNotNil(result.stableError)
            XCTAssertEqual(backend.writeCount, 0)
        }
    }

    func testReadbackMismatchDeviceChangeAndReadFailureReturnUnknown() async throws {
        for mode in [VolumeFixture.WriteBehavior.ignore, .switchDevice, .failReadback] {
            let backend = VolumeFixture(behavior: mode)
            let result = try await SystemVolumeAdapter(backend: backend).execute(
                command("system.volume.set", parameters: ["value": .number(80)])
            )
            XCTAssertEqual(result.status, .unknown)
            XCTAssertEqual(result.stableError, .resultUnverifiable)
            XCTAssertEqual(backend.writeCount, 1)
        }
    }

    func testWriteFailureIsUnknownAndUnsupportedWriteIsFailed() async throws {
        for (error, status) in [(VolumeBackendError.writeFailed, CommandStatus.unknown), (.unsupported, .failed)] {
            let backend = VolumeFixture(writeError: error)
            let result = try await SystemVolumeAdapter(backend: backend).execute(
                command("system.volume.set", parameters: ["value": .number(80)])
            )
            XCTAssertEqual(result.status, status)
            XCTAssertNotNil(result.stableError)
        }
    }

    func testConcurrentAdjustmentsSerializeWithoutLostUpdates() async throws {
        let backend = VolumeFixture(value: 0)
        let adapter = SystemVolumeAdapter(backend: backend)
        let action = command("system.volume.adjust", parameters: ["delta": .number(1)])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let result = try await adapter.execute(action)
                    XCTAssertEqual(result.status, .succeeded)
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(backend.value, 0.2, accuracy: 0.00001)
        XCTAssertEqual(backend.writeCount, 20)
    }

    private func command(_ action: String, parameters: [String: JSONValue] = [:]) -> BridgeCommand {
        BridgeCommand(
            requestID: "019a0f4e-2f55-7f5c-8ca2-222222222222",
            source: BridgeSource(kind: .debugConsole, id: "volume-test"),
            issuedAt: Date(), expiresAt: Date().addingTimeInterval(60),
            action: action,
            riskLevel: action == "system.volume.get" ? .l0 : .l1,
            parameters: .object(parameters), confirmation: nil
        )
    }
}

/// Locked test state; no macOS audio device is changed by this suite.
private final class VolumeFixture: OutputVolumeBackend, @unchecked Sendable {
    enum WriteBehavior { case normal, ignore, switchDevice, failReadback }
    private let lock = NSLock()
    private var scalar: Float32
    private var deviceID: UInt32 = 7
    private var writes = 0
    private let muted: Bool
    private var readError: VolumeBackendError?
    private let writeError: VolumeBackendError?
    private let behavior: WriteBehavior

    init(value: Float32 = 0.5, muted: Bool = false, readError: VolumeBackendError? = nil,
         writeError: VolumeBackendError? = nil, behavior: WriteBehavior = .normal) {
        scalar = value
        self.muted = muted
        self.readError = readError
        self.writeError = writeError
        self.behavior = behavior
    }

    var value: Float32 { lock.withLock { scalar } }
    var writeCount: Int { lock.withLock { writes } }

    func snapshot() throws -> OutputVolumeSnapshot {
        try lock.withLock {
            if let readError { throw readError }
            return OutputVolumeSnapshot(deviceID: deviceID, scalar: scalar, muted: muted)
        }
    }

    func setScalar(_ scalar: Float32, deviceID: UInt32) throws {
        try lock.withLock {
            writes += 1
            if let writeError { throw writeError }
            if behavior != .ignore { self.scalar = scalar }
            if behavior == .switchDevice { self.deviceID += 1 }
            if behavior == .failReadback { readError = .readFailed }
        }
    }
}
