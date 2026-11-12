import Darwin
import Foundation
import RemoteProtocol
import Testing

@testable import SennseiControl

private func tempSocketURL() -> URL {
    let hex = String((0..<8).map { _ in "0123456789abcdef".randomElement()! })
    return URL(fileURLWithPath: "/tmp/sn-\(hex).sock")
}

private let sampleStatus = RemoteStatus(connected: true, battery: 80, noise: "anc", automaticScenes: false, appVersion: "1.0")

private func makeServer(_ url: URL, delay: Duration? = nil) -> ControlServer {
    ControlServer(socketURL: url) { command in
        if let delay { try? await Task.sleep(for: delay) }
        return RemoteResponse(ok: true, status: sampleStatus)
    }
}

/// Raw connection for malformed-input tests.
private func rawExchange(_ url: URL, write bytes: [UInt8], closeAfterWrite: Bool = false) -> String {
    let fd = UnixSocket.makeSocket()
    defer { close(fd) }
    guard UnixSocket.connect(fd, to: UnixSocket.address(for: url.path)!) == 0 else { return "connect-failed" }
    bytes.withUnsafeBytes { _ = send(fd, $0.baseAddress, bytes.count, 0) }
    if closeAfterWrite { return "" }
    if case .line(let data) = UnixSocket.readLine(fd, limit: 65536, deadline: Date().addingTimeInterval(3)) {
        return String(decoding: data, as: UTF8.self)
    }
    return "no-reply"
}

// Serialized: the clients here block their thread, and the server's async handler needs a free
// cooperative-pool thread, so running many tests at once would starve it.
@Suite(.serialized) struct ControlServerTests {
    @Test func roundTripsACommandThroughTheSocket() throws {
        let url = tempSocketURL()
        let server = makeServer(url)
        try server.start()
        defer { server.stop() }
        let response = try ControlClient(socketURL: url).send(RemoteRequest(cmd: "status"))
        #expect(response.ok)
        #expect(response.status == sampleStatus)
    }

    @Test func unknownCommandIsRejectedBeforeTheHandler() throws {
        let url = tempSocketURL()
        let server = makeServer(url)
        try server.start()
        defer { server.stop() }
        let response = try ControlClient(socketURL: url).send(RemoteRequest(cmd: "rm -rf"))
        #expect(!response.ok)
        #expect(response.error?.code == .badRequest)
    }

    @Test func socketAndDirectoryHaveRestrictivePermissions() throws {
        let dir = URL(fileURLWithPath: "/tmp/snd-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("c.sock")
        let server = makeServer(url)
        try server.start()
        defer { server.stop() }
        var info = stat()
        #expect(stat(url.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(stat(dir.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)

        let loose = URL(fileURLWithPath: "/tmp/snl-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: loose) }
        try FileManager.default.createDirectory(
            at: loose, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try ControlPaths.preparePrivateDirectory(loose)
        #expect(stat(loose.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
    }

    @Test func staleSocketFileIsReplaced() throws {
        let url = tempSocketURL()
        // A socket file left behind by a crashed instance: bound, never unlinked, nobody listening.
        let fd = UnixSocket.makeSocket()
        var addr = UnixSocket.address(for: url.path)!
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)
        close(fd)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let server = makeServer(url)
        try server.start()
        defer { server.stop() }
        #expect(try ControlClient(socketURL: url).send(RemoteRequest(cmd: "ping")).ok)
    }

    @Test func aRegularFileAtTheSocketPathIsNeverDeleted() throws {
        let url = tempSocketURL()
        FileManager.default.createFile(atPath: url.path, contents: Data("keep".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let server = makeServer(url)
        #expect(throws: ControlServerError.self) { try server.start() }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aLiveServerIsNeverStolen() throws {
        let url = tempSocketURL()
        let first = makeServer(url)
        try first.start()
        defer { first.stop() }
        let second = makeServer(url)
        #expect(throws: ControlServerError.alreadyRunning) { try second.start() }
        second.stop()  // must not remove the first server's socket
        #expect(try ControlClient(socketURL: url).send(RemoteRequest(cmd: "ping")).ok)
    }

    @Test func overlongSocketPathThrowsAClearError() {
        let url = URL(fileURLWithPath: "/tmp/" + String(repeating: "a", count: 120) + ".sock")
        let server = makeServer(url)
        #expect(throws: ControlServerError.pathTooLong(url.path.utf8.count)) { try server.start() }
    }

    @Test func oversizedAndMalformedRequestsGetBadRequestAndDoNotCrash() throws {
        let url = tempSocketURL()
        let server = makeServer(url)
        try server.start()
        defer { server.stop() }
        for payload in [
            [UInt8](repeating: 0x61, count: 5000) + [0x0A],
            [UInt8](repeating: 0x61, count: 5000),
            Array("{\n".utf8), Array("\n".utf8),
        ] {
            let reply = rawExchange(url, write: payload)
            #expect(reply.contains("badRequest"), "reply: \(reply)")
        }
        #expect(try ControlClient(socketURL: url).send(RemoteRequest(cmd: "ping")).ok)
    }

    @Test func aRequestAtTheLimitIsAccepted() throws {
        let url = tempSocketURL()
        let server = makeServer(url)
        try server.start()
        defer { server.stop() }
        // 4096-byte body with a valid JSON shape but an unknown command: parsed, then badRequest from parse.
        let prefix = #"{"cmd":""#, suffix = #""}"#
        let filler = String(repeating: "x", count: RemoteWire.maxLineBytes - prefix.utf8.count - suffix.utf8.count)
        let reply = rawExchange(url, write: Array((prefix + filler + suffix + "\n").utf8))
        #expect(reply.contains("unknown command"), "reply: \(reply)")
    }

    @Test func clientGetsAppNotRunningWhenNobodyListens() {
        let client = ControlClient(socketURL: tempSocketURL())
        #expect(throws: ControlClientError.appNotRunning) { try client.send(RemoteRequest(cmd: "ping")) }
    }

    @Test func clientTimesOutOnASilentServer() throws {
        let url = tempSocketURL()
        let server = makeServer(url, delay: .seconds(2))
        try server.start()
        defer { server.stop() }
        let client = ControlClient(socketURL: url, timeout: 0.3)
        #expect(throws: ControlClientError.timedOut) { try client.send(RemoteRequest(cmd: "ping")) }
    }

    @Test func stopRemovesTheSocketFile() throws {
        let url = tempSocketURL()
        let server = makeServer(url)
        try server.start()
        #expect(FileManager.default.fileExists(atPath: url.path))
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        server.stop()
        makeServer(tempSocketURL()).stop()  // never started: harmless
    }

    @Test func aDisconnectMidRequestDoesNotCrashTheServer() throws {
        let url = tempSocketURL()
        let server = makeServer(url)
        try server.start()
        defer { server.stop() }
        _ = rawExchange(url, write: Array(#"{"cmd":"sta"#.utf8), closeAfterWrite: true)
        #expect(try ControlClient(socketURL: url).send(RemoteRequest(cmd: "ping")).ok)
    }

    @Test func concurrentClientsAllGetAnswers() throws {
        let url = tempSocketURL()
        let server = makeServer(url)
        try server.start()
        defer { server.stop() }
        let results = LockedCounter()
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            if (try? ControlClient(socketURL: url).send(RemoteRequest(cmd: "ping")).ok) == true { results.increment() }
        }
        #expect(results.value == 12)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
