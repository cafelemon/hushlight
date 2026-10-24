import AppKit
import ApplicationServices
import Foundation

struct QQMusicPlayback: Codable, Equatable, Sendable {
    let playing: Bool
    let track: String?
    let checkedAt: Date
}

enum QQMusicPlaybackAction: String, Codable, Sendable {
    case play, pause, next, previous
}

enum QQMusicPlaybackError: Error, LocalizedError, Equatable {
    case permissionRequired, notRunning, unverifiable, unknownOutcome

    var errorDescription: String? {
        switch self {
        case .permissionRequired: "QQ 音乐播放控制需要辅助功能权限。"
        case .notRunning: "QQ 音乐未运行。"
        case .unverifiable: "无法唯一确认 QQ 音乐播放控件或播放状态。"
        case .unknownOutcome: "已尝试控制 QQ 音乐，但无法确认结果。"
        }
    }
}

protocol QQMusicPlaybackProviding: Sendable {
    func read() async throws -> QQMusicPlayback
    func perform(_ action: QQMusicPlaybackAction,
                 authorize: @escaping @Sendable () async -> Bool) async throws -> QQMusicPlayback
}

struct QQMusicAXButton: Sendable {
    let key: String
    let title: String
}

struct QQMusicAXRegion: Sendable {
    let buttons: [QQMusicAXButton]
    let songTexts: [String]
}

struct QQMusicAXSnapshot: Sendable {
    let regions: [QQMusicAXRegion]
}

@MainActor
protocol QQMusicAXSurface: Sendable {
    func isTrusted() -> Bool
    func isRunning() -> Bool
    func snapshot() throws -> QQMusicAXSnapshot
    func press(buttonKey: String, expectedTitle: String) throws
}

enum QQMusicAXPreflightError: Error {
    case staleButton
}

@MainActor
final class QQMusicPlaybackBackend: QQMusicPlaybackProviding {
    private let surface: any QQMusicAXSurface

    init(surface: any QQMusicAXSurface = NativeQQMusicAXSurface()) {
        self.surface = surface
    }

    func read() async throws -> QQMusicPlayback {
        try Task.checkCancellation()
        return try observed().playback
    }

    func perform(_ action: QQMusicPlaybackAction,
                 authorize: @escaping @Sendable () async -> Bool) async throws -> QQMusicPlayback {
        try Task.checkCancellation()
        let initial = try observed()
        if let desired = action.desiredPlaying, initial.playback.playing == desired {
            return initial.playback
        }
        if action.isSkip && initial.playback.track == nil {
            throw QQMusicPlaybackError.unverifiable
        }
        guard await authorize() else { throw QQMusicPlaybackError.permissionRequired }
        try Task.checkCancellation()
        // The process, permission and exact control may have changed during authorization.
        let before = try observed()
        if let desired = action.desiredPlaying, before.playback.playing == desired {
            return before.playback
        }
        if action.isSkip && before.playback.track == nil {
            throw QQMusicPlaybackError.unverifiable
        }
        let button = try before.button(for: action)
        // This final grant follows the potentially slow AX tree scan and is adjacent to AXPress.
        guard await authorize() else { throw QQMusicPlaybackError.permissionRequired }
        try Task.checkCancellation()
        guard surface.isTrusted() else { throw QQMusicPlaybackError.permissionRequired }
        guard surface.isRunning() else { throw QQMusicPlaybackError.notRunning }
        do {
            try surface.press(buttonKey: button.key, expectedTitle: button.title)
        } catch QQMusicAXPreflightError.staleButton {
            throw QQMusicPlaybackError.unverifiable
        } catch {
            // AXPress may have taken effect even when it reports an error.
            throw QQMusicPlaybackError.unknownOutcome
        }
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if Task.isCancelled { throw QQMusicPlaybackError.unknownOutcome }
            do {
                let after = try observed()
                if Task.isCancelled { throw QQMusicPlaybackError.unknownOutcome }
                if let desired = action.desiredPlaying {
                    if after.playback.playing == desired { return after.playback }
                } else if let prior = before.playback.track,
                          let current = after.playback.track, current != prior {
                    return after.playback
                }
            } catch {
                // A read failure after pressing cannot prove that nothing happened.
            }
            if Task.isCancelled { throw QQMusicPlaybackError.unknownOutcome }
            if Date() >= deadline { break }
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { throw QQMusicPlaybackError.unknownOutcome }
        } while true
        throw QQMusicPlaybackError.unknownOutcome
    }

    private func observed() throws -> QQMusicObservation {
        guard surface.isTrusted() else { throw QQMusicPlaybackError.permissionRequired }
        guard surface.isRunning() else { throw QQMusicPlaybackError.notRunning }
        let snapshot: QQMusicAXSnapshot
        do { snapshot = try surface.snapshot() }
        catch { throw QQMusicPlaybackError.unverifiable }
        guard snapshot.regions.count == 1 else { throw QQMusicPlaybackError.unverifiable }
        let region = snapshot.regions[0]
        let stateButtons = region.buttons.filter { QQMusicControlLabel.playingState($0.title) != nil }
        guard stateButtons.count == 1 else { throw QQMusicPlaybackError.unverifiable }
        let songs = region.songTexts.compactMap(Self.parseSong)
        guard songs.count <= 1 else { throw QQMusicPlaybackError.unverifiable }
        return QQMusicObservation(playback: QQMusicPlayback(playing: QQMusicControlLabel.playingState(stateButtons[0].title) == true,
                                                             track: songs.first, checkedAt: Date()),
                                  buttons: region.buttons)
    }

    private static func parseSong(_ text: String) -> String? {
        guard text.hasPrefix("歌曲名：") else { return nil }
        let body = String(text.dropFirst("歌曲名：".count))
        let pieces = body.components(separatedBy: " - 歌手名：")
        guard pieces.count == 2 else { return nil }
        let title = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        return "\(title) - \(artist)"
    }
}

