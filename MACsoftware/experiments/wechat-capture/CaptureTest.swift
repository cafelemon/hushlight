// Bounded, read-only capture experiment. Never saves images or recognized text.
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage
import Vision
import ApplicationServices

struct Options {
    let mode: String
    let target: String
    let bundle: String
    let repeatCount: Int
    let testText: String
    let allowDisplay: Bool
    let settingsTitle: String?

    static func parse() -> Options? {
        var values: [String: String] = [:]
        var allowDisplay = false
        let args = Array(CommandLine.arguments.dropFirst())
        var index = 0
        while index < args.count {
            let key = args[index]
            if key == "--allow-display" { allowDisplay = true; index += 1; continue }
            guard ["--mode", "--target", "--bundle", "--repeat", "--test-text", "--settings-title"].contains(key),
                  index + 1 < args.count, !args[index + 1].hasPrefix("--"), values[key] == nil else { return nil }
            values[key] = args[index + 1]
            index += 2
        }
        let mode = (values["--mode"] ?? "A").uppercased()
        guard ["A", "B", "C", "D", "D2", "E", "F", "I"].contains(mode),
              let repeats = Int(values["--repeat"] ?? "1"), (1...5).contains(repeats) else { return nil }
        let name = values["--bundle"] ?? "微信"
        let bundle: String
        switch name {
        case "微信", "com.tencent.xinWeChat": bundle = "com.tencent.xinWeChat"
        case "计算器", "com.apple.calculator": bundle = "com.apple.calculator"
        default: return nil
        }
        let target = values["--target"] ?? "文件传输助手"
        let testText = values["--test-text"] ?? "ORBIT_CAPTURE_TEST_20261024"
        let settingsTitle = values["--settings-title"]
        guard !target.isEmpty, !testText.isEmpty, target.count <= 128, testText.count <= 128,
              settingsTitle == nil || (settingsTitle!.count >= 1 && settingsTitle!.count <= 128) else { return nil }
        return Options(mode: mode, target: target, bundle: bundle, repeatCount: repeats,
                       testText: testText, allowDisplay: allowDisplay, settingsTitle: settingsTitle)
    }
}

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    print(String(decoding: data, as: UTF8.self))
}

struct Target {
    let window: SCWindow
    let app: SCRunningApplication
    let display: SCDisplay
    let frame: CGRect
}

enum ProbeError: Error {
    case targetNotUnique, targetChanged, displayUnavailable, noFrame, accessibilityPermissionMissing, windowSharingRestricted
}

func runningApps(_ options: Options) -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == options.bundle }
}

func appVersion(_ app: NSRunningApplication?) -> String {
    app?.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "unknown"
}

func diagnosticMetadata(_ options: Options) async throws -> [String: Any] {
    let apps = runningApps(options)
    let pids = Set(apps.map(\.processIdentifier))
    let content = try await SCShareableContent.current
    let sck = content.windows.filter {
        $0.isOnScreen && $0.windowLayer == 0 && $0.owningApplication?.bundleIdentifier == options.bundle
    }
    let sckWindows: [[String: Any]] = sck.map { window in
        let title = window.title ?? ""
        return ["id": window.windowID, "pid": window.owningApplication?.processID ?? 0,
                "width": Int(window.frame.width), "height": Int(window.frame.height),
                "title_available": !title.isEmpty, "target_exact": title == options.target,
                "target_contains": title.contains(options.target),
                "english_file_transfer_match": title.localizedCaseInsensitiveContains("File Transfer")]
    }
    let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let cg = raw.filter {
        guard let pid = $0[kCGWindowOwnerPID as String] as? Int,
              let layer = $0[kCGWindowLayer as String] as? Int else { return false }
        return pids.contains(pid_t(pid)) && layer == 0
    }
    let cgWindows: [[String: Any]] = cg.map { info in
        let name = info[kCGWindowName as String] as? String ?? ""
        let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
        return ["id": info[kCGWindowNumber as String] as? Int ?? 0,
                "pid": info[kCGWindowOwnerPID as String] as? Int ?? 0,
                "width": Int((bounds["Width"] as? NSNumber)?.doubleValue ?? 0),
                "height": Int((bounds["Height"] as? NSNumber)?.doubleValue ?? 0),
                "target_match": name == options.target || name.contains(options.target),
                "sharing_state": info[kCGWindowSharingState as String] as? Int ?? -1,
                "title_available": !name.isEmpty]
    }
    let ax = axWindowCounts(options, apps)
    return ["running_process_count": apps.count, "running_pids": apps.map(\.processIdentifier),
            "app_versions": apps.map { appVersion($0) },
            "sck_visible_layer0_count": sck.count,
            "sck_title_available_count": sck.filter { !($0.title ?? "").isEmpty }.count,
            "sck_windows": sckWindows,
            "cg_visible_layer0_same_pid_count": cg.count,
            "cg_windows": cgWindows,
            "ax_permission": AXIsProcessTrusted(),
            "ax_target_title_exact_count": ax.exact,
            "ax_target_title_contains_count": ax.contains]
}

