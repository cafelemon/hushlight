import Foundation
import CoreGraphics
import XCTest
@testable import HushlightMac

@MainActor
final class WindowVisionModelTests: XCTestCase {
    private var window: WindowVisionWindow {
        .init(id: 42, pid: 123, target: .qqMusic, width: 1280, height: 800)
    }

    func testAutomaticSelectionUsesSingleWindowWithoutManualCrop() async {
        let backend = VisionModelFixture()
        backend.windows = [window]
        let model = WindowVisionModel(backend: backend, selector: ExactWindowTextSelector())
        model.automaticTargetText = "仅供测试的临时文本"
        await model.automaticallyLocate()
        XCTAssertNotNil(model.result)
        XCTAssertNotNil(model.selection)
        XCTAssertEqual(model.selectedWindowID, window.id)
        XCTAssertNotNil(model.automaticSummary)
        XCTAssertEqual(backend.permissionRequests, 0)
        XCTAssertEqual(backend.captures, 1)
    }

    func testAutomaticSelectionRefusesMultipleUnselectedWindows() async {
        let backend = VisionModelFixture()
        backend.windows = [window, .init(id: 43, pid: 123, target: .qqMusic, width: 1280, height: 800)]
        let model = WindowVisionModel(backend: backend, selector: ExactWindowTextSelector())
        model.automaticTargetText = "仅供测试的临时文本"
        await model.automaticallyLocate()
        XCTAssertNil(model.result)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(backend.captures, 0)
    }

    func testChangingAutomaticGoalDiscardsLateCapture() async {
        let backend = VisionModelFixture()
        backend.windows = [window]; backend.holdCapture = true
        let model = WindowVisionModel(backend: backend, selector: ExactWindowTextSelector())
        model.automaticTargetText = "仅供测试的临时文本"
        let task = Task { await model.automaticallyLocate() }
        await backend.waitForCapture()
        model.automaticTargetText = "另一个目标"
        backend.finishCapture()
        await task.value
        XCTAssertNil(model.result); XCTAssertNil(model.preview)
        XCTAssertNil(model.automaticSummary)
        XCTAssertEqual(backend.recognitions, 0)
    }

    func testAutomaticSelectionRejectsReusedWindowIDWithChangedIdentity() async {
        let backend = VisionModelFixture()
        backend.windows = [window]
        let model = WindowVisionModel(backend: backend, selector: ExactWindowTextSelector())
        await model.loadWindows()
        model.selectWindow(window.id)
        model.automaticTargetText = "仅供测试的临时文本"
        backend.windows = [.init(id: window.id, pid: 999, target: .qqMusic, width: 1280, height: 800)]
        await model.automaticallyLocate()
        XCTAssertNil(model.result); XCTAssertNotNil(model.error)
        XCTAssertEqual(backend.captures, 0)
    }

    func testNavigationAndTargetSelectionDoNotRequestOrCapture() {
        let backend = VisionModelFixture()
        let model = WindowVisionModel(backend: backend, selector: ExactWindowTextSelector())
        model.selectTarget(.weChat)
        model.selectWindow(42)
        XCTAssertEqual(backend.permissionRequests, 0)
        XCTAssertEqual(backend.permissionReads, 0)
        XCTAssertEqual(backend.windowReads, 0)
        XCTAssertEqual(backend.captures, 0)
        XCTAssertNil(model.selectedWindowID)
    }

    func testMissingPermissionDoesNotPromptOrDiscoverWindows() async {
        let backend = VisionModelFixture()
        backend.granted = false
        let model = WindowVisionModel(backend: backend, selector: ExactWindowTextSelector())
        await model.loadWindows()
        XCTAssertNotNil(model.error)
        XCTAssertEqual(backend.windowReads, 0)
        XCTAssertEqual(backend.permissionRequests, 0)
        await model.requestPermission()
        XCTAssertEqual(backend.permissionRequests, 1)
        XCTAssertEqual(backend.windowReads, 0)
        XCTAssertEqual(backend.captures, 0)
    }

