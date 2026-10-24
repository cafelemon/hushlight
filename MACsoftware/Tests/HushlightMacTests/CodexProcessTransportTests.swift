import Foundation
import XCTest
@testable import HushlightMac

final class CodexProcessTransportTests: XCTestCase {
    private static func execute(_ code: String, input: Data = Data(), timeout: TimeInterval = 3) async throws -> CodexProcessResult {
        try await CodexProcessTransport().run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", code], environment: ["PATH": "/usr/bin:/bin"],
            directory: FileManager.default.temporaryDirectory, input: input, timeout: timeout)
    }

    func testLiveSyntheticCodexRunner() async throws {
        guard ProcessInfo.processInfo.environment["HUSHLIGHT_LIVE_CODEX_SMOKE"] == "1" else { throw XCTSkip("Opt-in synthetic Codex request, no personal input") }
        let schema = Data(#"{"type":"object","additionalProperties":false,"properties":{"status":{"type":"string","enum":["analysis_only"]}},"required":["status"]}"#.utf8)
        let result = try await CodexAutomationRunner().decide(prompt: "Synthetic test only. Return status analysis_only. No tools.", schema: schema)
        let value = try JSONSerialization.jsonObject(with: result) as? [String: String]
        XCTAssertEqual(value, ["status": "analysis_only"])
    }

    func testManualSystemProxyIsReadWithoutInheritingSecrets() {
        let settings: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 12345,
                                      "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 12345,
                                      "ProxyPassword": "never-copy", "SOME_TOKEN": "never-copy"]
        let environment = CodexSystemEnvironment.environment(settings: settings, home: "/Users/example")
        XCTAssertEqual(environment["HTTPS_PROXY"], "http://127.0.0.1:12345")
        XCTAssertEqual(environment["HTTP_PROXY"], "http://127.0.0.1:12345")
        XCTAssertEqual(environment.count, 5)
        XCTAssertFalse(environment.values.contains("never-copy"))
        XCTAssertNil(CodexSystemEnvironment.environment(settings: ["HTTPSEnable": 1, "HTTPSProxy": "user:password@host", "HTTPSPort": 10], home: "/home")["HTTPS_PROXY"])
        XCTAssertNil(CodexSystemEnvironment.environment(settings: settings.merging(["ProxyAutoConfigEnable": 1], uniquingKeysWith: { _, new in new }), home: "/home")["HTTPS_PROXY"])
    }

    func testRecoveredWarningDoesNotRejectSuccessfulModelReply() {
        let warning = #"{"type":"error","message":"Reconnecting after 429 request timed out"}"#
        XCTAssertNil(CodexAutomationError.classify(.init(exitCode: 0, stdout: Data(warning.utf8), stderr: Data("model catalog request timed out".utf8), timedOut: false)))
    }

    func testSaturatedOutputPipesAreDrainedBeforeLargeInputCompletes() async throws {
        let result = try await Self.execute("""
        import os, sys
        os.write(1, b'x' * 131072)
        os.write(2, b'y' * 131072)
        body = sys.stdin.buffer.read()
        sys.exit(0 if len(body) == 100000 else 2)
        """, input: Data(repeating: 97, count: 100_000), timeout: 5)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout.count, 65_536)
        XCTAssertEqual(result.stderr.count, 65_536)
    }

    func testTimeoutEscalatesWhenChildIgnoresTerminate() async throws {
        let start = Date()
        let result = try await Self.execute("import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)", timeout: 0.3)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        XCTAssertNotEqual(result.exitCode, 0)
    }

    func testAlreadyCancelledTaskDoesNotLaunchChild() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("codex-pre-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: marker) }
        let path = marker.path
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Self.execute("import pathlib; pathlib.Path('" + path + "').write_text('launched')")
        }
        do { _ = try await task.value; XCTFail("Cancellation") } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCancellationTerminatesChildAndDoesNotReportOrdinaryFailure() async throws {
        let task = Task { try await Self.execute("import time; time.sleep(60)", timeout: 20) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation") }
        catch is CancellationError {}
    }

    func testModelTextCannotMasqueradeAsDiagnostic() {
        let text = #"{"type":"item.completed","item":{"text":"private body: quota 401 request timed out"}}"#
        XCTAssertNil(CodexAutomationError.classify(.init(exitCode: 0, stdout: Data(text.utf8), stderr: Data(), timedOut: false)))
        let timeout = #"{"type":"error","message":"Reconnecting... 2/5 (request timed out)"}"#
        XCTAssertEqual(CodexAutomationError.classify(.init(exitCode: 9, stdout: Data(timeout.utf8), stderr: Data(), timedOut: true)), .requestTimedOut)
        let quota = #"{"type":"turn.failed","error":{"message":"You hit your usage limit; private account detail"}}"#
        XCTAssertEqual(CodexAutomationError.classify(.init(exitCode: 1, stdout: Data(quota.utf8), stderr: Data(), timedOut: false)), .rateLimited)
        XCTAssertEqual(CodexAutomationError.classify(.init(exitCode: 9, stdout: Data(), stderr: Data("earlier 401".utf8), timedOut: true)), .timedOut)
    }

    func testRunnerSeparatesMissingMalformedAndOversizedResults() async throws {
        for mode in [RunnerStub.Mode.missing, .malformed, .oversized] {
            let stub = RunnerStub(mode: mode)
            let runner = CodexAutomationRunner(executableURL: URL(fileURLWithPath: "/usr/bin/true"), transport: stub)
            do { _ = try await runner.decide(prompt: "synthetic", schema: Data("{}".utf8)); XCTFail("Invalid result") }
            catch CodexAutomationError.invalidOutput {}
            let directory = await stub.directory
            XCTAssertNotNil(directory)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory!.path))
        }
    }

    func testRunnerUsesOnlyBoundedSafeConfigurationAndReturnsJSON() async throws {
        let stub = RunnerStub(mode: .valid)
        let runner = CodexAutomationRunner(executableURL: URL(fileURLWithPath: "/usr/bin/true"), transport: stub)
        let result = try await runner.decide(prompt: "synthetic", schema: Data("{}".utf8))
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "{\"status\":\"analysis_only\"}")
        let verified = await stub.verified
        XCTAssertTrue(verified)
    }
}

private actor RunnerStub: CodexProcessDriving {
    enum Mode: Sendable { case missing, malformed, oversized, valid }
    let mode: Mode
    var directory: URL?
    var verified = false
    init(mode: Mode) { self.mode = mode }
    func run(executable: URL, arguments: [String], environment: [String: String], directory: URL, input: Data, timeout: TimeInterval) async throws -> CodexProcessResult {
        self.directory = directory
        let modeBits = (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        verified = arguments.contains("--json") && arguments.contains("--ignore-user-config") && arguments.contains("features.shell_tool=false") && environment["HOME"] != nil && Set(environment.keys).isSubset(of: ["PATH", "HOME", "CODEX_HOME", "HTTP_PROXY", "HTTPS_PROXY"]) && modeBits & 0o777 == 0o700
        verified = verified && !arguments.contains("--output-last-message")
        let text: String
        switch mode {
        case .missing: return .init(exitCode: 0, stdout: Data(), stderr: Data(), timedOut: false)
        case .malformed: text = "not-json"
        case .oversized: text = String(repeating: "a", count: 32_001)
        case .valid: text = "{\"status\":\"analysis_only\"}"
        }
        let event: [String: Any] = ["type": "item.completed", "item": ["type": "agent_message", "text": text]]
        return .init(exitCode: 0, stdout: try JSONSerialization.data(withJSONObject: event), stderr: Data(), timedOut: false)
    }
}
