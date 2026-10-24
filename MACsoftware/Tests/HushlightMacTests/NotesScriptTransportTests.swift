import Foundation
import XCTest
@testable import HushlightMac

final class NotesScriptTransportTests: XCTestCase {
    func testConstantScriptJSONTransportWithStubbedNotesHandler() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: project.appendingPathComponent("Sources/HushlightMac/Resources/NotesBridge.applescript"), encoding: .utf8)
        let boundary = try XCTUnwrap(source.range(of: "on performOperation("))
        let prefix = String(source[..<boundary.lowerBound])
        // Execute only Foundation stdin/stdout transport; no Notes code is included in this stub.
        let stub = prefix + """
        on performOperation(operationName, accountID, folderID, noteID, expectedHTML, payloadHTML, pageOffset, pageLimit)
            if operationName is "write-error" then
                set my writeMayHaveOccurred to true
                error number -1743
            end if
            if operationName is "preflight-error" then error number -1743
            return {{operationName, accountID, folderID, noteID, expectedHTML, payloadHTML}}
        end performOperation
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-transport-\(UUID()).applescript")
        try stub.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let request = NotesScriptRequest(operation: "create", accountID: "scope", folderID: "folder", noteID: "note",
                                         expectedHTML: "a\"\\\n中文", html: "<div>&amp; '\" \\</div>")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [url.path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(request))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let rows = try JSONDecoder().decode([[String]].self, from: data)
        XCTAssertEqual(rows, [["create", "scope", "folder", "note", request.expectedHTML, request.html]])
        for (operation, expectedStage) in [("preflight-error", "not_applied"), ("write-error", "uncertain")] {
            let probe = Process(), probeInput = Pipe(), probeOutput = Pipe()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            probe.arguments = [url.path]
            probe.standardInput = probeInput; probe.standardOutput = probeOutput; probe.standardError = FileHandle.nullDevice
            try probe.run()
            try probeInput.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(NotesScriptRequest(operation: operation)))
            try probeInput.fileHandleForWriting.close()
            let output = probeOutput.fileHandleForReading.readDataToEndOfFile()
            probe.waitUntilExit()
            XCTAssertEqual(try JSONDecoder().decode([[String]].self, from: output), [["error", "-1743", expectedStage]])
        }
    }
}
