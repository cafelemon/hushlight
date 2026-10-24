import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct QQSongNativeWindow: Equatable, Sendable {
    let window: WindowVisionWindow
    let frame: CGRect
}

enum QQSongGeometryPolicy {
    static func valid(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.maxX.isFinite && rect.maxY.isFinite &&
            rect.width > 0 && rect.height > 0 && rect.width <= 8_192 && rect.height <= 8_192
    }

    static func contains(_ field: CGRect, in window: CGRect) -> Bool {
        valid(window) && valid(field) && window.contains(field) &&
            window.contains(CGPoint(x: field.midX, y: field.midY))
    }

    static func point(for region: CGRect, in window: CGRect) -> CGPoint? {
        guard valid(window), ExactWindowTextSelector.valid(region) else { return nil }
        let point = CGPoint(x: window.minX + window.width * region.midX,
                            y: window.minY + window.height * region.midY)
        return point.x.isFinite && point.y.isFinite && window.contains(point) ? point : nil
    }
}

@MainActor
protocol QQSongNativeSurface: Sendable {
    /// May activate only an already running QQ process, after explicit authorization.
    func prepare(authorize: @escaping @Sendable () async -> Bool) async throws
    /// Requires existing AX permission, one QQ process, one QQMianWindow and QQ foreground.
    func inspectWindow() throws -> QQSongNativeWindow
    func submitSearch(_ query: String, in window: QQSongNativeWindow,
                      authorize: @escaping @Sendable () async -> Bool) async throws
    /// Checks authorization and current window immediately before each mouse event.
    /// Once an event is posted, failure is an unknown playback outcome.
    func doubleClick(_ region: CGRect, in window: QQSongNativeWindow,
                     authorize: @escaping @Sendable () async -> Bool) async throws
}

extension QQSongNativeSurface {
    func prepare(authorize: @escaping @Sendable () async -> Bool) async throws { }
}

@MainActor
final class NativeQQSongSearchBackend: QQSongSearchPlaying {
    private let surface: any QQSongNativeSurface
    private let vision: any WindowVisionProviding
    private let selector: any QQSongSelecting
    private let playback: any QQMusicPlaybackProviding
    private let pollAttempts: Int
    private let pollInterval: Duration
    private let searchSamples: Int
    private let searchSampleInterval: Duration
    private static let fullWindow = CGRect(x: 0, y: 0, width: 1, height: 1)

    init(surface: any QQSongNativeSurface = NativeQQSongSurface(),
         vision: any WindowVisionProviding = NativeWindowVisionBackend(),
         selector: any QQSongSelecting = QQSongSelector(),
         playback: any QQMusicPlaybackProviding = QQMusicPlaybackBackend(),
         pollAttempts: Int = 10, pollInterval: Duration = .milliseconds(150),
         searchSamples: Int = 12, searchSampleInterval: Duration = .milliseconds(250)) {
        self.surface = surface
        self.vision = vision
        self.selector = selector
        self.playback = playback
        self.pollAttempts = max(1, pollAttempts)
        self.pollInterval = pollInterval
        self.searchSamples = max(1, searchSamples)
        self.searchSampleInterval = searchSampleInterval
    }

    func play(_ request: QQSongRequest,
              authorize: @escaping @Sendable () async -> Bool,
              beforePlay: @escaping @Sendable () async throws -> Void) async throws -> QQMusicPlayback {
        try request.validate()
        try await requireAuthorization(authorize)
        try await surface.prepare(authorize: authorize)
        for attempt in 1...2 {
            try await requireAuthorization(authorize)
            let window = try surface.inspectWindow()
            guard await vision.permissionGranted() else { throw QQSongSearchError.permissionRequired }
            try await requireAuthorization(authorize)
            let query = request.query.folding(options: [.widthInsensitive], locale: Locale(identifier: "zh_CN"))
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            try await surface.submitSearch(query, in: window, authorize: authorize)
            try await requireAuthorization(authorize)
            guard try surface.inspectWindow() == window else { throw QQSongSearchError.unavailableWindow }
            let candidate = try await locateCandidate(request, in: window, authorize: authorize)
            try await requireAuthorization(authorize)
            guard try surface.inspectWindow() == window else { throw QQSongSearchError.unavailableWindow }

            // Read the track before clicking. An unchanged old track after the click does
            // not prove that the requested row played, so it cannot authorize a retry.
            let baseline = try? await playback.read()
            try await requireAuthorization(authorize)
            guard try surface.inspectWindow() == window else { throw QQSongSearchError.unavailableWindow }

            // The durable admission is adjacent to the native playback attempt. No further
            // candidate search or OCR is permitted after an uncertain click.
            try await beforePlay()
            try await requireAuthorization(authorize)
            do {
                try await surface.doubleClick(candidate.region, in: window, authorize: authorize)
            } catch let error as QQSongSearchError {
                throw error
            } catch {
                throw QQSongSearchError.unknownOutcome
            }

            let observation = await readAfterClick(candidate: candidate, request: request,
                                                   baseline: baseline)
            switch observation {
            case .matched(let value): return value
            case .different:
                if attempt == 2 { throw QQSongSearchError.unknownOutcome }
                // Only a positively identified wrong track permits one fresh search.
            case .unknown: throw QQSongSearchError.unknownOutcome
            }
        }
        throw QQSongSearchError.unknownOutcome
    }

