import Darwin
import Dispatch
import Foundation
import RemoteProtocol

public enum ControlServerError: Error, Equatable, CustomStringConvertible {
    case pathTooLong(Int)
    case alreadyRunning
    case notASocket(String)
    case posix(String, Int32)

    public var description: String {
        switch self {
        case .pathTooLong(let n):
            return "control socket path is \(n) bytes; the limit is \(UnixSocket.maxPathBytes)"
        case .alreadyRunning: return "another instance is already listening on the control socket"
        case .notASocket(let p): return "\(p) exists and is not a socket; refusing to remove it"
        case .posix(let op, let code): return "\(op) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Serves one request per connection over a Unix domain socket owned by the current user.
public final class ControlServer: @unchecked Sendable {
    private let socketURL: URL
    private let handler: @Sendable (RemoteCommand) async -> RemoteResponse
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var active = 0
    private let queue = DispatchQueue(label: "sennsei.control.server", attributes: .concurrent)

    /// Bound on simultaneous connections, so silent clients cannot exhaust threads.
    private static let maxConnections = 16
    private static let readDeadline: TimeInterval = 5

    public init(socketURL: URL, handler: @escaping @Sendable (RemoteCommand) async -> RemoteResponse) {
        self.socketURL = socketURL
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard source == nil else { return }
        let path = socketURL.path
        guard let addr = UnixSocket.address(for: path) else {
            throw ControlServerError.pathTooLong(path.utf8.count)
        }
        let directory = socketURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try removeStaleSocket(path: path, addr: addr)

        let fd = UnixSocket.makeSocket()
        guard fd >= 0 else { throw ControlServerError.posix("socket", errno) }
        func fail(_ op: String) -> ControlServerError {
            let code = errno
            close(fd)
            return .posix(op, code)
        }
        var bindAddr = addr
        let bound = withUnsafePointer(to: &bindAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw fail("bind") }
        // Nobody can connect before listen(), so the mode is tightened before the socket is usable.
        guard chmod(path, 0o600) == 0 else {
            let error = fail("chmod")
            unlink(path)
            throw error
        }
        guard listen(fd, 16) == 0 else {
            let error = fail("listen")
            unlink(path)
            throw error
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptPending(listenFD: fd) }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    public func stop() {
        lock.lock()
        let src = source
        source = nil
        lock.unlock()
        guard let src else { return }
        src.cancel()
        unlink(socketURL.path)
    }

    // MARK: Startup

    private func removeStaleSocket(path: String, addr: sockaddr_un) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw ControlServerError.notASocket(path) }
        let probe = UnixSocket.makeSocket()
        guard probe >= 0 else { throw ControlServerError.posix("socket", errno) }
        defer { close(probe) }
        switch UnixSocket.connect(probe, to: addr) {
        case 0: throw ControlServerError.alreadyRunning
        case ECONNREFUSED: unlink(path)
        case let code: throw ControlServerError.posix("probe", code)
        }
    }

    // MARK: Connections

    private func acceptPending(listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }  // EAGAIN: drained (or the listener is closing)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
                close(fd)
                continue
            }
            lock.lock()
            let admit = active < Self.maxConnections
            if admit { active += 1 }
            lock.unlock()
            guard admit else {
                close(fd)
                continue
            }
            queue.async { [self] in serve(fd) }
        }
    }

    private func finish(_ fd: Int32) {
        // Discard whatever the client still sends so closing does not reset the connection
        // before it has read our reply; bounded in bytes and time.
        shutdown(fd, SHUT_WR)
        var sink = [UInt8](repeating: 0, count: 1024)
        var drained = 0
        let deadline = Date().addingTimeInterval(0.2)
        while drained < 65536, deadline.timeIntervalSinceNow > 0 {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 50) > 0 else { break }
            let n = recv(fd, &sink, sink.count, 0)
            if n <= 0 { break }
            drained += n
        }
        close(fd)
        lock.lock()
        active -= 1
        lock.unlock()
    }

    private func serve(_ fd: Int32) {
        let deadline = Date().addingTimeInterval(Self.readDeadline)
        let outcome = UnixSocket.readLine(fd, limit: RemoteWire.maxLineBytes + 1, deadline: deadline)
        func reply(_ response: RemoteResponse) {
            _ = UnixSocket.writeAll(fd, RemoteWire.encode(response))
            finish(fd)
        }
        func bad(_ message: String) {
            reply(RemoteResponse(ok: false, error: RemoteError(code: .badRequest, message: message)))
        }
        switch outcome {
        case .failed:
            finish(fd)
        case .eof, .timedOut:
            bad("incomplete request")
        case .tooLong:
            bad("request too long")
        case .line(let line):
            guard let request: RemoteRequest = RemoteWire.decodeLine(line) else {
                bad("malformed request")
                return
            }
            switch request.parsed {
            case .failure(let error):
                reply(RemoteResponse(ok: false, error: error))
            case .success(let command):
                let handler = self.handler
                Task { [self] in
                    let response = await handler(command)
                    _ = UnixSocket.writeAll(fd, RemoteWire.encode(response))
                    finish(fd)
                }
            }
        }
    }
}