    func testExplicitSelectionAndResultClearOnPause() async {
        let backend = VisionModelFixture()
        backend.windows = [window]
        let model = WindowVisionModel(backend: backend, selector: ExactWindowTextSelector())
        await model.loadWindows()
        XCTAssertNil(model.selectedWindowID)
        await model.capturePreview()
        XCTAssertEqual(backend.captures, 0)
        model.selectWindow(window.id)
        await model.capturePreview()
        await model.recognize()
        XCTAssertEqual(backend.recognitions, 0)
        model.setSelection(CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4))
        await model.recognize()
        XCTAssertNotNil(model.result)
        model.setPaused(true)
        XCTAssertNil(model.result)
        await model.recognize()
        XCTAssertEqual(backend.captures, 1)
    }

    func testTargetChangeDiscardsLateWindowList() async {
        let backend = VisionModelFixture()
        backend.windows = [window]
        backend.holdList = true
        let model = WindowVisionModel(backend: backend, selector: ExactWindowTextSelector())
        let pending = Task { await model.loadWindows() }
        await backend.waitForList()
        model.selectTarget(.weChat)
        backend.finishList()
        await pending.value
        XCTAssertTrue(model.windows.isEmpty)
        XCTAssertNil(model.selectedWindowID)
        XCTAssertFalse(model.isBusy)
    }

    func testDuplicateCaptureAndLatePrivateResultAreDiscarded() async {
        let backend = VisionModelFixture()
        backend.windows = [window]
        backend.holdCapture = true
        let model = WindowVisionModel(backend: backend, selector: ExactWindowTextSelector())
        await model.loadWindows()
        model.selectWindow(window.id)
        let pending = Task { await model.capturePreview() }
        await backend.waitForCapture()
        await model.capturePreview()
        XCTAssertEqual(backend.captures, 1)
        model.clear()
        backend.finishCapture()
        await pending.value
        XCTAssertNil(model.result)
        XCTAssertNil(model.preview)
        XCTAssertTrue(backend.captureWasCancelled)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isBusy)
    }

    func testPauseCancelsOCRAndDiscardsItsLateText() async {
        let backend = VisionModelFixture()
        backend.windows = [window]
        backend.holdRecognition = true
        let model = WindowVisionModel(backend: backend, selector: ExactWindowTextSelector())
        await model.loadWindows()
        model.selectWindow(window.id)
        await model.capturePreview()
        model.setSelection(CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        let pending = Task { await model.recognize() }
        await backend.waitForRecognition()
        await model.recognize()
        XCTAssertEqual(backend.recognitions, 1)
        model.setPaused(true)
        backend.finishRecognition()
        await pending.value
        XCTAssertTrue(backend.recognitionWasCancelled)
        XCTAssertNil(model.preview)
        XCTAssertNil(model.selection)
        XCTAssertNil(model.result)
        XCTAssertFalse(model.isBusy)
    }

    func testSelectionMappingClampsToImageAndRejectsOutsideStart() {
        let canvas = CGSize(width: 400, height: 200)
        let crop = WindowVisionSelection.normalized(start: CGPoint(x: 100, y: 50), end: CGPoint(x: 600, y: 400), canvas: canvas)
        XCTAssertEqual(crop, CGRect(x: 0.25, y: 0.25, width: 0.75, height: 0.75))
        XCTAssertNil(WindowVisionSelection.normalized(start: CGPoint(x: -1, y: 50), end: .zero, canvas: canvas))
        XCTAssertNil(WindowVisionSelection.normalized(start: .zero, end: .zero, canvas: canvas))
    }

    func testChangedWindowIdentityIsNotShownAsRecognized() async {
        let backend = VisionModelFixture()
        backend.windows = [window]
        backend.returnWrongWindow = true
        let model = WindowVisionModel(backend: backend, selector: ExactWindowTextSelector())
        await model.loadWindows()
        model.selectWindow(window.id)
        await model.capturePreview()
        XCTAssertNil(model.preview)
        XCTAssertNotNil(model.error)
    }
}

