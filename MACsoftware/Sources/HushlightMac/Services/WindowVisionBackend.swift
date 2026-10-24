import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

enum WindowVisionTarget: String, CaseIterable, Sendable {
    case qqMusic
    case weChat

    var title: String {
        switch self {
        case .qqMusic: "QQ 音乐"
        case .weChat: "微信"
        }
    }

    var bundleID: String {
        switch self {
        case .qqMusic: "com.tencent.QQMusicMac"
        case .weChat: "com.tencent.xinWeChat"
        }
    }
}

struct WindowVisionWindow: Identifiable, Equatable, Sendable {
    let id: UInt32
    let pid: Int32
    let target: WindowVisionTarget
    let width: Double
    let height: Double
}

struct WindowVisionLine: Sendable {
    let text: String
    let confidence: Float
    /// Normalized window coordinates, with the origin at the top left.
    let rect: CGRect
    let region: String
}

struct WindowVisionResult: Sendable {
    let window: WindowVisionWindow
    let checkedAt: Date
    let lines: [WindowVisionLine]
}

struct WindowVisionPreview: Sendable {
    let window: WindowVisionWindow
    let checkedAt: Date
    /// Held only in memory for the active review flow.
    let image: CGImage
}

enum WindowVisionError: Error, Equatable {
    case unsupported
    case permissionRequired
    case invalidWindow
    case staleWindow
    case captureFailed
    case sharingRestricted
}

protocol WindowVisionProviding: Sendable {
    func permissionGranted() async -> Bool
    func requestPermission() async -> Bool
    func listWindows(target: WindowVisionTarget) async throws -> [WindowVisionWindow]
    func capturePreview(window: WindowVisionWindow) async throws -> WindowVisionPreview
    func recognize(preview: WindowVisionPreview, region: CGRect) async throws -> WindowVisionResult
}

/// Deliberately contains only identity and geometry; window titles never leave the native adapter.
struct WindowVisionCandidate: Sendable {
    let id: UInt32
    let pid: Int32
    let bundleID: String
    let width: Double
    let height: Double
}

enum WindowVisionSizePolicy {
    static func accepts(width: Double, height: Double) -> Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0 &&
        width <= 8_192 && height <= 8_192 && width * height <= 16_000_000
    }
}

