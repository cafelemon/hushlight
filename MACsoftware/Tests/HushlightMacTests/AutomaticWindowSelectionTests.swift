import CoreGraphics
import Foundation
import XCTest
@testable import HushlightMac

final class AutomaticWindowSelectionTests: XCTestCase {
    private let window = WindowVisionWindow(id: 41, pid: 101, target: .qqMusic,
                                            width: 800, height: 600)
    private let region = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.1)

    func testUniqueNormalizedExactTargetReturnsOnlyMatchedLine() async throws {
        let backend = SelectionBackend(rounds: [[
            line("Private other text", rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1)),
            line("  Ｈｅｌｌｏ   World  ", rect: region)
        ]])
        let output = try await service(backend).select(window: window, targetText: "hello world",
                                                        authorize: { true })
        XCTAssertEqual(output.attempts, 1)
        XCTAssertEqual(output.region, region)
        XCTAssertEqual(output.result.lines.count, 1)
        XCTAssertEqual(output.result.lines.first?.text, "  Ｈｅｌｌｏ   World  ")
        let captures = await backend.captureCount()
        let regions = await backend.regions()
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(regions, [CGRect(x: 0, y: 0, width: 1, height: 1)])
    }

    func testDuplicateTargetIsAmbiguousEvenWhenRegionsOverlap() async {
        let overlapping = CGRect(x: 0.21, y: 0.31, width: 0.4, height: 0.1)
        let backend = SelectionBackend(rounds: [[line("晴天", rect: region),
                                                  line("晴天", rect: overlapping)]])
        await assertSelectionError(.ambiguous, backend: backend, target: "晴天")
    }

    func testLowConfidenceRejectsCandidate() async {
        let backend = SelectionBackend(rounds: [[line("晴天", confidence: 0.69)]])
        await assertSelectionError(.lowConfidence, backend: backend, target: "晴天")
    }

    func testFreshCaptureCorrectsTargetAfterInitialMiss() async throws {
        let backend = SelectionBackend(rounds: [[line("错误")], [line("晴天")]])
        let output = try await service(backend).select(window: window, targetText: "晴天",
                                                        authorize: { true })
        XCTAssertEqual(output.attempts, 2)
        XCTAssertEqual(output.result.lines.map(\.text), ["晴天"])
        let captures = await backend.captureCount()
        XCTAssertEqual(captures, 2)
    }

    func testAtMostTwoAttempts() async {
        let backend = SelectionBackend(rounds: [[line("错误")], [line("仍然错误")], [line("晴天")]])
        await assertSelectionError(.notFound, backend: backend, target: "晴天")
        let captures = await backend.captureCount()
        XCTAssertEqual(captures, 2)
    }

    func testCancellationAndRevokedAuthorizationDiscardRecognition() async throws {
        let revoked = SelectionAuthorization()
        let backend = SelectionBackend(rounds: [[line("晴天")]], afterRecognition: {
            await revoked.revoke()
        })
        do {
            _ = try await service(backend).select(window: window, targetText: "晴天",
                                                   authorize: { await revoked.allowed() })
            XCTFail("Expected revoked authorization")
        } catch AutomaticWindowSelectionError.unauthorized {}
        let captures = await backend.captureCount()
        XCTAssertEqual(captures, 1)

        let cancelledBackend = SelectionBackend(rounds: [[line("晴天")]])
        do {
            _ = try await service(cancelledBackend).select(window: window, targetText: "晴天",
                                                           authorize: {
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            })
            XCTFail("Expected cancellation")
        }
        catch is CancellationError {}
        let cancelledCaptures = await cancelledBackend.captureCount()
        XCTAssertEqual(cancelledCaptures, 0)
    }

    func testCrossWindowIdentityAndPermissionFailureDoNotRetry() async {
        let wrongWindow = WindowVisionWindow(id: 42, pid: 101, target: .qqMusic,
                                              width: 800, height: 600)
        let backend = SelectionBackend(rounds: [[line("晴天")]], returnedWindow: wrongWindow)
        await assertSelectionError(.unverifiedWindow, backend: backend, target: "晴天")
        let captures = await backend.captureCount()
        let recognitions = await backend.recognitionCount()
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(recognitions, 0)

        let denied = SelectionBackend(rounds: [[line("晴天")]], permitted: false)
        do {
            _ = try await service(denied).select(window: window, targetText: "晴天",
                                                  authorize: { true })
            XCTFail("Expected permission failure")
        } catch WindowVisionError.permissionRequired {}
        catch { XCTFail("Unexpected error: \(error)") }
        let deniedCaptures = await denied.captureCount()
        XCTAssertEqual(deniedCaptures, 0)
    }

    private func assertSelectionError(_ expected: AutomaticWindowSelectionError,
                                      backend: SelectionBackend, target: String) async {
        do {
            _ = try await service(backend).select(window: window, targetText: target,
                                                   authorize: { true })
            XCTFail("Expected \(expected)")
        } catch let error as AutomaticWindowSelectionError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func service(_ backend: SelectionBackend) -> AutomaticWindowSelectionService {
        AutomaticWindowSelectionService(backend: backend)
    }

    private func line(_ text: String, confidence: Float = 0.9,
                      rect: CGRect? = nil) -> WindowVisionLine {
        WindowVisionLine(text: text, confidence: confidence, rect: rect ?? region, region: "selection")
    }
}

