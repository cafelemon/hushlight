import Foundation
import XCTest
@testable import HushlightMac

private actor VoicePlannerRunnerStub: AutomationCodexRunning {
    let output: Data
    private(set) var calls = 0
    private(set) var lastPrompt = ""
    private(set) var lastSchema = Data()

    init(_ output: String) { self.output = Data(output.utf8) }

    func decide(prompt: String, schema: Data) async throws -> Data {
        calls += 1
        lastPrompt = prompt
        lastSchema = schema
        return output
    }
}

final class VoiceCommandPlannerTests: XCTestCase {
    private func json(_ action: String, label: String? = nil, seconds: Int? = nil,
                      cityID: String? = nil, reason: String? = nil) -> String {
        let value: [String: Any] = [
            "action": action, "label": label as Any? ?? NSNull(),
            "seconds": seconds as Any? ?? NSNull(), "city_id": cityID as Any? ?? NSNull(),
            "reason": reason as Any? ?? NSNull()
        ]
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func testValidProposalsHaveOnlyComputedReviewText() async throws {
        let cases: [(String, String, VoiceCommandAction)] = [
            ("查看当前系统音量", json("volume_read"), .volumeRead),
            ("设置一个五分钟计时器", json("timer_create", label: "计时器", seconds: 300), .timerCreate(label: "计时器", seconds: 300)),
            ("设置1小时30分钟计时器", json("timer_create", label: "计时器", seconds: 5400), .timerCreate(label: "计时器", seconds: 5400)),
            ("查询北京当前天气", json("weather_get", cityID: "beijing"), .weatherGet(cityID: "beijing"))
        ]
        for (text, output, expected) in cases {
            let runner = VoicePlannerRunnerStub(output)
            let actual = try await CodexVoiceCommandPlanner(runner: runner).propose(text: text)
            XCTAssertEqual(actual, expected)
            let schema = try JSONSerialization.jsonObject(with: await runner.lastSchema) as? [String: Any]
            XCTAssertEqual(Set(schema?["required"] as? [String] ?? []), ["action", "label", "seconds", "city_id", "reason"])
            XCTAssertEqual(schema?["additionalProperties"] as? Bool, false)
            let prompt = await runner.lastPrompt
            XCTAssertTrue(prompt.contains("untrusted user text"))
        }
        XCTAssertEqual(VoiceCommandAction.volumeRead.reviewDescription, "读取当前系统音量")
        XCTAssertEqual(VoiceCommandAction.timerCreate(label: "计时器", seconds: 300).reviewDescription,
                       "确认执行后创建 300 秒到期的计时器「计时器」，按系统通知设置提醒")
        XCTAssertEqual(VoiceCommandAction.weatherGet(cityID: "beijing").reviewDescription, "查询北京当前天气")
    }

    func testInputBoundsDoNotCallModel() async throws {
        for source in ["", "  \n ", String(repeating: "字", count: 4_001)] {
            let runner = VoicePlannerRunnerStub(json("volume_read"))
            do { _ = try await CodexVoiceCommandPlanner(runner: runner).propose(text: source); XCTFail("Invalid input") }
            catch CodexAutomationError.invalidInput {}
            let calls = await runner.calls
            XCTAssertEqual(calls, 0)
        }
    }

    func testMalformedAndExtraOutputAreRejected() async throws {
        let invalid = [
            "not-json", "[]", "{}", json("volume_read").dropLast().description,
            #"{"action":"volume_read","label":null,"seconds":null,"city_id":null,"reason":null,"shell":"rm -rf /"}"#,
            #"{"action":"volume_read","label":"x","seconds":null,"city_id":null,"reason":null}"#,
            #"{"action":"timer_create","label":"计时器","seconds":5.5,"city_id":null,"reason":null}"#,
            #"{"action":"timer_create","label":"计时器","seconds":true,"city_id":null,"reason":null}"#,
            json("timer_create", label: "计时器", seconds: 4),
            json("timer_create", label: "计时器", seconds: 86_401),
            json("weather_get", cityID: "unknown"),
            json("shell"),
            String(repeating: "x", count: 32_001)
        ]
        for output in invalid {
            do { _ = try await CodexVoiceCommandPlanner(runner: VoicePlannerRunnerStub(output)).propose(text: "5秒计时器"); XCTFail("Accepted: \(output.prefix(40))") }
            catch CodexAutomationError.invalidOutput {}
        }
    }

    func testModelCannotInventDurationCityOrAction() async throws {
        let scenarios: [(String, String)] = [
            ("明天九点提醒我", json("timer_create", label: "计时器", seconds: 300)),
            ("五分钟或十分钟计时器", json("timer_create", label: "计时器", seconds: 300)),
            ("五分钟计时器", json("timer_create", label: "计时器", seconds: 600)),
            ("五分钟计时器", json("timer_create", label: "煮鸡蛋", seconds: 300)),
            ("设置1.5小时计时器", json("timer_create", label: "计时器", seconds: 18_000)),
            ("设置-5分钟计时器", json("timer_create", label: "计时器", seconds: 300)),
            ("设置1/5小时计时器", json("timer_create", label: "计时器", seconds: 18_000)),
            ("设置5分钟计时器，查询北京天气", json("timer_create", label: "计时器", seconds: 300)),
            ("设置5分钟计时器，另建10分钟计时器", json("timer_create", label: "计时器", seconds: 900)),
            ("查询天气", json("weather_get", cityID: "beijing")),
            ("查询北京和上海的天气", json("weather_get", cityID: "beijing")),
            ("把音量调高", json("volume_read")),
            ("给微信发消息", json("volume_read"))
        ]
        for (source, output) in scenarios {
            let result = try await CodexVoiceCommandPlanner(runner: VoicePlannerRunnerStub(output)).propose(text: source)
            guard case .unsupported = result else { return XCTFail("Invented proposal for \(source)") }
        }
    }

    func testCancellationBeforeInvocationDoesNotCallRunner() async throws {
        let runner = VoicePlannerRunnerStub(json("volume_read"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CodexVoiceCommandPlanner(runner: runner).propose(text: "查看当前音量")
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        let calls = await runner.calls
        XCTAssertEqual(calls, 0)
    }

    func testLivePublicPhraseOnlyWhenOptedIn() async throws {
        guard ProcessInfo.processInfo.environment["HUSHLIGHT_LIVE_VOICE_PLANNER"] == "1" else {
            throw XCTSkip("Opt-in Codex planner call uses only a public synthetic phrase")
        }
        let result = try await CodexVoiceCommandPlanner().propose(text: "查看当前系统音量")
        XCTAssertEqual(result, .volumeRead)
    }
}