func selectTarget(_ options: Options) async throws -> Target {
    let content = try await SCShareableContent.current
    let matches = content.windows.filter {
        $0.isOnScreen && $0.windowLayer == 0 && $0.title == options.target &&
        $0.owningApplication?.bundleIdentifier == options.bundle &&
        $0.frame.width >= 80 && $0.frame.height >= 80 &&
        $0.frame.width <= 4096 && $0.frame.height <= 4096
    }
    guard matches.count == 1, let window = matches.first, let app = window.owningApplication else {
        throw ProbeError.targetNotUnique
    }
    // Respect the public WindowServer sharing flag. Metadata inventory remains available,
    // but experiments must never try to defeat an explicitly non-shared window.
    let metadata = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    if let entry = metadata.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == window.windowID &&
        ($0[kCGWindowOwnerPID as String] as? Int32) == app.processID }),
       let sharing = entry[kCGWindowSharingState as String] as? UInt32,
       sharing == CGWindowSharingType.none.rawValue {
        throw ProbeError.windowSharingRestricted
    }
    guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(window.frame) }) else {
        throw ProbeError.displayUnavailable
    }
    return Target(window: window, app: app, display: display, frame: window.frame)
}

func validate(_ original: Target, _ options: Options) async throws {
    let fresh = try await selectTarget(options)
    let a = original.frame, b = fresh.frame
    guard fresh.window.windowID == original.window.windowID,
          fresh.app.processID == original.app.processID,
          fresh.app.bundleIdentifier == original.app.bundleIdentifier,
          fresh.display.displayID == original.display.displayID,
          a.origin == b.origin, a.size == b.size else { throw ProbeError.targetChanged }
}

func selectSettings(_ options: Options, _ main: Target) async throws -> Target {
    let content = try await SCShareableContent.current
    let matches = content.windows.filter {
        let title = $0.title ?? ""
        let titleMatches = options.settingsTitle.map { title == $0 } ?? (title == "设置" || title == "Settings")
        return $0.isOnScreen && $0.windowLayer == 0 && titleMatches &&
            $0.owningApplication?.processID == main.app.processID &&
            $0.owningApplication?.bundleIdentifier == options.bundle &&
            $0.windowID != main.window.windowID &&
            $0.frame.width >= 80 && $0.frame.height >= 80 &&
            $0.frame.width <= 4096 && $0.frame.height <= 4096 &&
            CGDisplayBounds(main.display.displayID).contains($0.frame)
    }
    guard matches.count == 1, let window = matches.first, let app = window.owningApplication else {
        throw ProbeError.targetNotUnique
    }
    return Target(window: window, app: app, display: main.display, frame: window.frame)
}

func validateSettings(_ original: Target, _ options: Options, _ main: Target) async throws {
    let fresh = try await selectSettings(options, main)
    guard fresh.window.windowID == original.window.windowID,
          fresh.app.processID == original.app.processID,
          fresh.app.bundleIdentifier == original.app.bundleIdentifier,
          fresh.frame == original.frame,
          fresh.display.displayID == original.display.displayID else { throw ProbeError.targetChanged }
}

