import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import HushlightMac

final class WindowVisionBackendTests: XCTestCase {
    private let qq = WindowVisionWindow(id: 41, pid: 101, target: .qqMusic,
                                        width: 800, height: 600)

    func testMissingPermissionNeverListsOrCaptures() async throws {
        let surface = FakeWindowVisionSurface(granted: false, candidates: [candidate(41, 101)])
        let backend = NativeWindowVisionBackend(surface: surface, recognizer: FakeWindowVisionRecognizer(),
                                                supported: { true })
        let granted = await backend.permissionGranted()
        XCTAssertFalse(granted)
        do { _ = try await backend.listWindows(target: .qqMusic); XCTFail("Expected permission denial") }
        catch WindowVisionError.permissionRequired {}
        do { _ = try await backend.capturePreview(window: qq); XCTFail("Expected permission denial") }
        catch WindowVisionError.permissionRequired {}
        let counts = await surface.counts()
        XCTAssertEqual(counts.windows, 0)
        XCTAssertEqual(counts.captures, 0)
        XCTAssertEqual(counts.requests, 0)
    }

    func testExistingPermissionIsReusedWithoutRequest() async {
        let surface = FakeWindowVisionSurface(granted: true, candidates: [])
        let backend = NativeWindowVisionBackend(surface: surface, recognizer: FakeWindowVisionRecognizer(),
                                                supported: { true })
        let granted = await backend.requestPermission()
        XCTAssertTrue(granted)
        let counts = await surface.counts()
        XCTAssertEqual(counts.preflights, 1)
        XCTAssertEqual(counts.requests, 0)
        XCTAssertEqual(counts.windows, 0)
        XCTAssertEqual(counts.captures, 0)
    }

    func testWhitelistIdentityAndExplicitMultipleWindowSelection() async throws {
        let surface = FakeWindowVisionSurface(granted: true, candidates: [
            candidate(41, 101), candidate(42, 101), candidate(43, 101, bundle: "com.other"),
            candidate(44, 0), candidate(45, 201, bundle: WindowVisionTarget.weChat.bundleID)
        ])
        let backend = NativeWindowVisionBackend(surface: surface, recognizer: FakeWindowVisionRecognizer(),
                                                supported: { true })
        let qqWindows = try await backend.listWindows(target: .qqMusic)
        XCTAssertEqual(qqWindows.map(\.id), [41, 42])
        let weChatIDs = try await backend.listWindows(target: .weChat).map(\.id)
        XCTAssertEqual(weChatIDs, [45])
        let beforeCapture = await surface.counts()
        XCTAssertEqual(beforeCapture.captures, 0)
        let chosen = try XCTUnwrap(qqWindows.last)
        let preview = try await backend.capturePreview(window: chosen)
        _ = try await backend.recognize(preview: preview, region: CGRect(x: 0.1, y: 0.1,
                                                                          width: 0.5, height: 0.5))
        let captured = await surface.capturedIDs()
        XCTAssertEqual(captured, [42])
    }

    func testStaleIdentityAfterCaptureDiscardsRecognition() async throws {
        let surface = FakeWindowVisionSurface(granted: true, candidates: [candidate(41, 101)])
        await surface.changeAfterCapture(to: [candidate(41, 999)])
        let recognizer = FakeWindowVisionRecognizer()
        let backend = NativeWindowVisionBackend(surface: surface, recognizer: recognizer,
                                                supported: { true })
        do { _ = try await backend.capturePreview(window: qq); XCTFail("Expected stale identity") }
        catch WindowVisionError.staleWindow {}
        let calls = await recognizer.count()
        XCTAssertEqual(calls, 0)
    }

