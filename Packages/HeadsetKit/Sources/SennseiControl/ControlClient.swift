import Darwin
import Foundation
import RemoteProtocol

public enum ControlClientError: Error, Equatable {
    case appNotRunning, timedOut, protocolError(String)
}

/// Sends one request to the running app and returns its one-line reply.
public struct ControlClient: Sendable {
    public let socketURL: URL
    public let timeout: TimeInterval

    public init(socketURL: URL, timeout: TimeInterval = 15) {
        self.socketURL = socketURL
        self.timeout = timeout
    }

    public func send(_ request: RemoteRequest) throws -> RemoteResponse {
        let deadline = Date().addingTimeInterval(timeout)
        guard let addr = UnixSocket.address(for: socketURL.path) else {
            throw ControlClientError.protocolError("socket path too long")
        }
        let fd = UnixSocket.makeSocket()
        guard fd >= 0 else { throw ControlClientError.protocolError("socket: errno \(errno)") }
        defer { close(fd) }
        switch UnixSocket.connect(fd, to: addr) {
        case 0: break
        case ENOENT, ECONNREFUSED: throw ControlClientError.appNotRunning
        case let code: throw ControlClientError.protocolError("connect: \(String(cString: strerror(code)))")
        }
        var timeoutValue = timeval(
            tv_sec: Int(max(timeout, 0.001).rounded(.up)), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))
        guard UnixSocket.writeAll(fd, RemoteWire.encode(request)) else {
            throw ControlClientError.protocolError("write failed")
        }
        switch UnixSocket.readLine(fd, limit: 65536, deadline: deadline) {
        case .line(let line):
            guard let response: RemoteResponse = RemoteWire.decodeLine(line) else {
                throw ControlClientError.protocolError("unreadable reply")
            }
            return response
        case .timedOut: throw ControlClientError.timedOut
        case .eof: throw ControlClientError.protocolError("connection closed without a reply")
        case .tooLong: throw ControlClientError.protocolError("reply too long")
        case .failed: throw ControlClientError.protocolError("read failed")
        }
    }
}
