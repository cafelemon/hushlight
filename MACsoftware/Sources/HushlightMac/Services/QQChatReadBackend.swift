import AppKit
import ApplicationServices
import Foundation

/// A preview of the one conversation currently shown by QQ. Names are display text, not account IDs.
struct QQChatVisibleMessage: Sendable, Equatable {
    let sender: String?
    let body: String
}

struct QQChatSnapshot: Sendable, Equatable {
    let conversationTitle: String
    let messages: [QQChatVisibleMessage]
    let hasDraft: Bool
    let checkedAt: Date
    /// This snapshot cannot establish a stable recipient identity or authorize sending.
    let identityScope: IdentityScope = .currentVisibleConversationOnly

    enum IdentityScope: Sendable, Equatable {
        case currentVisibleConversationOnly
    }
}

protocol QQChatReading: Sendable {
    func snapshot() async throws -> QQChatSnapshot
}

enum QQChatReadError: Error, Equatable, LocalizedError {
    case permissionRequired
    case notRunning
    case unavailableWindow
    case ambiguousConversation
    case malformedSnapshot
    case limitsExceeded
    case conversationChanged

    var errorDescription: String? {
        switch self {
        case .permissionRequired: "需要先在系统设置中授予辅助功能权限。"
        case .notRunning: "QQ 尚未运行。"
        case .unavailableWindow: "无法读取 QQ 主窗口，请检查 Mac 已解锁且 QQ 聊天窗口可见。"
        case .ambiguousConversation: "无法确认当前聊天对象。"
        case .malformedSnapshot: "当前聊天内容无法可靠读取。"
        case .limitsExceeded: "当前聊天内容超出安全读取范围。"
        case .conversationChanged: "读取期间当前聊天已变化，请重试。"
        }
    }
}

/// Copyable, bounded AX data; tests can inject this without touching the real desktop.
struct QQChatAXNode: Sendable {
    let role: String
    let title: String?
    let description: String?
    let identifier: String?
    let value: String?
    let placeholder: String?
    let children: [QQChatAXNode]

    init(role: String, title: String? = nil, description: String? = nil,
         identifier: String? = nil, value: String? = nil, placeholder: String? = nil,
         children: [QQChatAXNode] = []) {
        self.role = role
        self.title = title
        self.description = description
        self.identifier = identifier
        self.value = value
        self.placeholder = placeholder
        self.children = children
    }
}

protocol QQChatAXProviding: Sendable {
    func windows(deadline: ContinuousClock.Instant) async throws -> [QQChatAXNode]
}

final class NativeQQChatReadBackend: QQChatReading {
    private let provider: any QQChatAXProviding

    init(provider: any QQChatAXProviding = NativeQQChatAXProvider()) {
        self.provider = provider
    }

    func snapshot() async throws -> QQChatSnapshot {
        try Task.checkCancellation()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let checkedAt = Date()
        let first = try QQChatSnapshotParser.parse(windows: await provider.windows(deadline: deadline),
                                                   checkedAt: checkedAt)
        try Task.checkCancellation()
        let second = try QQChatSnapshotParser.parse(windows: await provider.windows(deadline: deadline),
                                                    checkedAt: checkedAt)
        try Task.checkCancellation()
        guard first == second else { throw QQChatReadError.conversationChanged }
        return second
    }
}

enum QQChatSnapshotParser {
    private static let maxNodes = 500
    private static let maxDepth = 32
    private static let maxMessages = 30
    private static let maxText = 1_000
    private static let maxTotalText = 8_000