    func testCancellationStopsBeforeCapture() async throws {
        let surface = FakeWindowVisionSurface(granted: true, candidates: [candidate(41, 101)])
        let backend = NativeWindowVisionBackend(surface: surface, recognizer: FakeWindowVisionRecognizer(),
                                                supported: { true })
        let selected = qq
        let task = Task { try await backend.capturePreview(window: selected) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        let counts = await surface.counts()
        XCTAssertEqual(counts.captures, 0)
    }

    func testUnsupportedNeverTouchesSurface() async throws {
        let surface = FakeWindowVisionSurface(granted: true, candidates: [candidate(41, 101)])
        let backend = NativeWindowVisionBackend(surface: surface, recognizer: FakeWindowVisionRecognizer(),
                                                supported: { false })
        let granted = await backend.permissionGranted()
        XCTAssertFalse(granted)
        do { _ = try await backend.listWindows(target: .qqMusic); XCTFail("Expected unsupported") }
        catch WindowVisionError.unsupported {}
        let counts = await surface.counts()
        XCTAssertEqual(counts.preflights, 0)
        let requested = await backend.requestPermission()
        XCTAssertFalse(requested)
        let final = await surface.counts()
        XCTAssertEqual(final.requests, 0)
    }

    func testUserRegionBoundsAndConservativePixelCropping() {
        let image = Self.makeImage(width: 101, height: 101)
        let region = CGRect(x: 0.101, y: 0.201, width: 0.499, height: 0.399)
        let pixels = WindowVisionRegionPolicy.pixelRect(region, image: image)
        XCTAssertEqual(pixels, CGRect(x: 11, y: 21, width: 49, height: 39))
        XCTAssertNil(WindowVisionRegionPolicy.pixelRect(.zero, image: image))
        XCTAssertNil(WindowVisionRegionPolicy.pixelRect(CGRect(x: 0.9, y: 0.9,
                                                                width: 0.2, height: 0.1), image: image))
        XCTAssertNil(WindowVisionRegionPolicy.pixelRect(CGRect(x: .nan, y: 0,
                                                                width: 0.5, height: 0.5), image: image))
        XCTAssertNil(WindowVisionRegionPolicy.pixelRect(CGRect(x: 0.001, y: 0.001,
                                                                width: 0.001, height: 0.001), image: image))
    }

    func testOversizeWindowsAreExcludedAndNeverCaptured() async throws {
        XCTAssertTrue(WindowVisionSizePolicy.accepts(width: 4_000, height: 4_000))
        XCTAssertFalse(WindowVisionSizePolicy.accepts(width: 4_001, height: 4_000))
        XCTAssertFalse(WindowVisionSizePolicy.accepts(width: 8_193, height: 100))
        XCTAssertFalse(WindowVisionSizePolicy.accepts(width: .infinity, height: 100))
        XCTAssertFalse(WindowVisionSizePolicy.accepts(width: 0, height: 100))
        let oversized = WindowVisionWindow(id: 80, pid: 101, target: .qqMusic,
                                           width: 8_193, height: 100)
        let surface = FakeWindowVisionSurface(granted: true, candidates: [
            WindowVisionCandidate(id: 80, pid: 101, bundleID: WindowVisionTarget.qqMusic.bundleID,
                                  width: 8_193, height: 100)
        ])
        let backend = NativeWindowVisionBackend(surface: surface, recognizer: FakeWindowVisionRecognizer(),
                                                supported: { true })
        let listed = try await backend.listWindows(target: .qqMusic)
        XCTAssertTrue(listed.isEmpty)
        do { _ = try await backend.capturePreview(window: oversized); XCTFail("Expected size denial") }
        catch WindowVisionError.invalidWindow {}
        let counts = await surface.counts()
        XCTAssertEqual(counts.captures, 0)
    }

    func testNativeVisionOnlyReadsExplicitSyntheticCrop() async throws {
        guard ProcessInfo.processInfo.environment["HUSHLIGHT_LIVE_VISION_SYNTHETIC"] == "1" else {
            throw XCTSkip("Opt in to local Vision model execution with HUSHLIGHT_LIVE_VISION_SYNTHETIC=1")
        }
        let image = Self.makeTextImage()
        let region = CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)
        let lines = try await NativeWindowVisionRecognizer().recognize(image: image, region: region)
        XCTAssertTrue(lines.contains { $0.text.uppercased().contains("ALPHA") },
                      "Expected synthetic in-crop word")
        XCTAssertFalse(lines.contains { $0.text.uppercased().contains("OUTSIDE") },
                       "Text outside user selection must not be read")
        for line in lines {
            XCTAssertEqual(line.region, "selection")
            XCTAssertGreaterThanOrEqual(line.rect.minX, region.minX - 0.01)
            XCTAssertGreaterThanOrEqual(line.rect.minY, region.minY - 0.01)
            XCTAssertLessThanOrEqual(line.rect.maxX, region.maxX + 0.01)
            XCTAssertLessThanOrEqual(line.rect.maxY, region.maxY + 0.01)
        }
    }