final class Frames: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var floor = Double.infinity
    private var frame: CGImage?
    private var count = 0
    private var stopped = false
    private var rawCallbacks = 0
    private var validSamples = 0
    private var imageBuffers = 0
    private var ptsBeforeArm = 0
    private var ptsAfterArm = 0
    private var ptsInvalid = 0
    private var displayTimePresent = 0
    private var displayTimeBeforeArm = 0
    private var displayTimeAfterArm = 0
    private var ptsDeltaRange: ClosedRange<Double>?
    private var displayDeltaRange: ClosedRange<Double>?

    func arm() {
        lock.lock()
        frame = nil; count = 0
        rawCallbacks = 0; validSamples = 0; imageBuffers = 0
        ptsBeforeArm = 0; ptsAfterArm = 0; ptsInvalid = 0
        displayTimePresent = 0; displayTimeBeforeArm = 0; displayTimeAfterArm = 0
        ptsDeltaRange = nil; displayDeltaRange = nil
        floor = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        lock.unlock()
    }
    func result() -> (CGImage?, Int, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (frame, count, stopped)
    }
    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var values: [String: Any] = [
            "raw_callback_count": rawCallbacks, "valid_sample_count": validSamples,
            "image_buffer_count": imageBuffers, "accepted_frame_count": count,
            "pts_before_arm_count": ptsBeforeArm, "pts_after_arm_count": ptsAfterArm,
            "pts_invalid_count": ptsInvalid, "display_time_present_count": displayTimePresent,
            "display_time_before_arm_count": displayTimeBeforeArm,
            "display_time_after_arm_count": displayTimeAfterArm,
            "stream_stopped_with_error": stopped
        ]
        if let range = ptsDeltaRange {
            values["pts_minus_arm_ms_min"] = range.lowerBound
            values["pts_minus_arm_ms_max"] = range.upperBound
        }
        if let range = displayDeltaRange {
            values["display_time_minus_arm_ms_min"] = range.lowerBound
            values["display_time_minus_arm_ms_max"] = range.upperBound
        }
        return values
    }
    private func expanded(_ range: ClosedRange<Double>?, with value: Double) -> ClosedRange<Double> {
        guard let range else { return value...value }
        return min(range.lowerBound, value)...max(range.upperBound, value)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); stopped = true; lock.unlock()
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        lock.lock(); rawCallbacks += 1; lock.unlock()
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        lock.lock(); validSamples += 1; lock.unlock()
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]]
        let displayUnits = (attachments?.first?[SCStreamFrameInfo.displayTime.rawValue] as? NSNumber)?.uint64Value
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        lock.lock()
        imageBuffers += 1
        if pts.isFinite {
            let delta = (pts - floor) * 1000
            ptsDeltaRange = expanded(ptsDeltaRange, with: delta)
            if pts >= floor { ptsAfterArm += 1 } else { ptsBeforeArm += 1 }
        } else { ptsInvalid += 1 }
        if let displayUnits {
            let displaySeconds = CMTimeGetSeconds(CMClockMakeHostTimeFromSystemUnits(displayUnits))
            if displaySeconds.isFinite {
                displayTimePresent += 1
                let delta = (displaySeconds - floor) * 1000
                displayDeltaRange = expanded(displayDeltaRange, with: delta)
                if displaySeconds >= floor { displayTimeAfterArm += 1 }
                else { displayTimeBeforeArm += 1 }
            }
        }
        let accepted = !stopped && pts.isFinite && pts >= floor
        if accepted { count += 1 }
        let needsImage = accepted && frame == nil
        lock.unlock()
        guard needsImage else { return }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let image = CIContext().createCGImage(ci, from: ci.extent) else { return }
        lock.lock()
        if frame == nil && !stopped && pts >= floor { frame = image }
        lock.unlock()
    }
}

