// Independent, bounded test of the public ScreenCaptureKit filter transition.
// Images and OCR text stay in memory. Output contains only a fixed-marker match and image statistics.
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage
import Vision

private let bundleID = "com.tencent.xinWeChat"
private let marker = "ORBIT_CAPTURE_TEST_20261024"

private struct Arguments {
    let windowID: CGWindowID
    let displayID: CGDirectDisplayID
    let title: String
    let extraTwoSeconds: Bool

    static func parse() -> Arguments? {
        let args = Array(CommandLine.arguments.dropFirst())
        var values: [String: String] = [:]
        var acknowledged = false
        var extra = false
        var index = 0
        while index < args.count {
            let argument = args[index]
            if argument == "--acknowledge-test-window" && !acknowledged {
                acknowledged = true
                index += 1
            } else if argument == "--extra-two-seconds" && !extra {
                extra = true
                index += 1
            } else if ["--window-id", "--display-id", "--title"].contains(argument),
                      index + 1 < args.count, values[argument] == nil {
                values[argument] = args[index + 1]
                index += 2
            } else {
                return nil
            }
        }
        guard acknowledged,
              let windowText = values["--window-id"], let windowID = UInt32(windowText), windowID > 0,
              let displayText = values["--display-id"], let displayID = UInt32(displayText), displayID > 0,
              let title = values["--title"], ["微信", "Weixin"].contains(title) else { return nil }
        return Arguments(windowID: windowID, displayID: displayID, title: title,
                         extraTwoSeconds: extra)
    }
}

private struct Selection {
    let app: SCRunningApplication
    let window: SCWindow
    let display: SCDisplay
    let frame: CGRect
    let sharingState: Int?
}

private enum ProbeFailure: String, Error {
    case permissionMissing = "screen_recording_permission_missing"
    case processNotUnique = "wechat_process_not_unique"
    case targetNotUnique = "target_main_window_not_unique"
    case displayMismatch = "target_not_contained_in_display"
    case targetChanged = "target_changed"
    case streamStopped = "stream_stopped"
}

private func emit(_ values: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return }
    print(String(decoding: data, as: UTF8.self))
}

private func select(_ args: Arguments) async throws -> Selection {
    let processes = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID }
    guard processes.count == 1, let process = processes.first else { throw ProbeFailure.processNotUnique }
    let content = try await SCShareableContent.current
    let matches = content.windows.filter {
        $0.windowID == args.windowID && $0.title == args.title && $0.windowLayer == 0 &&
        $0.isOnScreen && $0.owningApplication?.processID == process.processIdentifier &&
        $0.owningApplication?.bundleIdentifier == bundleID &&
        $0.frame.width >= 300 && $0.frame.height >= 300 &&
        $0.frame.width <= 4096 && $0.frame.height <= 4096
    }
    guard matches.count == 1, let window = matches.first,
          let app = window.owningApplication else { throw ProbeFailure.targetNotUnique }
    guard let display = content.displays.first(where: { $0.displayID == args.displayID }),
          display.frame.contains(window.frame) else { throw ProbeFailure.displayMismatch }
    let metadata = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                               kCGNullWindowID) as? [[String: Any]] ?? []
    let sharing = metadata.first {
        ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == window.windowID &&
        ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processID
    }.flatMap { ($0[kCGWindowSharingState as String] as? NSNumber)?.intValue }
    return Selection(app: app, window: window, display: display,
                     frame: window.frame, sharingState: sharing)
}

private func verify(_ original: Selection, _ args: Arguments) async throws {
    let current = try await select(args)
    guard current.app.processID == original.app.processID,
          current.window.windowID == original.window.windowID,
          current.display.displayID == original.display.displayID,
          current.frame == original.frame else { throw ProbeFailure.targetChanged }
}

private final class Receiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let context = CIContext()
    private var armTime = Double.infinity
    private var lastKeptTime = -Double.infinity
    private var images: [CGImage] = []
    private var latestImage: CGImage?
    private var latestPhase = "none"
    private var latestAfterUpdate = false
    private var phase = "app_warmup"
    private var warmImage: CGImage?
    private var callbacks = 0
    private var invalid = 0
    private var missingImageBuffer = 0
    private var oldTimestamp = 0
    private var newTimestamp = 0
    private var stopped = false

    func beginUpdate() {
        lock.lock()
        warmImage = latestPhase == "app_warmup" ? latestImage : nil
        phase = "filter_update"
        lock.unlock()
    }

    func arm() {
        lock.lock()
        images.removeAll()
        callbacks = 0; invalid = 0; missingImageBuffer = 0
        oldTimestamp = 0; newTimestamp = 0
        lastKeptTime = -Double.infinity
        armTime = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        phase = "post_update"
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); stopped = true; lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        lock.lock(); callbacks += 1; lock.unlock()
        guard CMSampleBufferIsValid(sample) else {
            lock.lock(); invalid += 1; lock.unlock(); return
        }
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
            lock.lock(); missingImageBuffer += 1; lock.unlock(); return
        }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        lock.lock()
        let callbackPhase = phase
        let afterUpdate = pts.isFinite && pts >= armTime
        if afterUpdate { newTimestamp += 1 } else { oldTimestamp += 1 }
        // Keep at most eleven images total: nine strict frames, one warm frame, one rolling latest.
        let keep = !stopped && afterUpdate && images.count < 9 && pts >= lastKeptTime + 0.20
        if keep { lastKeptTime = pts }
        lock.unlock()
        let input = CIImage(cvPixelBuffer: buffer)
        guard let image = context.createCGImage(input, from: input.extent) else { return }
        lock.lock()
        // One rolling image mirrors Gist latest(); strict post-update frames remain separate.
        latestImage = image
        latestPhase = callbackPhase
        latestAfterUpdate = afterUpdate
        if keep && !stopped && images.count < 9 { images.append(image) }
        lock.unlock()
    }

    func take() -> ([CGImage], CGImage?, CGImage?, String, Bool, [String: Any], Bool) {
        lock.lock(); defer { lock.unlock() }
        return (images, warmImage, latestImage, latestPhase, latestAfterUpdate,
                ["callbacks": callbacks, "invalid_samples": invalid,
                         "missing_image_buffers": missingImageBuffer,
                         "pre_update_pts": oldTimestamp, "post_update_pts": newTimestamp,
                         "retained_frames": images.count], stopped)
    }
}

