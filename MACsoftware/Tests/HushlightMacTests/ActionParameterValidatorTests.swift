import XCTest
@testable import HushlightMac

final class ActionParameterValidatorTests: XCTestCase {
    private let validator = ActionParameterValidator()

    func testEveryRegisteredActionHasAValidParameterExample() throws {
        let digest = String(repeating: "a", count: 64)
        let examples: [(String, JSONValue)] = [
            ("system.volume.get", object()),
            ("system.volume.set", object(["value": .number(42)])),
            ("system.volume.adjust", object(["delta": .number(-5)])),
            ("timer.create", object([
                "timer_id": .string("timer-01"),
                "fire_at": .string("2026-08-14T08:00:00Z"),
                "label": .string("休息")
            ])),
            ("timer.update", object([
                "timer_id": .string("timer-01"),
                "label": .string("继续休息")
            ])),
            ("timer.cancel", object(["timer_id": .string("timer-01")])),
            ("reminder.create", object([
                "reminder_id": .string("reminder-01"),
                "title": .string("喝水"),
                "due_at": .string("2026-08-14T08:00:00Z")
            ])),
            ("reminder.update", object([
                "reminder_id": .string("reminder-01"),
                "due_at": .string("2026-08-14T08:30:00Z")
            ])),
            ("reminder.cancel", object(["reminder_id": .string("reminder-01")])),
            ("content.open", object(["bundle_id": .string("com.apple.Safari")])),
            ("media.play", object()),
            ("media.pause", object(["provider": .string("system")])),
            ("media.previous", object(["provider": .string("netease_music")])),
            ("media.next", object()),
            ("music.search_and_play", object([
                "provider": .string("netease_music"),
                "query": .string("轻松的歌")
            ])),
            ("chat.draft", object([
                "provider": .string("wechat"),
                "target_name": .string("测试联系人"),
                "content": .string("我晚十分钟")
            ])),
            ("chat.send", object([
                "provider": .string("wechat"),
                "user_id": .string("user-01"),
                "device_id": .string("device-01"),
                "session_id": .string("session-01"),
                "target_id": .string("contact-01"),
                "draft_sha256": .string(digest)
            ]))
        ]

        XCTAssertEqual(examples.count, CapabilityRegistry.standard.definitions.count)
        for (action, parameters) in examples {
            XCTAssertNoThrow(
                try validator.validate(action: action, parameters: parameters),
                "Expected valid parameters for \(action)"
            )
        }
    }

    func testUnknownAndExtraFieldsFailClosed() {
        XCTAssertThrowsError(
            try validator.validate(action: "shell.run", parameters: object())
        ) { error in
            XCTAssertEqual(error as? StableErrorCode, .capabilityDisabled)
        }
        XCTAssertThrowsError(
            try validator.validate(
                action: "system.volume.get",
                parameters: object(["command": .string("whoami")])
            )
        ) { error in
            XCTAssertEqual(error as? StableErrorCode, .invalidSchema)
        }
    }

    func testVolumeBoundsAndUpdateChangesAreRequired() {
        assertInvalid("system.volume.set", object(["value": .number(101)]))
        assertInvalid("system.volume.adjust", object(["delta": .number(-101)]))
        assertInvalid("timer.update", object(["timer_id": .string("timer-01")]))
        assertInvalid("reminder.update", object(["reminder_id": .string("reminder-01")]))
    }

    func testContentOpenRejectsAmbiguousAndUnsafeTargets() {
        assertInvalid("content.open", object())
        assertInvalid("content.open", object([
            "bundle_id": .string("com.apple.Safari"),
            "url": .string("https://example.com")
        ]))
        assertInvalid("content.open", object(["url": .string("file:///tmp/private")]))
        assertInvalid("content.open", object(["url": .string("https://127.0.0.1/private")]))
        assertInvalid("content.open", object(["url": .string("https://user:pass@example.com")]))
        XCTAssertNoThrow(try validator.validate(
            action: "content.open",
            parameters: object(["url": .string("https://music.163.com/song?id=1")])
        ))
    }

    func testChatTargetsAndDigestAreStrict() {
        assertInvalid("chat.draft", object([
            "provider": .string("wechat"),
            "target_name": .string("A"),
            "target_id": .string("contact-a"),
            "content": .string("test")
        ]))
        assertInvalid("chat.send", object([
            "provider": .string("wechat"),
            "user_id": .string("user-01"),
            "device_id": .string("device-01"),
            "session_id": .string("session-01"),
            "target_id": .string("contact-01"),
            "draft_sha256": .string("not-a-digest")
        ]))
    }

    private func assertInvalid(
        _ action: String,
        _ parameters: JSONValue,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try validator.validate(action: action, parameters: parameters),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? StableErrorCode, .invalidSchema, file: file, line: line)
        }
    }

    private func object(_ value: [String: JSONValue] = [:]) -> JSONValue {
        .object(value)
    }
}
