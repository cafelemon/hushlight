import Foundation
import XCTest
@testable import HushlightMac

private struct QQChatFixtureProvider: QQChatAXProviding {
    let roots: [QQChatAXNode]
    func windows(deadline: ContinuousClock.Instant) async throws -> [QQChatAXNode] { roots }
}

private actor QQChatChangingProvider: QQChatAXProviding {
    private let first: [QQChatAXNode]
    private let second: [QQChatAXNode]
    private var calls = 0

    init(first: [QQChatAXNode], second: [QQChatAXNode]) {
        self.first = first
        self.second = second
    }

    func windows(deadline: ContinuousClock.Instant) async throws -> [QQChatAXNode] {
        calls += 1
        return calls == 1 ? first : second
    }
}

@MainActor
final class QQChatReadBackendTests: XCTestCase {
    private func node(_ role: String, title: String? = nil, description: String? = nil,
                      identifier: String? = nil, value: String? = nil, placeholder: String? = nil,
                      children: [QQChatAXNode] = []) -> QQChatAXNode {
        .init(role: role, title: title, description: description, identifier: identifier,
              value: value, placeholder: placeholder, children: children)
    }

    private func window(target: String = "测试联系人", draft: String = "", rows: [QQChatAXNode]? = nil,
                        extra: [QQChatAXNode] = [], headerExtra: [QQChatAXNode] = [],
                        emptyComposerDescription: Bool = false) -> QQChatAXNode {
        let messageRows = rows ?? [node("AXGroup", children: [
            node("AXGroup", identifier: "sender", children: [node("AXStaticText", value: "测试联系人")]),
            node("AXStaticText", value: "你好")
        ])]
        return node("AXWindow", title: "QQ", children: [node("AXGroup", children: [
            node("AXGroup", description: "会话列表", children: [
                node("AXStaticText", value: "另一位联系人"),
                node("AXStaticText", value: "侧栏旧消息"),
                node("AXButton", title: target)
            ]),
            node("AXGroup", children: [node("AXButton", title: target),
                                        node("AXButton", title: "在线"),
                                        node("AXToolbar", title: "更多")] + headerExtra),
            node("AXGroup", children: [
                node("AXGroup", description: "消息列表", children: [node("AXGroup", children: messageRows)]),
                node("AXToolbar", title: "会话"),
                node("AXTextArea", description: emptyComposerDescription ? nil : target, value: draft)
            ] + extra)
        ])])
    }

    func testCurrentVisibleConversationPreviewExcludesSidebarAndDraftText() async throws {
        let backend = NativeQQChatReadBackend(provider: QQChatFixtureProvider(roots: [window(draft: "还没发送")]))
        let result = try await backend.snapshot()
        XCTAssertEqual(result.conversationTitle, "测试联系人")
        XCTAssertEqual(result.messages, [.init(sender: "测试联系人", body: "你好")])
        XCTAssertTrue(result.hasDraft)
        XCTAssertEqual(result.identityScope, .currentVisibleConversationOnly)
        XCTAssertFalse(result.messages.map(\.body).contains("还没发送"))
        XCTAssertFalse(result.messages.map(\.body).contains("侧栏旧消息"))
    }

    func testEmptyDraftAndNonTextRows() async throws {
        let rows = [node("AXGroup", children: [node("AXImage", description: "表情")])]
        let result = try await NativeQQChatReadBackend(provider: QQChatFixtureProvider(roots: [window(rows: rows)])).snapshot()
        XCTAssertFalse(result.hasDraft)
        XCTAssertTrue(result.messages.isEmpty)
    }

    func testContainerDescriptionSenderAndVoicePlaceholder() async throws {
        let row = node("AXGroup", description: "测试账号", children: [node("AXStaticText", value: "你好")])
        let original = window(draft: "按住 ⌃ ⌥，使用语音输入文字", rows: [
            node("AXGroup", description: "16:35"), row
        ])
        let result = try await NativeQQChatReadBackend(provider: QQChatFixtureProvider(roots: [original])).snapshot()
        XCTAssertEqual(result.messages, [.init(sender: "测试账号", body: "你好")])
        XCTAssertFalse(result.hasDraft)
    }