private func summarize(_ image: CGImage) -> [String: Any] {
    var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
    let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
        guard let canvas = CGContext(data: bytes.baseAddress, width: 64, height: 64,
                                     bitsPerComponent: 8, bytesPerRow: 256,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        return true
    }
    let rgb = stride(from: 0, to: pixels.count, by: 4).map {
        (Double(pixels[$0]) + Double(pixels[$0 + 1]) + Double(pixels[$0 + 2])) / 3
    }
    let mean = rgb.reduce(0, +) / Double(rgb.count)
    let variance = rendered ? rgb.reduce(0) { $0 + pow($1 - mean, 2) } / Double(rgb.count) : 0
    let alpha = stride(from: 3, to: pixels.count, by: 4).map { Int(pixels[$0]) }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    try? VNImageRequestHandler(cgImage: image).perform([request])
    let match = (request.results ?? []).contains {
        $0.topCandidates(1).first?.string.contains(marker) == true
    }
    return ["width": image.width, "height": image.height,
            "mean_rgb": mean, "rgb_variance": variance,
            "alpha_min": alpha.min() ?? 0, "alpha_max": alpha.max() ?? 0,
            "test_text_match": match]
}

@main private struct GistExactCapture {
    static func main() async {
        guard let args = Arguments.parse() else {
            emit(["status": "blocked", "reason": "explicit_test_window_acknowledgement_and_target_required",
                  "usage": "--acknowledge-test-window --window-id <id> --display-id <id> --title 微信 [--extra-two-seconds]"])
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            emit(["status": "blocked", "reason": ProbeFailure.permissionMissing.rawValue])
            return
        }
        do {
            let target = try await select(args)
            let config = SCStreamConfiguration()
            config.width = Int(target.frame.width)
            config.height = Int(target.frame.height)
            config.showsCursor = false
            config.minimumFrameInterval = CMTime(seconds: 0.5, preferredTimescale: 600)
            config.queueDepth = 3
            config.sourceRect = CGRect(x: target.frame.minX - target.display.frame.minX,
                                       y: target.frame.minY - target.display.frame.minY,
                                       width: target.frame.width, height: target.frame.height)
            let receiver = Receiver()
            let initial = SCContentFilter(display: target.display, including: [target.app],
                                          exceptingWindows: [])
            let stream = SCStream(filter: initial, configuration: config, delegate: receiver)
            try stream.addStreamOutput(receiver, type: .screen,
                                       sampleHandlerQueue: DispatchQueue(label: "orbit.gist.exact.frames"))
            try await verify(target, args)
            try await stream.startCapture()
            do {
                try await Task.sleep(for: .milliseconds(250))
                try await verify(target, args)
                receiver.beginUpdate()
                try await stream.updateContentFilter(
                    SCContentFilter(display: target.display, including: [target.window]))
                // Discard warmup/transition frames; only post-update PTS can qualify.
                receiver.arm()
                try await Task.sleep(for: .milliseconds(args.extraTwoSeconds ? 2550 : 550))
                try await stream.stopCapture()
                try await verify(target, args)
                let (images, warm, latest, latestPhase, latestAfterUpdate, counts, stopped) = receiver.take()
                if stopped { throw ProbeFailure.streamStopped }
                let frameStats = images.map(summarize)
                let warmStats: [String: Any] = warm.map(summarize) ?? [:]
                let latestStats: [String: Any] = latest.map(summarize) ?? [:]
                emit(["status": "completed", "method": "gist_app_then_window_filter",
                      "sharing_state": target.sharingState as Any? ?? NSNull(),
                      "window_id": target.window.windowID, "display_id": target.display.displayID,
                      "observation_ms": args.extraTwoSeconds ? 2550 : 550,
                      "receiver": counts, "frames": frameStats,
                      "gist_latest": ["phase": latestPhase,
                                      "timestamp_after_update": latestAfterUpdate,
                                      "available": latest != nil,
                                      "pixels_and_marker": latestStats],
                      "app_warm_latest": ["available": !warmStats.isEmpty,
                                          "pixels_and_marker": warmStats],
                      "test_text_match": frameStats.contains { ($0["test_text_match"] as? Bool) == true }])
            } catch {
                try? await stream.stopCapture()
                throw error
            }
        } catch {
            let reason = (error as? ProbeFailure)?.rawValue ?? "capture_or_content_error"
            emit(["status": "blocked", "reason": reason])
        }
    }
}
