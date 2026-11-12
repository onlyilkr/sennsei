import Darwin
import Foundation

public enum ControlPaths {
    /// `~/Library/Application Support/Sennsei/control.sock`.
    public static func defaultSocketURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Sennsei", isDirectory: true).appendingPathComponent("control.sock")
    }

    /// Creates `directory` with mode 0700, or tightens an existing one to 0700.
    /// Only call this for a directory the app owns (never for a shared one such as /tmp).
    public static func preparePrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// Darwin socket helpers shared by the server and the client.
enum UnixSocket {
    /// `sun_path` holds 104 bytes including the terminating NUL.
    static let maxPathBytes = 103

    static func address(for path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPathBytes else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }

    static func makeSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd >= 0 {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        return fd
    }

    /// Returns 0 on success, otherwise errno.
    static func connect(_ fd: Int32, to addr: sockaddr_un) -> Int32 {
        var addr = addr
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0 ? 0 : errno
    }

    enum ReadOutcome { case line(Data), eof, timedOut, tooLong, failed }

    /// Reads until the first newline, never holding more than `limit` bytes, within `deadline`.
    static func readLine(_ fd: Int32, limit: Int, deadline: Date) -> ReadOutcome {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while true {
            let remaining = Int(deadline.timeIntervalSinceNow * 1000)
            if remaining <= 0 { return .timedOut }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(min(remaining, 1000)))
            if ready < 0 { if errno == EINTR { continue }; return .failed }
            if ready == 0 { continue }
            let want = min(chunk.count, limit - buffer.count)
            let n = recv(fd, &chunk, want, 0)
            if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return .failed }
            if n == 0 { return .eof }
            buffer.append(contentsOf: chunk[0..<n])
            if let nl = buffer.firstIndex(of: 0x0A) { return .line(Data(buffer[0...nl])) }
            if buffer.count >= limit { return .tooLong }
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { send(fd, $0.baseAddress! + offset, bytes.count - offset, 0) }
            if n < 0 { if errno == EINTR { continue }; return false }
            offset += n
        }
        return true
    }
}