    func testEmptyComposerUsesAdjacentHeaderAndNestedTimeWrapper() async throws {
        let first = node("AXGroup", children: [
            node("AXStaticText", value: "16:35"),
            node("AXGroup", description: "测试联系人"),
            node("AXStaticText", value: "你好")
        ])
        let second = node("AXGroup", children: [
            node("AXGroup", title: "我"), node("AXStaticText", value: "收到")
        ])
        let timeWrapper = node("AXGroup", children: [node("AXStaticText", value: "16:35"), first, second])
        let result = try await NativeQQChatReadBackend(provider: QQChatFixtureProvider(
            roots: [window(rows: [timeWrapper], emptyComposerDescription: true)])).snapshot()
        XCTAssertEqual(result.conversationTitle, "测试联系人")
        XCTAssertEqual(result.messages, [.init(sender: "测试联系人", body: "你好"),
                                         .init(sender: "我", body: "收到")])
        XCTAssertFalse(result.hasDraft)
    }

    func testClockShapedMessageBodyWithSenderIsPreserved() async throws {
        let row = node("AXGroup", children: [
            node("AXGroup", description: "Someone"), node("AXStaticText", value: "16:35")
        ])
        let result = try await NativeQQChatReadBackend(provider: QQChatFixtureProvider(
            roots: [window(rows: [row], emptyComposerDescription: true)])).snapshot()
        XCTAssertEqual(result.messages, [.init(sender: "Someone", body: "16:35")])
    }

