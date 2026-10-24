import Foundation
import Darwin

public enum WorkbenchClientError: Error, Sendable { case unavailable, invalidResponse, oversizedResponse }

public struct WorkbenchClient: Sendable {
    public let socketPath: String
    public init(socketPath: String = WorkbenchPaths.defaultSocketPath) { self.socketPath = socketPath }

    public func request(_ request: WorkbenchRequest) throws -> WorkbenchResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WorkbenchClientError.unavailable }
        defer { close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 45, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw WorkbenchClientError.unavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw WorkbenchClientError.unavailable }
        var outgoing = try JSONEncoder().encode(request)
        outgoing.append(10)
        guard outgoing.count <= 65_536 else { throw WorkbenchClientError.unavailable }
        try outgoing.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                guard n > 0 else { throw WorkbenchClientError.unavailable }
                sent += n
            }
        }
        var data = Data()
        var byte: UInt8 = 0
        while data.count <= 1_048_576 {
            let n = Darwin.read(fd, &byte, 1)
            guard n == 1 else { throw WorkbenchClientError.invalidResponse }
            if byte == 10 {
                let response = try JSONDecoder().decode(WorkbenchResponse.self, from: data)
                guard response.version == 1, response.requestID == request.requestID else { throw WorkbenchClientError.invalidResponse }
                return response
            }
            data.append(byte)
        }
        throw WorkbenchClientError.oversizedResponse
    }
}