enum QQMusicControlLabel {
    static func playingState(_ title: String) -> Bool? {
        switch title {
        case "播放": false
        case "暂停", "暂停播放": true
        default: nil
        }
    }
}

private struct QQMusicObservation {
    let playback: QQMusicPlayback
    let buttons: [QQMusicAXButton]

    func button(for action: QQMusicPlaybackAction) throws -> QQMusicAXButton {
        let title: String
        switch action {
        case .play: title = "播放"
        case .pause: title = "暂停"
        case .next: title = "下一首"
        case .previous: title = "上一首"
        }
        let matches = buttons.filter { $0.title == title || (action == .pause && $0.title == "暂停播放") }
        guard matches.count == 1 else { throw QQMusicPlaybackError.unverifiable }
        return matches[0]
    }
}

private extension QQMusicPlaybackAction {
    var desiredPlaying: Bool? {
        switch self {
        case .play: true
        case .pause: false
        case .next, .previous: nil
        }
    }
    var isSkip: Bool { self == .next || self == .previous }
}

enum QQMusicAXSearchPolicy {
    static func mayInspectLabels(role: String?) -> Bool {
        role == (kAXGroupRole as String) || role == "AXPanel"
    }

    static func mayDescend(role: String?) -> Bool {
        role == (kAXWindowRole as String) || mayInspectLabels(role: role)
    }

    static func isPlaybackBar(role: String?, identifier: String?, title: String?,
                              description: String?, roleDescription: String?) -> Bool {
        guard mayInspectLabels(role: role) else { return false }
        return [identifier, title, description, roleDescription].contains("播放控制栏")
    }

    static func excludesSubtree(role: String?, identifier: String?, title: String?,
                                description: String?, roleDescription: String?) -> Bool {
        if role == (kAXScrollAreaRole as String) { return true }
        let labels = [identifier, title, description, roleDescription].compactMap { $0 }
        return labels.contains { label in
            ["个人中心", "账户", "聊天"].contains { label.contains($0) }
        }
    }
}

@MainActor
final class NativeQQMusicAXSurface: QQMusicAXSurface {
    private let bundleID = "com.tencent.QQMusicMac"
    private var buttons: [String: AXUIElement] = [:]
    private let maxNodes = 160
    private let maxDepth = 7

    func isTrusted() -> Bool { AXIsProcessTrusted() }