final class CaptureDiagnostics {
    var phase = "preparing"
    var warmReceiver: [String: Any]?
    var postReceiver: [String: Any]?
    var warmCount = 0
    var settingsWindowID: CGWindowID?
    var configurationUpdated = false
    var filterUpdated = false

    func fields() -> [String: Any] {
        var result: [String: Any] = ["phase": phase, "warm_count": warmCount]
        if let warmReceiver { result["warm_receiver"] = warmReceiver }
        if let postReceiver { result["post_receiver"] = postReceiver }
        if let settingsWindowID { result["settings_window_id"] = settingsWindowID }
        result["configuration_updated"] = configurationUpdated
        result["filter_updated"] = filterUpdated
        return result
    }
}

func configuration(_ target: Target, displayCrop: Bool) -> SCStreamConfiguration {
    let config = SCStreamConfiguration()
    config.width = Int(target.frame.width)
    config.height = Int(target.frame.height)
    config.capturesAudio = false
    config.showsCursor = false
    config.includeChildWindows = false
    config.queueDepth = 3
    config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
    if displayCrop {
        let bounds = CGDisplayBounds(target.display.displayID)
        config.sourceRect = CGRect(x: target.frame.minX - bounds.minX,
                                   y: target.frame.minY - bounds.minY,
                                   width: target.frame.width, height: target.frame.height)
    }
    return config
}

func applicationFilter(_ target: Target) async throws -> SCContentFilter {
    let content = try await SCShareableContent.current
    let others = content.windows.filter {
        $0.owningApplication?.processID == target.app.processID && $0.windowID != target.window.windowID
    }
    return SCContentFilter(display: target.display, including: [target.app], exceptingWindows: others)
}

func streamImage(_ options: Options, _ target: Target, _ diagnostics: CaptureDiagnostics) async throws -> (CGImage, Int) {
    let mode = options.mode
    let appFilter = try mode == "C" || mode == "D" ? await applicationFilter(target) : nil
    let filter: SCContentFilter
    switch mode {
    case "B": filter = SCContentFilter(desktopIndependentWindow: target.window)
    case "C", "D": filter = appFilter!
    default: filter = SCContentFilter(display: target.display, excludingWindows: [])
    }
    let frames = Frames()
    let stream = SCStream(filter: filter,
                          configuration: configuration(target, displayCrop: mode != "B"),
                          delegate: frames)
    try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: DispatchQueue(label: "orbit.capture.experiment"))
    try await validate(target, options)
    frames.arm()
    diagnostics.phase = "starting_stream"
    try await stream.startCapture()
    do {
        let captureDeadline = Date().addingTimeInterval(3.9)
        if mode == "D" {
            diagnostics.phase = "warmup_250ms"
            try await Task.sleep(for: .milliseconds(250))
            diagnostics.warmReceiver = frames.snapshot()
            diagnostics.warmCount = frames.result().1
            try await validate(target, options)
            diagnostics.phase = "updating_filter"
            try await stream.updateContentFilter(SCContentFilter(display: target.display, including: [target.window]))
            // Warmup frames are discarded; only PTS after this arm can be reported.
            frames.arm()
            diagnostics.phase = "post_filter_wait"
        } else {
            diagnostics.phase = "frame_wait"
        }
        let postDeadline = min(Date().addingTimeInterval(3.0), captureDeadline)
        while Date() < postDeadline {
            if frames.result().0 != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        diagnostics.phase = "stopping_stream"
        try await stream.stopCapture()
        diagnostics.postReceiver = frames.snapshot()
        diagnostics.phase = "validating_target"
        try await validate(target, options)
        let (image, count, _) = frames.result()
        guard let image else {
            diagnostics.phase = mode == "D" ? "post_filter_no_frame" : "no_frame"
            throw ProbeError.noFrame
        }
        diagnostics.phase = "completed"
        return (image, count)
    } catch {
        try? await stream.stopCapture()
        if diagnostics.phase == "post_filter_wait" || diagnostics.phase == "stopping_stream" ||
            diagnostics.phase == "validating_target" || diagnostics.phase == "post_filter_no_frame" ||
            diagnostics.phase == "no_frame" || diagnostics.phase == "frame_wait" {
            diagnostics.postReceiver = frames.snapshot()
        }
        throw error
    }
}