    private func locateCandidate(_ request: QQSongRequest, in window: QQSongNativeWindow,
                                 authorize: @escaping @Sendable () async -> Bool) async throws -> QQSongCandidate {
        var lastSelectionError: QQSongSearchError = .notFound
        for sample in 0..<searchSamples {
            try await requireAuthorization(authorize)
            guard await vision.permissionGranted() else { throw QQSongSearchError.permissionRequired }
            guard try surface.inspectWindow() == window else { throw QQSongSearchError.unavailableWindow }
            let preview: WindowVisionPreview
            do { preview = try await vision.capturePreview(window: window.window) }
            catch { throw mapVision(error) }
            try await requireAuthorization(authorize)
            guard preview.window == window.window else { throw QQSongSearchError.unavailableWindow }
            let recognized: WindowVisionResult
            do { recognized = try await vision.recognize(preview: preview, region: Self.fullWindow) }
            catch { throw mapVision(error) }
            try await requireAuthorization(authorize)
            guard recognized.window == window.window,
                  recognized.checkedAt == preview.checkedAt,
                  try surface.inspectWindow() == window else {
                throw QQSongSearchError.unavailableWindow
            }
            do {
                let candidate = try selector.choose(request, lines: recognized.lines)
                guard ExactWindowTextSelector.valid(candidate.region),
                      WindowVisionRegionPolicy.pixelRect(candidate.region, image: preview.image) != nil else {
                    throw QQSongSearchError.ambiguous
                }
                return candidate
            } catch let error as QQSongSearchError where error == .notFound {
                lastSelectionError = error
            }
            if sample < searchSamples - 1 {
                do { try await Task.sleep(for: searchSampleInterval) }
                catch { throw QQSongSearchError.unauthorized }
            }
        }
        throw lastSelectionError
    }

    private enum Observation {
        case matched(QQMusicPlayback), different, unknown
    }

    private func readAfterClick(candidate: QQSongCandidate, request: QQSongRequest,
                                baseline: QQMusicPlayback?) async -> Observation {
        var latest: Observation = .unknown
        for index in 0..<pollAttempts {
            if Task.isCancelled { return .unknown }
            do {
                let value = try await playback.read()
                if Task.isCancelled { return .unknown }
                if value.playing, let track = value.track {
                    if Self.matches(track, candidate: candidate, request: request) { return .matched(value) }
                    if let prior = baseline?.track, Self.normalizedTrack(prior) != Self.normalizedTrack(track) {
                        latest = .different
                    } else { latest = .unknown }
                } else { latest = .unknown }
            } catch {
                // A failed read after clicking cannot prove that the click did nothing.
                latest = .unknown
            }
            if index < pollAttempts - 1 {
                do { try await Task.sleep(for: pollInterval) }
                catch { return .unknown }
            }
        }
        return latest
    }