    func isRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.bundleIdentifier == bundleID && !$0.isTerminated }
    }

    func snapshot() throws -> QQMusicAXSnapshot {
        buttons.removeAll()
        let processes = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.bundleIdentifier == bundleID && !$0.isTerminated }
        guard processes.count == 1 else { throw QQMusicPlaybackError.unverifiable }
        let app = AXUIElementCreateApplication(processes[0].processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let windows = elements(app, attribute: kAXWindowsAttribute as String) else {
            throw QQMusicPlaybackError.unverifiable
        }
        let matching = windows.filter { string($0, attribute: kAXIdentifierAttribute as String) == "QQMianWindow" }
        guard matching.count == 1 else { throw QQMusicPlaybackError.unverifiable }
        var remaining = maxNodes
        var regions: [QQMusicAXRegion] = []
        try findRegions(in: matching[0], depth: 0, remaining: &remaining, regions: &regions)
        return QQMusicAXSnapshot(regions: regions)
    }

    func press(buttonKey: String, expectedTitle: String) throws {
        guard let button = buttons[buttonKey],
              string(button, attribute: kAXRoleAttribute as String) == (kAXButtonRole as String),
              string(button, attribute: kAXTitleAttribute as String) == expectedTitle else {
            throw QQMusicAXPreflightError.staleButton
        }
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard result == .success else { throw QQMusicPlaybackError.unknownOutcome }
    }

    private func findRegions(in element: AXUIElement, depth: Int,
                             remaining: inout Int, regions: inout [QQMusicAXRegion]) throws {
        guard depth <= maxDepth, remaining > 0 else { throw QQMusicPlaybackError.unverifiable }
        remaining -= 1
        let role = string(element, attribute: kAXRoleAttribute as String)
        guard QQMusicAXSearchPolicy.mayDescend(role: role) else { return }
        // Outside the playback bar, labels are inspected only on structural containers.
        let inspectLabels = QQMusicAXSearchPolicy.mayInspectLabels(role: role)
        let identifier = inspectLabels ? string(element, attribute: kAXIdentifierAttribute as String) : nil
        let title = inspectLabels ? string(element, attribute: kAXTitleAttribute as String) : nil
        let description = inspectLabels ? string(element, attribute: kAXDescriptionAttribute as String) : nil
        let roleDescription = inspectLabels ? string(element, attribute: kAXRoleDescriptionAttribute as String) : nil
        if QQMusicAXSearchPolicy.excludesSubtree(role: role, identifier: identifier,
                                                 title: title, description: description,
                                                 roleDescription: roleDescription) {
            return
        }
        if QQMusicAXSearchPolicy.isPlaybackBar(role: role, identifier: identifier,
                                               title: title, description: description,
                                               roleDescription: roleDescription) {
            regions.append(try collectRegion(element, remaining: &remaining))
            return
        }
        for child in elements(element, attribute: kAXChildrenAttribute as String) ?? [] {
            try findRegions(in: child, depth: depth + 1, remaining: &remaining, regions: &regions)
        }
    }

    private func collectRegion(_ root: AXUIElement, remaining: inout Int) throws -> QQMusicAXRegion {
        var foundButtons: [QQMusicAXButton] = []
        var songTexts: [String] = []
        func visit(_ element: AXUIElement, depth: Int) throws {
            guard depth <= maxDepth, remaining > 0 else { throw QQMusicPlaybackError.unverifiable }
            remaining -= 1
            let role = string(element, attribute: kAXRoleAttribute as String)
            let title = string(element, attribute: kAXTitleAttribute as String)
            if role == (kAXButtonRole as String), let title,
               ["上一首", "播放", "暂停", "暂停播放", "下一首"].contains(title) {
                let key = "button-\(foundButtons.count)"
                buttons[key] = element
                foundButtons.append(QQMusicAXButton(key: key, title: title))
            }
            // Values are read only inside the verified playback control group.
            for value in [title, string(element, attribute: kAXValueAttribute as String)] {
                if let value, value.hasPrefix("歌曲名："), !songTexts.contains(value) {
                    songTexts.append(value)
                }
            }
            for child in elements(element, attribute: kAXChildrenAttribute as String) ?? [] {
                try visit(child, depth: depth + 1)
            }
        }
        try visit(root, depth: 0)
        return QQMusicAXRegion(buttons: foundButtons, songTexts: songTexts)
    }

    private func string(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func elements(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let values = value as? [AXUIElement] else { return nil }
        return values
    }
}
