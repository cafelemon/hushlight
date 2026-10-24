import CoreGraphics
import XCTest
@testable import HushlightMac

private actor WindowDecisionRunner: AutomationCodexRunning {
    let output: String
    var prompt = ""
    var calls = 0
    init(_ output: String) { self.output = output }
    func decide(prompt: String, schema: Data) async throws -> Data {
        self.prompt = prompt; calls += 1
        return Data(output.utf8)
    }
}
final class CodexWindowTextSelectorTests: XCTestCase {
    private func line(_ text: String, confidence: Float = 0.99) -> WindowVisionLine {
        .init(text: text, confidence: confidence, rect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.05), region: "test")
    }
    func testChoosesOriginalObservationIndexAndDoesNotSendLowConfidenceText() async throws {
        let runner = WindowDecisionRunner(#"{"status":"selected","index":1}"#)
        let choice = try await CodexWindowTextSelector(runner: runner).select(targetText: "工作群", lines: [line("Excluded private text", confidence: 0.1),line("产品研发工作群")])
        XCTAssertEqual(choice, .selected(index: 1))
        let prompt = await runner.prompt
        XCTAssertFalse(prompt.contains("Excluded private text"))
        XCTAssertTrue(prompt.contains("产品研发工作群"))
        XCTAssertTrue(prompt.contains("untrusted OCR DATA"))
    }
    func testRejectsInventedFilteredBooleanFractionAndExtraFields() async throws {
        for output in [#"{"status":"selected","index":99}"#, #"{"status":"selected","index":0}"#, #"{"status":"selected","index":true}"#, #"{"status":"selected","index":1.5}"#, #"{"status":"selected","index":1,"instruction":"click"}"#] {
            do {
                _ = try await CodexWindowTextSelector(runner: WindowDecisionRunner(output)).select(targetText: "目标", lines: [line("Excluded", confidence: 0.1),line("目标")])
                XCTFail("Untrusted selection accepted")
            } catch CodexAutomationError.invalidOutput {}
        }
    }
    func testMissingAndAmbiguousAreNotSuccessAndMustHaveNullIndex() async throws {
        for (status, expected) in [("not_found",AutomaticWindowSelectionChoice.notFound),("ambiguous",.ambiguous)] {
            let runner = WindowDecisionRunner("{\"status\":\"\(status)\",\"index\":null}")
            let choice = try await CodexWindowTextSelector(runner: runner).select(targetText: "目标", lines: [line("目标")])
            XCTAssertEqual(choice, expected)
        }
        do {
            _ = try await CodexWindowTextSelector(runner: WindowDecisionRunner(#"{"status":"ambiguous","index":0}"#)).select(targetText: "目标", lines: [line("目标")])
            XCTFail("Ambiguous must not have an index")
        } catch CodexAutomationError.invalidOutput {}
    }
    func testOversizedInputAndEmptyCandidatesDoNotInvokeAgent() async throws {
        let runner = WindowDecisionRunner("{}"), selector = CodexWindowTextSelector(runner: runner)
        do {
            _ = try await selector.select(targetText: "目标", lines: (0..<201).map { _ in line("目标") })
            XCTFail("Input bound ignored")
        } catch CodexAutomationError.invalidInput {}
        let empty = try await selector.select(targetText: "目标", lines: [line("Low",confidence: 0.1)])
        XCTAssertEqual(empty,.notFound)
        let calls = await runner.calls; XCTAssertEqual(calls,0)
    }
    func testLowConfidenceDuplicateCannotBeHiddenByFiltering() async throws {
        let runner = WindowDecisionRunner(#"{"status":"selected","index":0}"#)
        let choice = try await CodexWindowTextSelector(runner: runner).select(targetText: "研发群", lines: [line("研发群"),line("研发群",confidence: 0.1)])
        XCTAssertEqual(choice,.ambiguous)
    }
    func testCancelledTaskDoesNotDiscloseOCR() async throws {
        let runner = WindowDecisionRunner(#"{"status":"selected","index":0}"#)
        let observation = line("Private")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CodexWindowTextSelector(runner: runner).select(targetText: "目标",lines: [observation])
        }
        do { _ = try await task.value; XCTFail("Cancelled task accepted") } catch is CancellationError {}
        let calls = await runner.calls; XCTAssertEqual(calls,0)
    }
}
