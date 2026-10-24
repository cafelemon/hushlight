import Foundation
import Darwin
import WorkbenchKit

private enum ConfigurationError: Error { case invalidArguments, invalidCredentialFile }

private struct Configuration {
    let credentialFile: String
    let socketPath: String

    init(arguments: [String]) throws {
        var credentialFile: String?
        var socketPath = WorkbenchPaths.defaultSocketPath
        var index = 1
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw ConfigurationError.invalidArguments }
            switch arguments[index] {
            case "--credential-file": credentialFile = arguments[index + 1]
            case "--socket": socketPath = arguments[index + 1]
            default: throw ConfigurationError.invalidArguments
            }
            index += 2
        }
        guard let credentialFile, credentialFile.hasPrefix("/"), socketPath.hasPrefix("/") else {
            throw ConfigurationError.invalidArguments
        }
        self.credentialFile = credentialFile
        self.socketPath = socketPath
    }

    func credential() throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: credentialFile)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              let mode = attributes[.posixPermissions] as? NSNumber,
              (mode.intValue & 0o077) == 0,
              let size = attributes[.size] as? NSNumber,
              size.intValue <= 4_096,
              let contents = String(data: try Data(contentsOf: URL(fileURLWithPath: credentialFile)), encoding: .utf8) else {
            throw ConfigurationError.invalidCredentialFile
        }
        let credential = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty, !credential.contains("\n"), !credential.contains("\r") else {
            throw ConfigurationError.invalidCredentialFile
        }
        return credential
    }
}

private enum InputLine {
    case line(Data)
    case oversized
    case end
}

private struct BoundedStdin {
    static let maximumLineBytes = 1_048_576
    private var buffer = Data()
    private var discard = false
    private var eof = false

    mutating func next() -> InputLine {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if discard { discard = false; return .oversized }
                if line.count > Self.maximumLineBytes { return .oversized }
                return .line(line)
            }
            if eof {
                if discard { discard = false; return .oversized }
                guard !buffer.isEmpty else { return .end }
                let line = buffer
                buffer.removeAll()
                return line.count > Self.maximumLineBytes ? .oversized : .line(line)
            }
            if buffer.count > Self.maximumLineBytes { buffer.removeAll(); discard = true }
            var chunk = [UInt8](repeating: 0, count: 4_096)
            let readCount = Darwin.read(STDIN_FILENO, &chunk, chunk.count)
            if readCount <= 0 { eof = true; continue }
            if discard {
                if let newline = chunk[..<readCount].firstIndex(of: 10) {
                    discard = false
                    buffer.append(contentsOf: chunk[(newline + 1)..<readCount])
                    return .oversized
                }
            } else {
                buffer.append(contentsOf: chunk[..<readCount])
            }
        }
    }
}

private func writeLine(_ data: Data) {
    var output = data
    output.append(10)
    output.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let count = Darwin.write(STDOUT_FILENO, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            guard count > 0 else { return }
            offset += count
        }
    }
}

do {
    let configuration = try Configuration(arguments: CommandLine.arguments)
    _ = try configuration.credential()
    let client = WorkbenchClient(socketPath: configuration.socketPath)
    let server = MCPServer { operation, action, parameters, requestID in
        let request = WorkbenchRequest(
            requestID: requestID ?? UUID().uuidString,
            operation: operation,
            action: action,
            parameters: parameters,
            credential: try configuration.credential()
        )
        return try client.request(request)
    }
    var stdin = BoundedStdin()
    while true {
        switch stdin.next() {
        case .line(let input):
            if let result = server.process(input) { writeLine(result) }
        case .oversized:
            let error = JSONValue.object([
                "jsonrpc": .string("2.0"), "id": .null,
                "error": .object(["code": .number(-32700), "message": .string("Input frame too large")])
            ])
            if let result = try? JSONEncoder().encode(error) { writeLine(result) }
        case .end:
            exit(EXIT_SUCCESS)
        }
    }
} catch {
    fputs("agent-workbench-mcp: invalid configuration or unreadable credential file\n", stderr)
    exit(EXIT_FAILURE)
}
