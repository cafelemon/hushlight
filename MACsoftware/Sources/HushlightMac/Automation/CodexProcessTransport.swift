import Foundation
import Darwin

struct CodexProcessResult: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool
}

protocol CodexProcessDriving: Sendable {
    func run(executable: URL, arguments: [String], environment: [String: String], directory: URL,
             input: Data, timeout: TimeInterval) async throws -> CodexProcessResult
}

private final class CodexCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Drains both pipes while writing stdin. No raw output is logged or persisted.
/// Nonblocking reads do not wait indefinitely for inherited pipes held by descendants.
struct CodexProcessTransport: CodexProcessDriving {
    private static let captureLimit = 65_536

    func run(executable: URL, arguments: [String], environment: [String: String], directory: URL,
             input: Data, timeout: TimeInterval) async throws -> CodexProcessResult {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0, input.count <= 128_000 else { throw CodexAutomationError.invalidInput }
        let cancellation = CodexCancellation()
        return try await withTaskCancellationHandler {
            let result = try await Task.detached(priority: .utility) {
                let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                process.executableURL = executable; process.arguments = arguments
                process.environment = environment; process.currentDirectoryURL = directory
                process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
                let writeFD = stdin.fileHandleForWriting.fileDescriptor
                let outputFD = stdout.fileHandleForReading.fileDescriptor
                let errorFD = stderr.fileHandleForReading.fileDescriptor
                guard fcntl(writeFD, F_SETNOSIGPIPE, 1) != -1 else { throw CodexAutomationError.unavailable }
                for fd in [writeFD, outputFD, errorFD] {
                    guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else { throw CodexAutomationError.unavailable }
                }
                defer {
                    try? stdin.fileHandleForWriting.close()
                    try? stdout.fileHandleForReading.close()
                    try? stderr.fileHandleForReading.close()
                }
                guard !cancellation.cancelled else { throw CancellationError() }
                try process.run()
                let start = DispatchTime.now().uptimeNanoseconds
                var output = Data(), errors = Data(), offset = 0
                var inputClosed = false, timeoutReached = false, stoppedAt: UInt64?
                while process.isRunning {
                    let current = DispatchTime.now().uptimeNanoseconds
                    let expired = Double(current - start) / 1_000_000_000 >= timeout
                    if (expired || cancellation.cancelled), stoppedAt == nil {
                        timeoutReached = expired && !cancellation.cancelled
                        stoppedAt = current; process.terminate()
                    }
                    if let stoppedAt, current - stoppedAt >= 1_000_000_000, process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                    Self.drain(outputFD, into: &output)
                    Self.drain(errorFD, into: &errors)
                    if !inputClosed {
                        if offset < input.count && stoppedAt == nil {
                            let count = input.withUnsafeBytes { buffer in
                                Darwin.write(writeFD, buffer.baseAddress!.advanced(by: offset), min(8192, input.count - offset))
                            }
                            if count > 0 { offset += count }
                            else if count < 0 && errno != EAGAIN && errno != EINTR { inputClosed = true; try? stdin.fileHandleForWriting.close() }
                        }
                        if offset == input.count || stoppedAt != nil {
                            inputClosed = true; try? stdin.fileHandleForWriting.close()
                        }
                    }
                    // Bounded observation interval; cancellation/timeout remains responsive.
                    var descriptors = [pollfd(fd: outputFD, events: Int16(POLLIN), revents: 0), pollfd(fd: errorFD, events: Int16(POLLIN), revents: 0)]
                    let ready = poll(&descriptors, nfds_t(descriptors.count), 20)
                    if ready > 0 && !descriptors.contains(where: { $0.revents & Int16(POLLIN) != 0 }) {
                        _ = poll(nil, 0, 10) // EOF/HUP must not create a busy spin while the child exits.
                    }
                }
                process.waitUntilExit()
                Self.drain(outputFD, into: &output)
                Self.drain(errorFD, into: &errors)
                return CodexProcessResult(exitCode: process.terminationStatus, stdout: output, stderr: errors, timedOut: timeoutReached)
            }.value
            if Task.isCancelled { throw CancellationError() }
            return result
        } onCancel: { cancellation.cancel() }
    }

    private static func drain(_ fd: Int32, into captured: inout Data) {
        var bytes = [UInt8](repeating: 0, count: 8192)
        // Bound work per iteration even for a noisy child; timeout checks cannot be starved.
        for _ in 0..<16 {
            let count = Darwin.read(fd, &bytes, bytes.count)
            guard count > 0 else { return }
            captured.append(contentsOf: bytes.prefix(count))
            if captured.count > captureLimit { captured.removeFirst(captured.count - captureLimit) }
        }
    }
}