    static func parse(windows: [QQChatAXNode], checkedAt: Date) throws -> QQChatSnapshot {
        guard windows.count == 1, let window = windows.first, window.role == "AXWindow",
              window.title == "QQ" else { throw QQChatReadError.unavailableWindow }
        var count = 0
        var nodes: [QQChatAXNode] = []
        func visit(_ node: QQChatAXNode, depth: Int) throws {
            guard depth <= maxDepth, count < maxNodes else { throw QQChatReadError.limitsExceeded }
            count += 1
            nodes.append(node)
            for child in node.children { try visit(child, depth: depth + 1) }
        }
        try visit(window, depth: 0)

        // The current QQ HTML view keeps sidebar, header and body as three sibling groups.
        // Resolve title only from the header adjacent to the body containing this composer/list.
        let contexts = nodes.filter { node in
            guard node.role == "AXGroup", node.children.count == 2 || node.children.count == 3 else {
                return false
            }
            let body = node.children.last!
            let bodyNodes = [body] + descendants(body)
            return bodyNodes.contains(where: { $0.role == "AXTextArea" }) &&
                bodyNodes.contains(where: isMessageList)
        }
        guard contexts.count == 1, let context = contexts.first else {
            throw QQChatReadError.ambiguousConversation
        }
        let header = context.children[context.children.count == 3 ? 1 : 0]
        let body = context.children.last!
        let bodyNodes = [body] + descendants(body)
        let composers = bodyNodes.filter { $0.role == "AXTextArea" }
        guard composers.count == 1, let composer = composers.first,
              nodes.filter({ $0.role == "AXTextArea" }).count == 1 else {
            throw QQChatReadError.ambiguousConversation
        }
        let titleRegion = header.children.count == 3 && header.children[1].role == "AXGroup"
            ? header.children[1] : header
        let headerButtons = descendants(titleRegion).filter { $0.role == "AXButton" }
        let targetButtons = headerButtons.filter { button in
            guard let label = preferredLabel(button) else { return false }
            return !isStatusLabel(label)
        }
        guard targetButtons.count == 1, let targetButton = targetButtons.first,
              let target = preferredLabel(targetButton),
              target.count <= 120 else { throw QQChatReadError.ambiguousConversation }
        if let title = targetButton.title.map(clean), let description = targetButton.description.map(clean),
           !title.isEmpty && !description.isEmpty && title != description {
            throw QQChatReadError.ambiguousConversation
        }
        if let description = composer.description.map(clean), !description.isEmpty,
           description != target { throw QQChatReadError.ambiguousConversation }
        let lists = bodyNodes.filter(isMessageList)
        guard lists.count == 1, let list = lists.first else { throw QQChatReadError.malformedSnapshot }
        let containers = messageContainers(in: list)
        guard containers.count <= maxMessages else { throw QQChatReadError.limitsExceeded }
        var total = target.count
        var messages: [QQChatVisibleMessage] = []
        for container in containers {
            guard let parts = messageParts(container) else { throw QQChatReadError.malformedSnapshot }
            let sender = parts.sender
            let body = parts.body
            guard body.count <= maxText, (sender?.count ?? 0) <= 120 else { throw QQChatReadError.limitsExceeded }
            total += body.count + (sender?.count ?? 0)
            guard total <= maxTotalText else { throw QQChatReadError.limitsExceeded }
            messages.append(.init(sender: sender, body: body))
        }
        // The composer value is deliberately never exposed or included in messages.
        let composerValue = clean(composer.value ?? "")
        let placeholder = clean(composer.placeholder ?? "")
        let isPlaceholder = (!placeholder.isEmpty && composerValue == placeholder) ||
            composerValue == "按住 ⌃ ⌥，使用语音输入文字"
        return QQChatSnapshot(conversationTitle: target, messages: messages,
                              hasDraft: !composerValue.isEmpty && !isPlaceholder, checkedAt: checkedAt)
    }

    private static func isMessageList(_ node: QQChatAXNode) -> Bool {
        [node.title, node.description, node.identifier].compactMap { $0 }
            .contains { clean($0) == "消息列表" || clean($0).lowercased() == "message list" }
    }

    private static func descendants(_ node: QQChatAXNode) -> [QQChatAXNode] {
        node.children.flatMap { [$0] + descendants($0) }
    }

    private static func isStatusLabel(_ label: String) -> Bool {
        ["在线", "离线", "忙碌", "隐身"].contains(label) || label.hasPrefix("在线状态")
    }

    private static func preferredLabel(_ node: QQChatAXNode) -> String? {
        [node.title, node.description].compactMap { $0 }.map(clean).first { !$0.isEmpty }
    }

    private static func messageContainers(in node: QQChatAXNode) -> [QQChatAXNode] {
        node.children.flatMap { child -> [QQChatAXNode] in
            guard child.role == "AXGroup" || child.role == "AXRow" else { return [] }
            if messageParts(child) != nil { return [child] }
            return messageContainers(in: child)
        }
    }

    private static func messageParts(_ node: QQChatAXNode) -> (sender: String?, body: String)? {
        var children = node.children
        if let first = children.first, first.role == "AXStaticText",
           let clock = (first.value ?? first.title).map(clean), isClockText(clock) {
            children.removeFirst()
        }
        if let label = node.description.map(clean), !label.isEmpty, !isClockText(label),
           !isMessageList(node), children.count == 1, children[0].role == "AXStaticText",
           let body = (children[0].value ?? children[0].title).map(clean), !body.isEmpty {
            return (label, body)
        }
        guard children.count >= 2, let senderNode = children.first,
              senderNode.role == "AXGroup" || senderNode.role == "AXRow" else { return nil }
        let sender = [senderNode.description, senderNode.title, senderNode.value,
                      senderNode.identifier == "sender" ? senderNode.children.first?.value : nil]
            .compactMap { $0 }.map(clean).first { !$0.isEmpty && $0 != "sender" }
        guard let sender, !sender.isEmpty, !isClockText(sender) else { return nil }
        let bodies = ([children[1]] + descendants(children[1]))
            .filter { $0.role == "AXStaticText" }
            .compactMap { $0.value ?? $0.title }.map(clean).filter { !$0.isEmpty }
        guard bodies.count == 1 else { return nil }
        return (sender, bodies[0])
    }