    private static func matches(_ track: String, candidate: QQSongCandidate,
                                request: QQSongRequest) -> Bool {
        let parts = track.components(separatedBy: " - ")
        guard parts.count == 2 else { return false }
        func normalize(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                          locale: Locale(identifier: "zh_CN"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard normalize(parts[1]) == normalize(candidate.artist) else { return false }
        let actualTitle = normalize(parts[0])
        let expectedTitle = normalize(candidate.title)
        guard actualTitle.hasPrefix(expectedTitle) else { return false }
        let suffix = String(actualTitle.dropFirst(expectedTitle.count))
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "()（）[]【】-—_")))
        let liveTags = ["live", "live版", "现场", "现场版", "演唱会", "实况"]
        let originalTags = ["原唱", "原版", "original", "studio", "录音室版"]
        let alternatives = ["remix", "混音", "伴奏", "instrumental", "karaoke", "翻唱", "cover",
                            "全景声", "dolby", "dj", "acoustic", "纯音乐", "剪辑", "加速", "慢速"]
        guard !alternatives.contains(where: suffix.contains) else { return false }
        switch request.version {
        case .original: return suffix.isEmpty || originalTags.contains(suffix)
        case .live: return liveTags.contains(suffix)
        }
    }

    private static func normalizedTrack(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "zh_CN"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func requireAuthorization(_ authorize: @Sendable () async -> Bool) async throws {
        try Task.checkCancellation()
        guard await authorize() else { throw QQSongSearchError.unauthorized }
        try Task.checkCancellation()
    }

    private func mapVision(_ error: Error) -> QQSongSearchError {
        if let error = error as? WindowVisionError {
            switch error {
            case .permissionRequired: return .permissionRequired
            case .unsupported, .invalidWindow, .staleWindow, .captureFailed, .sharingRestricted: return .unavailableWindow
            }
        }
        if error is CancellationError { return .unauthorized }
        return .unavailableWindow
    }
}

@MainActor
final class NativeQQSongSurface: QQSongNativeSurface {
    private let bundleID = "com.tencent.QQMusicMac"
    private let mainWindowID = "QQMianWindow"