    private static func makeTextImage() -> CGImage {
        let context = CGContext(data: nil, width: 1_000, height: 600, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1_000, height: 600))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 76, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        context.textPosition = CGPoint(x: 300, y: 280)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "ALPHA", attributes: attrs)), context)
        context.textPosition = CGPoint(x: 10, y: 510)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "OUTSIDE", attributes: attrs)), context)
        return context.makeImage()!
    }

    private static func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    private func candidate(_ id: UInt32, _ pid: Int32,
                           bundle: String = WindowVisionTarget.qqMusic.bundleID) -> WindowVisionCandidate {
        WindowVisionCandidate(id: id, pid: pid, bundleID: bundle, width: 800, height: 600)
    }
}

private actor FakeWindowVisionSurface: WindowVisionSurface {
    private let granted: Bool
    private var candidates: [WindowVisionCandidate]
    private var replacement: [WindowVisionCandidate]?
    private var preflightCount = 0
    private var windowCount = 0
    private var captureCount = 0
    private var requestCount = 0
    private var captured: [UInt32] = []

    init(granted: Bool, candidates: [WindowVisionCandidate]) {
        self.granted = granted
        self.candidates = candidates
    }

    func preflight() -> Bool { preflightCount += 1; return granted }
    func requestPermission() -> Bool { requestCount += 1; return granted }
    func windows() -> [WindowVisionCandidate] { windowCount += 1; return candidates }
    func capture(_ window: WindowVisionWindow) throws -> CGImage {
        captureCount += 1
        captured.append(window.id)
        if let replacement { candidates = replacement }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8,
                                bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
    func changeAfterCapture(to candidates: [WindowVisionCandidate]) { replacement = candidates }
    func capturedIDs() -> [UInt32] { captured }
    func counts() -> (preflights: Int, windows: Int, captures: Int, requests: Int) {
        (preflightCount, windowCount, captureCount, requestCount)
    }
}

private actor FakeWindowVisionRecognizer: WindowVisionRecognizing {
    private var calls = 0
    func recognize(image: CGImage, region: CGRect) -> [WindowVisionLine] {
        calls += 1
        return []
    }
    func count() -> Int { calls }
}

extension WindowVisionBackendTests {
    func testRealRestrictedTestWindowOptInStopsBeforeImageRead() async throws {
        guard ProcessInfo.processInfo.environment["WORKBENCH_WECHAT_RESTRICTION_SMOKE"] == "1" else {
            throw XCTSkip("Requires user-prepared non-sensitive test window")
        }
        let surface = NativeWindowVisionSurface()
        guard await surface.preflight() else { throw XCTSkip("No capture permission inherited") }
        let metadata = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        let restrictedIDs = metadata.compactMap { row -> UInt32? in
            guard (row[kCGWindowName as String] as? String) == "文件传输助手",
                  (row[kCGWindowSharingState as String] as? UInt32) == CGWindowSharingType.none.rawValue else { return nil }
            return row[kCGWindowNumber as String] as? UInt32
        }
        let windows = try await surface.windows().filter {
            $0.bundleID == WindowVisionTarget.weChat.bundleID && restrictedIDs.contains($0.id)
        }
        guard windows.count == 1, let candidate = windows.first else { throw XCTSkip("Unique restricted test window required") }
        let target = WindowVisionWindow(id:candidate.id,pid:candidate.pid,target:.weChat,width:candidate.width,height:candidate.height)
        do {
            _ = try await surface.capture(target)
            XCTFail("Known non-shared WeChat window must reject before screenshot")
        } catch WindowVisionError.sharingRestricted {}
    }
}