enum WindowVisionRegionPolicy {
    /// User-selected normalized rectangle, with origin at the top left.
    static func pixelRect(_ region: CGRect, image: CGImage) -> CGRect? {
        guard region.origin.x.isFinite, region.origin.y.isFinite,
              region.width.isFinite, region.height.isFinite,
              region.minX >= 0, region.minY >= 0,
              region.width > 0, region.height > 0,
              region.maxX <= 1, region.maxY <= 1 else { return nil }
        // Round inward so fractional edges cannot reveal a pixel outside selection.
        let minX = ceil(region.minX * CGFloat(image.width))
        let minY = ceil(region.minY * CGFloat(image.height))
        let maxX = floor(region.maxX * CGFloat(image.width))
        let maxY = floor(region.maxY * CGFloat(image.height))
        guard maxX - minX >= 1, maxY - minY >= 1 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

protocol WindowVisionSurface: Sendable {
    func preflight() async -> Bool
    func requestPermission() async -> Bool
    func windows() async throws -> [WindowVisionCandidate]
    func capture(_ window: WindowVisionWindow) async throws -> CGImage
}

protocol WindowVisionRecognizing: Sendable {
    func recognize(image: CGImage, region: CGRect) async throws -> [WindowVisionLine]
}

struct NativeWindowVisionBackend: WindowVisionProviding {
    private let surface: any WindowVisionSurface
    private let recognizer: any WindowVisionRecognizing
    private let supported: @Sendable () -> Bool

    init(surface: any WindowVisionSurface = NativeWindowVisionSurface(),
         recognizer: any WindowVisionRecognizing = NativeWindowVisionRecognizer(),
         supported: @escaping @Sendable () -> Bool = {
             if #available(macOS 14.2, *) { return true }
             return false
         }) {
        self.surface = surface
        self.recognizer = recognizer
        self.supported = supported
    }

    func permissionGranted() async -> Bool {
        guard supported() else { return false }
        return await surface.preflight()
    }

    func requestPermission() async -> Bool {
        guard supported() else { return false }
        if await surface.preflight() { return true }
        return await surface.requestPermission()
    }

    func listWindows(target: WindowVisionTarget) async throws -> [WindowVisionWindow] {
        guard supported() else { throw WindowVisionError.unsupported }
        guard await surface.preflight() else { throw WindowVisionError.permissionRequired }
        try Task.checkCancellation()
        let candidates = try await surface.windows()
        try Task.checkCancellation()
        return candidates.compactMap { candidate in
            guard candidate.bundleID == target.bundleID,
                  candidate.pid > 0, candidate.id > 0,
                  WindowVisionSizePolicy.accepts(width: candidate.width,
                                                height: candidate.height) else { return nil }
            return WindowVisionWindow(id: candidate.id, pid: candidate.pid, target: target,
                                      width: candidate.width, height: candidate.height)
        }
    }

    func capturePreview(window: WindowVisionWindow) async throws -> WindowVisionPreview {
        guard supported() else { throw WindowVisionError.unsupported }
        guard await surface.preflight() else { throw WindowVisionError.permissionRequired }
        guard WindowVisionSizePolicy.accepts(width: window.width,
                                             height: window.height) else { throw WindowVisionError.invalidWindow }
        try Task.checkCancellation()
        guard try await isCurrent(window) else { throw WindowVisionError.invalidWindow }
        try Task.checkCancellation()
        let image = try await surface.capture(window)
        try Task.checkCancellation()
        guard try await isCurrent(window) else { throw WindowVisionError.staleWindow }
        guard WindowVisionSizePolicy.accepts(width: Double(image.width),
                                             height: Double(image.height)) else { throw WindowVisionError.captureFailed }
        return WindowVisionPreview(window: window, checkedAt: Date(), image: image)
    }

    func recognize(preview: WindowVisionPreview, region: CGRect) async throws -> WindowVisionResult {
        guard supported() else { throw WindowVisionError.unsupported }
        guard await surface.preflight() else { throw WindowVisionError.permissionRequired }
        guard WindowVisionSizePolicy.accepts(width: preview.window.width,
                                             height: preview.window.height),
              WindowVisionSizePolicy.accepts(width: Double(preview.image.width),
                                             height: Double(preview.image.height)),
              WindowVisionRegionPolicy.pixelRect(region, image: preview.image) != nil else {
            throw WindowVisionError.invalidWindow
        }
        try Task.checkCancellation()
        guard try await isCurrent(preview.window) else { throw WindowVisionError.staleWindow }
        try Task.checkCancellation()
        let lines = try await recognizer.recognize(image: preview.image, region: region)
        try Task.checkCancellation()
        guard try await isCurrent(preview.window) else { throw WindowVisionError.staleWindow }
        try Task.checkCancellation()
        return WindowVisionResult(window: preview.window, checkedAt: preview.checkedAt, lines: lines)
    }

    private func isCurrent(_ window: WindowVisionWindow) async throws -> Bool {
        guard await surface.preflight() else { throw WindowVisionError.permissionRequired }
        let candidates = try await surface.windows()
        return candidates.contains {
            $0.id == window.id && $0.pid == window.pid &&
            $0.bundleID == window.target.bundleID &&
            $0.width == window.width && $0.height == window.height &&
            WindowVisionSizePolicy.accepts(width: $0.width, height: $0.height)
        }
    }
}

struct NativeWindowVisionSurface: WindowVisionSurface {
    func preflight() async -> Bool { CGPreflightScreenCaptureAccess() }
    func requestPermission() async -> Bool { CGRequestScreenCaptureAccess() }

    func windows() async throws -> [WindowVisionCandidate] {
        guard CGPreflightScreenCaptureAccess() else { throw WindowVisionError.permissionRequired }
        guard #available(macOS 14.2, *) else { throw WindowVisionError.unsupported }
        let content = try await SCShareableContent.current
        try Task.checkCancellation()
        return content.windows.compactMap { window in
            guard window.isOnScreen, window.windowLayer == 0,
                  let owner = window.owningApplication,
                  owner.processID > 0,
                  WindowVisionTarget.allCases.contains(where: { $0.bundleID == owner.bundleIdentifier }),
                  WindowVisionSizePolicy.accepts(width: window.frame.width,
                                                height: window.frame.height) else { return nil }
            return WindowVisionCandidate(id: window.windowID, pid: owner.processID,
                                         bundleID: owner.bundleIdentifier,
                                         width: window.frame.width, height: window.frame.height)
        }
    }

    func capture(_ selected: WindowVisionWindow) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw WindowVisionError.permissionRequired }
        guard #available(macOS 14.2, *) else { throw WindowVisionError.unsupported }
        guard WindowVisionSizePolicy.accepts(width: selected.width,
                                             height: selected.height) else { throw WindowVisionError.invalidWindow }
        try Task.checkCancellation()
        let content = try await SCShareableContent.current
        guard let window = content.windows.first(where: {
            $0.windowID == selected.id && $0.windowLayer == 0 && $0.isOnScreen &&
            $0.owningApplication?.processID == selected.pid &&
            $0.owningApplication?.bundleIdentifier == selected.target.bundleID &&
            $0.frame.width == selected.width && $0.frame.height == selected.height
        }) else { throw WindowVisionError.staleWindow }
        guard WindowVisionSizePolicy.accepts(width: window.frame.width,
                                             height: window.frame.height) else { throw WindowVisionError.invalidWindow }
        try Task.checkCancellation()
        if selected.target == .weChat {
            let metadata = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            if let entry = metadata.first(where: {
                ($0[kCGWindowNumber as String] as? UInt32) == selected.id &&
                ($0[kCGWindowOwnerPID as String] as? Int32) == selected.pid
            }), let sharing = entry[kCGWindowSharingState as String] as? UInt32,
               sharing == CGWindowSharingType.none.rawValue {
                throw WindowVisionError.sharingRestricted
            }
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width)
        configuration.height = Int(window.frame.height)
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.includeChildWindows = false
        configuration.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                               configuration: configuration)
        try Task.checkCancellation()
        guard WindowVisionSizePolicy.accepts(width: Double(image.width),
                                             height: Double(image.height)) else { throw WindowVisionError.captureFailed }
        return image
    }
}