private actor SelectionAuthorization {
    private var isAllowed = true
    func revoke() { isAllowed = false }
    func allowed() -> Bool { isAllowed }
}

private actor SelectionBackend: WindowVisionProviding {
    private let rounds: [[WindowVisionLine]]
    private let returnedWindow: WindowVisionWindow?
    private let permitted: Bool
    private let afterRecognition: (@Sendable () async -> Void)?
    private var captures = 0
    private var recognitions = 0
    private var observedRegions: [CGRect] = []

    init(rounds: [[WindowVisionLine]], returnedWindow: WindowVisionWindow? = nil,
         permitted: Bool = true, afterRecognition: (@Sendable () async -> Void)? = nil) {
        self.rounds = rounds
        self.returnedWindow = returnedWindow
        self.permitted = permitted
        self.afterRecognition = afterRecognition
    }

    func permissionGranted() -> Bool { permitted }
    func requestPermission() -> Bool { permitted }
    func listWindows(target: WindowVisionTarget) -> [WindowVisionWindow] { [] }

    func capturePreview(window: WindowVisionWindow) -> WindowVisionPreview {
        captures += 1
        let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return WindowVisionPreview(window: returnedWindow ?? window, checkedAt: Date(),
                                   image: context.makeImage()!)
    }

    func recognize(preview: WindowVisionPreview, region: CGRect) async -> WindowVisionResult {
        recognitions += 1
        observedRegions.append(region)
        let index = min(recognitions - 1, rounds.count - 1)
        let result = WindowVisionResult(window: preview.window, checkedAt: preview.checkedAt,
                                        lines: rounds[index])
        await afterRecognition?()
        return result
    }

    func captureCount() -> Int { captures }
    func recognitionCount() -> Int { recognitions }
    func regions() -> [CGRect] { observedRegions }
}

private struct UncheckedWindowSelector: AutomaticWindowTextSelecting {
    func select(targetText: String, lines: [WindowVisionLine]) -> AutomaticWindowSelectionChoice { .selected(index: 0) }
}
extension AutomaticWindowSelectionTests {
    func testServiceRejectsLowConfidenceEvenWhenSelectorAcceptsIt() async throws {
        let backend = SelectionBackend(rounds: [[line("Target",confidence: 0.1)]])
        let selector = AutomaticWindowSelectionService(backend: backend,selector: UncheckedWindowSelector())
        do {
            _ = try await selector.select(window: window,targetText: "Target",authorize: { true })
            XCTFail("Service must enforce confidence independently")
        } catch AutomaticWindowSelectionError.lowConfidence {}
    }
}