@MainActor
private final class VisionModelFixture: WindowVisionProviding {
    var granted = true
    var permissionRequests = 0
    var permissionReads = 0
    var windowReads = 0
    var captures = 0
    var captureError: WindowVisionError?
    var recognitions = 0
    var captureWasCancelled = false
    var windows: [WindowVisionWindow] = []
    var holdList = false
    var holdCapture = false
    var holdRecognition = false
    var recognitionWasCancelled = false
    var returnWrongWindow = false
    private var listContinuation: CheckedContinuation<Void, Never>?
    private var captureContinuation: CheckedContinuation<Void, Never>?
    private var listStarted: CheckedContinuation<Void, Never>?
    private var captureStarted: CheckedContinuation<Void, Never>?
    private var recognitionContinuation: CheckedContinuation<Void, Never>?
    private var recognitionStarted: CheckedContinuation<Void, Never>?

    func permissionGranted() async -> Bool { permissionReads += 1; return granted }
    func requestPermission() async -> Bool { permissionRequests += 1; return granted }
    func listWindows(target: WindowVisionTarget) async throws -> [WindowVisionWindow] {
        windowReads += 1
        listStarted?.resume(); listStarted = nil
        if holdList { await withCheckedContinuation { listContinuation = $0 } }
        return windows
    }
    func capturePreview(window: WindowVisionWindow) async throws -> WindowVisionPreview {
        captures += 1
        if let captureError { throw captureError }
        captureStarted?.resume(); captureStarted = nil
        if holdCapture { await withCheckedContinuation { captureContinuation = $0 } }
        captureWasCancelled = Task.isCancelled
        let output = returnWrongWindow
            ? WindowVisionWindow(id: window.id, pid: window.pid + 1, target: window.target, width: window.width, height: window.height)
            : window
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return .init(window: output, checkedAt: Date(), image: context.makeImage()!)
    }
    func recognize(preview: WindowVisionPreview, region: CGRect) async throws -> WindowVisionResult {
        recognitions += 1
        recognitionStarted?.resume(); recognitionStarted = nil
        if holdRecognition { await withCheckedContinuation { recognitionContinuation = $0 } }
        recognitionWasCancelled = Task.isCancelled
        return .init(window: preview.window, checkedAt: preview.checkedAt, lines: [
            .init(text: "仅供测试的临时文本", confidence: 0.98, rect: region, region: "selection")
        ])
    }
    func waitForList() async {
        if windowReads > 0 { return }
        await withCheckedContinuation { listStarted = $0 }
    }
    func waitForCapture() async {
        if captures > 0 { return }
        await withCheckedContinuation { captureStarted = $0 }
    }
    func waitForRecognition() async {
        if recognitions > 0 { return }
        await withCheckedContinuation { recognitionStarted = $0 }
    }
    func finishRecognition() { recognitionContinuation?.resume(); recognitionContinuation = nil }
    func finishList() { listContinuation?.resume(); listContinuation = nil }
    func finishCapture() { captureContinuation?.resume(); captureContinuation = nil }
}

extension WindowVisionModelTests {
    func testRestrictedWindowIsNotPresentedAsMissingPermissionAndDoesNotReachOCR() async {
        let chat = WindowVisionWindow(id:42,pid:123,target:.weChat,width:800,height:600)
        let backend = VisionModelFixture();backend.windows = [chat];backend.captureError = .sharingRestricted
        let model = WindowVisionModel(backend:backend,selector:ExactWindowTextSelector())
        model.selectTarget(.weChat)
        await model.loadWindows();model.selectWindow(chat.id)
        await model.capturePreview()
        XCTAssertNil(model.preview)
        XCTAssertTrue(model.error?.contains("不共享") == true)
        XCTAssertEqual(backend.permissionRequests,0)
        model.automaticTargetText = "仅供测试的临时文本"
        await model.automaticallyLocate()
        XCTAssertNil(model.result)
        XCTAssertTrue(model.error?.contains("重复授权不能解除") == true)
        XCTAssertEqual(backend.recognitions,0)
        XCTAssertEqual(backend.permissionRequests,0)
    }
}