private final class WindowVisionImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

struct NativeWindowVisionRecognizer: WindowVisionRecognizing {
    func recognize(image: CGImage, region: CGRect) async throws -> [WindowVisionLine] {
        guard WindowVisionSizePolicy.accepts(width: Double(image.width),
                                             height: Double(image.height)),
              WindowVisionRegionPolicy.pixelRect(region, image: image) != nil else {
            throw WindowVisionError.invalidWindow
        }
        let box = WindowVisionImageBox(image)
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try Self.recognizeSynchronously(image: box.image, region: region)
        }
        return try await withTaskCancellationHandler {
            let lines = try await worker.value
            try Task.checkCancellation()
            return lines
        } onCancel: {
            worker.cancel()
        }
    }

    private static func recognizeSynchronously(image: CGImage,
                                               region: CGRect) throws -> [WindowVisionLine] {
        var lines: [WindowVisionLine] = []
        try Task.checkCancellation()
        guard let pixels = WindowVisionRegionPolicy.pixelRect(region, image: image),
              let crop = image.cropping(to: pixels) else { throw WindowVisionError.invalidWindow }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["zh-Hans", "en-US"].filter(supported.contains)
        let handler = VNImageRequestHandler(cgImage: crop)
        try handler.perform([request])
        try Task.checkCancellation()
        for observation in request.results ?? [] {
            guard let choice = observation.topCandidates(1).first,
                  !choice.string.isEmpty else { continue }
            let box = observation.boundingBox
            let rect = CGRect(x: (pixels.minX + box.minX * pixels.width) / CGFloat(image.width),
                              y: (pixels.minY + (1 - box.maxY) * pixels.height) / CGFloat(image.height),
                              width: box.width * pixels.width / CGFloat(image.width),
                              height: box.height * pixels.height / CGFloat(image.height))
            lines.append(WindowVisionLine(text: choice.string, confidence: choice.confidence,
                                          rect: rect, region: "selection"))
        }
        return lines
    }
}