func streamD2(_ options: Options, _ main: Target, _ diagnostics: CaptureDiagnostics) async throws -> (CGImage, Int) {
    let settings = try await selectSettings(options, main)
    diagnostics.settingsWindowID = settings.window.windowID
    let content = try await SCShareableContent.current
    let excluded = content.windows.filter {
        $0.owningApplication?.processID == main.app.processID && $0.windowID != settings.window.windowID
    }
    let initial = SCContentFilter(display: main.display, including: [main.app], exceptingWindows: excluded)
    let frames = Frames()
    let stream = SCStream(filter: initial, configuration: configuration(settings, displayCrop: true), delegate: frames)
    try stream.addStreamOutput(frames, type: .screen,
                               sampleHandlerQueue: DispatchQueue(label: "orbit.capture.experiment.d2"))
    try await validate(main, options)
    try await validateSettings(settings, options, main)
    frames.arm()
    diagnostics.phase = "starting_settings_stream"
    try await stream.startCapture()
    do {
        let captureDeadline = Date().addingTimeInterval(3.9)
        let warmDeadline = Date().addingTimeInterval(1.0)
        diagnostics.phase = "settings_warmup"
        try await Task.sleep(for: .milliseconds(250))
        while Date() < warmDeadline && frames.result().0 == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        diagnostics.warmReceiver = frames.snapshot()
        diagnostics.warmCount = frames.result().1
        try await validate(main, options)
        try await validateSettings(settings, options, main)
        diagnostics.phase = "updating_configuration"
        try await stream.updateConfiguration(configuration(main, displayCrop: true))
        diagnostics.configurationUpdated = true
        diagnostics.phase = "updating_filter"
        try await stream.updateContentFilter(SCContentFilter(display: main.display, including: [main.window]))
        diagnostics.filterUpdated = true
        frames.arm()
        diagnostics.phase = "post_filter_wait"
        let postDeadline = min(Date().addingTimeInterval(3.0), captureDeadline)
        while Date() < postDeadline && frames.result().0 == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        diagnostics.phase = "stopping_stream"
        try await stream.stopCapture()
        diagnostics.postReceiver = frames.snapshot()
        diagnostics.phase = "validating_target"
        try await validate(main, options)
        try await validateSettings(settings, options, main)
        let (image, count, _) = frames.result()
        guard let image else {
            diagnostics.phase = "post_filter_no_frame"
            throw ProbeError.noFrame
        }
        diagnostics.phase = "completed"
        return (image, count)
    } catch {
        try? await stream.stopCapture()
        if diagnostics.filterUpdated { diagnostics.postReceiver = frames.snapshot() }
        throw error
    }
}

func imageStatistics(_ image: CGImage, testText: String) -> [String: Any] {
    var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
    let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(data: raw.baseAddress, width: 64, height: 64,
                                      bitsPerComponent: 8, bytesPerRow: 256,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        return true
    }
    let values = stride(from: 0, to: bytes.count, by: 4).map {
        (Double(bytes[$0]) + Double(bytes[$0 + 1]) + Double(bytes[$0 + 2])) / 3
    }
    let mean = values.reduce(0, +) / Double(values.count)
    let variance = drawn ? values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count) : 0
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    try? VNImageRequestHandler(cgImage: image).perform([request])
    let lines = request.results ?? []
    let matched = lines.contains { $0.topCandidates(1).first?.string.contains(testText) == true }
    let alpha = stride(from: 3, to: bytes.count, by: 4).map { Int(bytes[$0]) }
    return ["image_width": image.width, "image_height": image.height,
            "mean_rgb": mean, "alpha_min": alpha.min() ?? 0, "alpha_max": alpha.max() ?? 0,
            "alpha_mean": Double(alpha.reduce(0,+)) / Double(alpha.count),
            "variance": variance, "ocr_line_count": lines.count, "test_text_match": matched]
}