    func prepare(authorize: @escaping @Sendable () async -> Bool) async throws {
        guard await authorize() else { throw QQSongSearchError.unauthorized }
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw QQSongSearchError.permissionRequired }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.bundleIdentifier == bundleID && !$0.isTerminated }
        guard !apps.isEmpty else { throw QQSongSearchError.notRunning }
        guard apps.count == 1, let app = apps.first else { throw QQSongSearchError.unavailableWindow }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            guard app.activate(options: [.activateIgnoringOtherApps]) else {
                throw QQSongSearchError.unavailableWindow
            }
        }
        for index in 0..<10 {
            guard await authorize() else { throw QQSongSearchError.unauthorized }
            try Task.checkCancellation()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return }
            if index < 9 { try await Task.sleep(for: .milliseconds(100)) }
        }
        throw QQSongSearchError.unavailableWindow
    }

    func inspectWindow() throws -> QQSongNativeWindow {
        guard AXIsProcessTrusted() else { throw QQSongSearchError.permissionRequired }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.bundleIdentifier == bundleID && !$0.isTerminated }
        guard !apps.isEmpty else { throw QQSongSearchError.notRunning }
        guard apps.count == 1, let app = apps.first else { throw QQSongSearchError.unavailableWindow }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw QQSongSearchError.unavailableWindow
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        guard let windows = elements(axApp, kAXWindowsAttribute as String) else {
            throw QQSongSearchError.unavailableWindow
        }
        let mains = windows.filter { string($0, kAXIdentifierAttribute as String) == mainWindowID }
        guard mains.count == 1, let main = mains.first,
              let frame = frame(of: main), QQSongGeometryPolicy.valid(frame) else {
            throw QQSongSearchError.unavailableWindow
        }
        let candidates = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                          as? [[String: Any]]) ?? []
        let matches = candidates.compactMap { entry -> WindowVisionWindow? in
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32, pid == app.processIdentifier,
                  let id = entry[kCGWindowNumber as String] as? UInt32,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  abs(rect.minX - frame.minX) <= 2, abs(rect.minY - frame.minY) <= 2,
                  abs(rect.width - frame.width) <= 2, abs(rect.height - frame.height) <= 2,
                  WindowVisionSizePolicy.accepts(width: rect.width, height: rect.height) else { return nil }
            return WindowVisionWindow(id: id, pid: pid, target: .qqMusic,
                                      width: rect.width, height: rect.height)
        }
        guard matches.count == 1, let window = matches.first else { throw QQSongSearchError.unavailableWindow }
        return QQSongNativeWindow(window: window, frame: frame)
    }

    func submitSearch(_ query: String, in window: QQSongNativeWindow,
                      authorize: @escaping @Sendable () async -> Bool) async throws {
        guard await authorize() else { throw QQSongSearchError.unauthorized }
        try Task.checkCancellation()
        guard try inspectWindow() == window else { throw QQSongSearchError.unavailableWindow }
        let app = AXUIElementCreateApplication(window.window.pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let field = try uniqueSearchField(in: app)
        guard let fieldFrame = frame(of: field),
              QQSongGeometryPolicy.contains(fieldFrame, in: window.frame) else {
            throw QQSongSearchError.unavailableWindow
        }
        guard await authorize() else { throw QQSongSearchError.unauthorized }
        try Task.checkCancellation()
        guard try inspectWindow() == window else { throw QQSongSearchError.unavailableWindow }
        try postClick(at: CGPoint(x: fieldFrame.midX, y: fieldFrame.midY))
        guard focused(field, in: app) else { throw QQSongSearchError.unavailableWindow }
        guard await authorize() else { throw QQSongSearchError.unauthorized }
        try Task.checkCancellation()
        guard try inspectWindow() == window, focused(field, in: app) else {
            throw QQSongSearchError.unavailableWindow
        }
        let setResult = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, query as CFTypeRef)
        if setResult != .success {
            // The fallback targets only the previously verified focused search field.
            guard try inspectWindow() == window, focused(field, in: app) else {
                throw QQSongSearchError.unavailableWindow
            }
            try postKey(0, flags: .maskCommand) // Command+A
            guard try inspectWindow() == window, focused(field, in: app) else {
                throw QQSongSearchError.unavailableWindow
            }
            try postUnicode(query)
        }
        guard await authorize() else { throw QQSongSearchError.unauthorized }
        try Task.checkCancellation()
        guard try inspectWindow() == window, focused(field, in: app) else {
            throw QQSongSearchError.unavailableWindow
        }
        try postKey(36) // Return submits QQ search.
    }

    func doubleClick(_ region: CGRect, in window: QQSongNativeWindow,
                     authorize: @escaping @Sendable () async -> Bool) async throws {
        guard let point = QQSongGeometryPolicy.point(for: region, in: window.frame) else {
            throw QQSongSearchError.ambiguous
        }
        var posted = false
        do {
            for clickCount in 1...2 {
                guard await authorize() else { throw QQSongSearchError.unauthorized }
                try Task.checkCancellation()
                guard try inspectWindow() == window else { throw QQSongSearchError.unavailableWindow }
                try postClick(at: point, clickCount: clickCount)
                posted = true
            }
        } catch {
            if posted { throw QQSongSearchError.unknownOutcome }
            throw error
        }
    }

    private func uniqueSearchField(in app: AXUIElement) throws -> AXUIElement {
        guard let windows = elements(app, kAXWindowsAttribute as String) else {
            throw QQSongSearchError.unavailableWindow
        }
        let mains = windows.filter { string($0, kAXIdentifierAttribute as String) == mainWindowID }
        guard mains.count == 1, let root = mains.first else { throw QQSongSearchError.unavailableWindow }
        var fields: [AXUIElement] = []
        var remaining = 240
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= 9, remaining > 0 else { return }
            remaining -= 1
            let role = string(element, kAXRoleAttribute as String)
            if role == (kAXTextFieldRole as String) {
                let labels = [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                              kAXPlaceholderValueAttribute].compactMap { string(element, $0 as String) }
                if labels.contains(where: { $0.localizedCaseInsensitiveContains("搜索") ||
                    $0.localizedCaseInsensitiveContains("search") }) { fields.append(element) }
            }
            for child in elements(element, kAXChildrenAttribute as String) ?? [] { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        guard fields.count == 1, let field = fields.first else { throw QQSongSearchError.unavailableWindow }
        return field
    }

    private func focused(_ field: AXUIElement, in app: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value else { return false }
        return CFEqual(value, field)
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private func postClick(at point: CGPoint, clickCount: Int = 1) throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else {
            throw QQSongSearchError.unavailableWindow
        }
        down.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        up.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }

    private func postKey(_ key: CGKeyCode, flags: CGEventFlags = []) throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            throw QQSongSearchError.unavailableWindow
        }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }

    private func postUnicode(_ value: String) throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw QQSongSearchError.unavailableWindow
        }
        let units = Array(value.utf16)
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
}