    private static func isClockText(_ text: String) -> Bool {
        text.range(of: "^\\d{1,2}:\\d{2}$", options: .regularExpression) != nil
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct NativeQQChatAXProvider: QQChatAXProviding {
    private let bundleID = "com.tencent.qq"

    func windows(deadline: ContinuousClock.Instant) async throws -> [QQChatAXNode] {
        // Non-actor async execution keeps bounded AX IPC away from the UI actor.
        try checkBudget(deadline)
        guard AXIsProcessTrusted() else { throw QQChatReadError.permissionRequired }
        let pids = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.bundleIdentifier == bundleID && !$0.isTerminated }
                .map(\.processIdentifier)
        }
        guard !pids.isEmpty else { throw QQChatReadError.notRunning }
        guard pids.count == 1, let pid = pids.first else { throw QQChatReadError.unavailableWindow }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.2)
        try checkBudget(deadline)
        guard let rawWindows = elements(root, kAXWindowsAttribute as String) else {
            throw QQChatReadError.unavailableWindow
        }
        let matches = rawWindows.filter { candidate in
            AXUIElementSetMessagingTimeout(candidate, 0.2)
            return string(candidate, kAXRoleAttribute as String) == "AXWindow" &&
                string(candidate, kAXTitleAttribute as String) == "QQ"
        }
        guard matches.count == 1 else { throw QQChatReadError.unavailableWindow }
        guard let main = matches.first else { throw QQChatReadError.unavailableWindow }
        // Verified QQ 7.0.2 native tree: these wrappers lead to the two-child
        // sidebar/conversation split. Only the conversation branch is copied.
        let splitPath = [0, 0, 0, 0, 0, 0, 0, 0, 1, 3]
        var cursor = main
        for index in splitPath {
            try checkBudget(deadline)
            guard let children = elements(cursor, kAXChildrenAttribute as String),
                  children.indices.contains(index) else { throw QQChatReadError.unavailableWindow }
            cursor = children[index]
        }
        guard string(cursor, kAXRoleAttribute as String) == "AXGroup",
              let branches = elements(cursor, kAXChildrenAttribute as String), branches.count == 2,
              string(branches[1], kAXRoleAttribute as String) == "AXGroup" else {
            throw QQChatReadError.unavailableWindow
        }
        var seen = Set<CFHashCode>()
        var remaining = 500
        let conversation = try copy(branches[1], depth: 1, remaining: &remaining,
                                    seen: &seen, deadline: deadline)
        return [QQChatAXNode(role: "AXWindow", title: "QQ", children: [conversation])]
    }

    private func copy(_ element: AXUIElement, depth: Int, remaining: inout Int,
                      seen: inout Set<CFHashCode>, deadline: ContinuousClock.Instant) throws -> QQChatAXNode {
        try checkBudget(deadline)
        guard depth <= 32, remaining > 0 else { throw QQChatReadError.limitsExceeded }
        let identity = CFHash(element)
        guard seen.insert(identity).inserted else { throw QQChatReadError.malformedSnapshot }
        remaining -= 1
        let children = elements(element, kAXChildrenAttribute as String) ?? []
        guard children.count <= remaining else { throw QQChatReadError.limitsExceeded }
        let copied = try children.map { child in
            return try copy(child, depth: depth + 1, remaining: &remaining,
                            seen: &seen, deadline: deadline)
        }
        try checkBudget(deadline)
        return QQChatAXNode(role: string(element, kAXRoleAttribute as String) ?? "",
                            title: string(element, kAXTitleAttribute as String),
                            description: string(element, kAXDescriptionAttribute as String),
                            identifier: string(element, kAXIdentifierAttribute as String),
                            value: string(element, kAXValueAttribute as String),
                            placeholder: string(element, kAXPlaceholderValueAttribute as String),
                            children: copied)
    }

    private func checkBudget(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw QQChatReadError.limitsExceeded }
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        return String(text.prefix(8_001))
    }

    private func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }
}