func axValue(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute, &value) == .success ? value : nil
}

func axGeometry(_ element: AXUIElement) -> CGRect? {
    guard let position = axValue(element, kAXPositionAttribute as CFString),
          let size = axValue(element, kAXSizeAttribute as CFString),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
    return CGRect(origin: point, size: dimensions)
}

func axWindows(_ app: NSRunningApplication) -> [AXUIElement] {
    let element = AXUIElementCreateApplication(app.processIdentifier)
    return axValue(element, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
}

func axWindowCounts(_ options: Options, _ apps: [NSRunningApplication]) -> (exact: Int, contains: Int) {
    guard AXIsProcessTrusted() else { return (0, 0) }
    let titles = apps.flatMap(axWindows).compactMap { axValue($0, kAXTitleAttribute as CFString) as? String }
    return (titles.filter { $0 == options.target }.count,
            titles.filter { $0.contains(options.target) }.count)
}

struct AXTarget {
    let element: AXUIElement
    let pid: pid_t
    let frame: CGRect
}

func selectAXTarget(_ options: Options) throws -> AXTarget {
    guard AXIsProcessTrusted() else { throw ProbeError.accessibilityPermissionMissing }
    let apps = runningApps(options)
    let candidates: [(AXUIElement, pid_t, CGRect, String)] = apps.flatMap { app in
        axWindows(app).compactMap { window in
            guard let title = axValue(window, kAXTitleAttribute as CFString) as? String,
                  let frame = axGeometry(window), frame.width >= 80, frame.height >= 80 else { return nil }
            return (window, app.processIdentifier, frame, title)
        }
    }
    let exact = candidates.filter { $0.3 == options.target }
    let matches = exact.isEmpty ? candidates.filter { $0.3.contains(options.target) } : exact
    guard matches.count == 1, let chosen = matches.first else { throw ProbeError.targetNotUnique }
    return AXTarget(element: chosen.0, pid: chosen.1, frame: chosen.2)
}

func validateAX(_ original: AXTarget, _ options: Options) throws {
    let fresh = try selectAXTarget(options)
    var pid: pid_t = 0
    guard AXUIElementGetPid(original.element, &pid) == .success,
          pid == original.pid, fresh.pid == original.pid,
          CFEqual(fresh.element, original.element),
          fresh.frame == original.frame,
          axGeometry(original.element) == original.frame else { throw ProbeError.targetChanged }
}

func axMatchCount(_ options: Options, _ target: AXTarget) -> (Int, Int) {
    let root = target.element
    var pending: [(AXUIElement, Int)] = [(root, 0)]
    var visited = 0, matched = 0
    while !pending.isEmpty && visited < 500 {
        let (node, depth) = pending.removeFirst()
        visited += 1
        for key in [kAXValueAttribute, kAXDescriptionAttribute] {
            if let string = axValue(node, key as CFString) as? String, string.contains(options.testText) { matched += 1 }
        }
        if depth < 8, let children = axValue(node, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            pending.append(contentsOf: children.prefix(min(100, max(0, 500 - pending.count))).map { ($0, depth + 1) })
        }
    }
    return (visited, matched)
}

@main struct Main {
    static func main() async {
        guard let options = Options.parse() else {
            emit(["status": "blocked", "reason": "invalid_arguments_or_bundle_allowlist",
                  "usage": "--mode A|B|C|D|D2|E|F|I [--target title] [--settings-title title for D2] [--bundle 微信|计算器] [--repeat 1..5] [--test-text marker] [--allow-display for E]"])
            return
        }
        if options.mode == "E" && !options.allowDisplay {
            emit(["status": "blocked", "reason": "display_capture_requires_allow_display", "prompted": false])
            return
        }
        if options.mode == "F" && !AXIsProcessTrusted() {
            emit(["status": "blocked", "reason": "accessibility_permission_missing", "prompted": false])
            return
        }
        if options.mode != "F" && !CGPreflightScreenCaptureAccess() {
            emit(["status": "blocked", "reason": "screen_capture_permission_missing", "prompted": false])
            return
        }
        let architecture: String
        #if arch(arm64)
        architecture = "arm64"
        #elseif arch(x86_64)
        architecture = "x86_64"
        #else
        architecture = "other"
        #endif
        for attempt in 1...options.repeatCount {
            let started = CFAbsoluteTimeGetCurrent()
            let diagnostics = CaptureDiagnostics()
            do {
                if options.mode == "I" {
                    var result = try await diagnosticMetadata(options)
                    result["status"] = "completed"
                    result["mode"] = "I"
                    result["attempt"] = attempt
                    result["macos"] = ProcessInfo.processInfo.operatingSystemVersionString
                    result["architecture"] = architecture
                    result["duration_ms"] = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
                    emit(result)
                    continue
                }
                if options.mode == "F" {
                    let target = try selectAXTarget(options)
                    try validateAX(target, options)
                    let (visited, matched) = axMatchCount(options, target)
                    try validateAX(target, options)
                    emit(["status": "completed", "mode": "F", "attempt": attempt,
                          "method": "AX.bounded_tree", "macos": ProcessInfo.processInfo.operatingSystemVersionString,
                          "architecture": architecture, "bundle": options.bundle,
                          "app_version": appVersion(NSRunningApplication(processIdentifier: target.pid)),
                          "pid": target.pid, "window_width": Int(target.frame.width),
                          "window_height": Int(target.frame.height), "ax_nodes_visited": visited,
                          "test_text_match": matched > 0, "match_count": matched,
                          "frame_count": 0, "saved_image": false,
                          "duration_ms": Int((CFAbsoluteTimeGetCurrent() - started) * 1000)])
                    continue
                }
                let target = try await selectTarget(options)
                try await validate(target, options)
                let runningApp = NSRunningApplication(processIdentifier: target.app.processID)
                var result: [String: Any] = [
                    "status": "completed", "mode": options.mode, "attempt": attempt,
                    "method": ["A": "SCScreenshotManager.window", "B": "SCStream.desktopIndependentWindow",
                               "C": "SCStream.application_excluding_other_windows",
                               "D": "SCStream.application_then_update_window",
                               "D2": "SCStream.settings_warmup_then_update_main_window",
                               "E": "SCStream.display_cropped_to_window"][options.mode]!,
                    "macos": ProcessInfo.processInfo.operatingSystemVersionString,
                    "architecture": architecture, "app_version": appVersion(runningApp),
                    "bundle": options.bundle, "window_id": target.window.windowID,
                    "pid": target.app.processID, "window_width": Int(target.frame.width),
                    "window_height": Int(target.frame.height), "saved_image": false
                ]
                if options.mode == "A" {
                    let filter = SCContentFilter(desktopIndependentWindow: target.window)
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                             configuration: configuration(target, displayCrop: false))
                    try await validate(target, options)
                    result["frame_count"] = 1
                    result.merge(imageStatistics(image, testText: options.testText)) { _, new in new }
                } else {
                    let (image, count) = try options.mode == "D2"
                        ? await streamD2(options, target, diagnostics)
                        : await streamImage(options, target, diagnostics)
                    result["frame_count"] = count
                    result.merge(imageStatistics(image, testText: options.testText)) { _, new in new }
                    result.merge(diagnostics.fields()) { _, new in new }
                }
                result["duration_ms"] = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
                emit(result)
            } catch {
                let nsError = error as NSError
                let probe = error as? ProbeError
                var failure: [String: Any] = ["status": "failed", "mode": options.mode, "attempt": attempt,
                                                   "error_type": String(reflecting: type(of: error)),
                                                   "error_case": probe.map { String(describing: $0) } ?? "api_error",
                                                   "error_domain": nsError.domain, "error_code": nsError.code,
                                                   "duration_ms": Int((CFAbsoluteTimeGetCurrent() - started) * 1000)]
                if ["B", "C", "D", "D2", "E"].contains(options.mode) {
                    failure.merge(diagnostics.fields()) { _, new in new }
                }
                emit(failure)
            }
        }
    }
}