    func testConversationChangeBetweenReadsIsRejected() async {
        let first = window(rows: [node("AXGroup", children: [
            node("AXGroup", description: "测试联系人"), node("AXStaticText", value: "A的正文")
        ])], emptyComposerDescription: true)
        let second = window(target: "其他会话", rows: [node("AXGroup", children: [
            node("AXGroup", description: "其他会话"), node("AXStaticText", value: "B的正文")
        ])], emptyComposerDescription: true)
        do {
            _ = try await NativeQQChatReadBackend(provider: QQChatChangingProvider(
                first: [first], second: [second])).snapshot()
            XCTFail("Expected changed conversation")
        } catch let error as QQChatReadError {
            XCTAssertEqual(error, .conversationChanged)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNativeWrappedConversationShapeUsesHeaderDescriptionAndBodyOnly() async throws {
        let message = node("AXGroup", children: [
            node("AXGroup", description: "测试联系人"),
            node("AXGroup", children: [node("AXGroup", children: [
                node("AXGroup", children: [node("AXStaticText", value: "你好，我是codex，这是一条Orbit测试消息。")])
            ])]),
            node("AXGroup")
        ])
        let list = node("AXGroup", description: "消息列表", children: [
            node("AXGroup", children: [node("AXGroup", children: [message])])
        ])
        let header = node("AXGroup", children: [node("AXGroup"), node("AXGroup", children: [
            node("AXButton", title: "", description: "测试联系人"),
            node("AXButton", title: "", description: "在线状态在线")
        ]), node("AXGroup")])
        let body = node("AXGroup", children: [
            node("AXGroup", children: [node("AXGroup", children: [list])]),
            node("AXGroup", children: [node("AXGroup", children: [node("AXTextArea")])])
        ])
        let result = try await NativeQQChatReadBackend(provider: QQChatFixtureProvider(roots: [
            node("AXWindow", title: "QQ", children: [node("AXGroup", children: [header, body])])
        ])).snapshot()
        XCTAssertEqual(result.conversationTitle, "测试联系人")
        XCTAssertEqual(result.messages.map(\.body), ["你好，我是codex，这是一条Orbit测试消息。"])
        XCTAssertFalse(result.hasDraft)
    }

    func testNativeCurrentQQConversationSmoke() async throws {
        guard ProcessInfo.processInfo.environment["WORKBENCH_QQCHAT_READ_SMOKE"] == "1" else {
            throw XCTSkip("Native QQ chat smoke is opt-in")
        }
        let environment = ProcessInfo.processInfo.environment
        guard let target = environment["WORKBENCH_QQCHAT_SMOKE_TARGET"], !target.isEmpty,
              let expected = environment["WORKBENCH_QQCHAT_SMOKE_TEXT"], !expected.isEmpty else {
            throw XCTSkip("Configure an explicitly authorized target and public test text locally")
        }
        let result = try await NativeQQChatReadBackend().snapshot()
        guard result.conversationTitle == target,
              result.messages.contains(where: { $0.body == expected }) else {
            XCTFail("Current QQ target or public test message was not verified")
            return
        }
        print("QQChat native smoke pass; visible message count: \(result.messages.count)")
    }

    func testRejectsAdditionalWindowComposerAndMismatchedTitle() async {
        await expect(.unavailableWindow, [window(), window()])
        await expect(.ambiguousConversation, [window(extra: [node("AXTextArea", description: "别人")])])
        await expect(.ambiguousConversation, [window(headerExtra: [node("AXButton", title: "测试联系人")])])
        await expect(.ambiguousConversation, [window(target: "别人", extra: [node("AXTextArea", description: "测试联系人")])])
    }

    func testMissingMessageListAndDuplicateListFailClosed() async {
        let bare = node("AXWindow", title: "QQ", children: [
            node("AXButton", title: "测试联系人"), node("AXTextArea", description: "测试联系人")
        ])
        await expect(.ambiguousConversation, [bare])
        await expect(.malformedSnapshot, [window(extra: [node("AXGroup", description: "消息列表")])])
    }

    func testTextAndTreeLimitsFailClosed() async {
        let long = String(repeating: "字", count: 1_001)
        await expect(.limitsExceeded, [window(rows: [node("AXGroup", children: [
            node("AXGroup", description: "发言人"), node("AXStaticText", value: long)])])])
        let deep = (0..<33).reduce(node("AXStaticText", value: "深处")) { child, _ in
            node("AXGroup", children: [child])
        }
        await expect(.limitsExceeded, [window(extra: [deep])])
        let many = Array(repeating: node("AXGroup", children: [
            node("AXGroup", description: "发言人"), node("AXStaticText", value: "x")]), count: 31)
        await expect(.limitsExceeded, [window(rows: many)])
    }

    func testDeepQQHTMLTreeWithinBoundStillReadsTargetOnly() async throws {
        let row = node("AXGroup", description: "测试联系人", children: [node("AXStaticText", value: "可见消息")])
        let content = node("AXGroup", children: [node("AXGroup"),
            node("AXGroup", children: [node("AXButton", title: "测试联系人")]),
            node("AXGroup", children: [node("AXGroup", description: "消息列表", children: [row]),
                                       node("AXTextArea")])])
        let deep = (0..<18).reduce(content) { child, _ in node("AXGroup", children: [child]) }
        let root = node("AXWindow", title: "QQ", children: [deep])
        let result = try await NativeQQChatReadBackend(provider: QQChatFixtureProvider(roots: [root])).snapshot()
        XCTAssertEqual(result.messages, [.init(sender: "测试联系人", body: "可见消息")])
    }

    func testErrorsUseFixedLocalizedText() {
        XCTAssertEqual(QQChatReadError.limitsExceeded.errorDescription, "当前聊天内容超出安全读取范围。")
        XCTAssertEqual(QQChatReadError.ambiguousConversation.errorDescription, "无法确认当前聊天对象。")
    }

    private func expect(_ expected: QQChatReadError, _ roots: [QQChatAXNode]) async {
        do {
            _ = try await NativeQQChatReadBackend(provider: QQChatFixtureProvider(roots: roots)).snapshot()
            XCTFail("Expected \(expected)")
        } catch let error as QQChatReadError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
