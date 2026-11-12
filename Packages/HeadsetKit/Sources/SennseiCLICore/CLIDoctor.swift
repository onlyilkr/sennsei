import Foundation
import RemoteProtocol
import SennseiControl

/// Read-only diagnostics. Talks only to the app's control socket; never touches Bluetooth.
public struct CLIDoctor {
    public static func run(socketURL: URL) -> (report: String, exitCode: Int32) {
        var lines = [String]()
        var failed = false
        func line(_ name: String, _ ok: Bool, _ detail: String) {
            if !ok { failed = true }
            lines.append("\(name): \(ok ? "ok" : "fail") (\(detail))")
        }

        let socketExists = FileManager.default.fileExists(atPath: socketURL.path)
        line("socket", socketExists, socketExists ? CLIOutput.sanitize(socketURL.path) : "\(CLIOutput.sanitize(socketURL.path)) not found")

        let client = ControlClient(socketURL: socketURL, timeout: 5)
        var status: RemoteStatus?
        var appDetail = "Sennsei is not running"
        if socketExists {
            do {
                let reply = try client.send(RemoteRequest(cmd: "status"))
                if reply.ok, let s = reply.status {
                    status = s
                } else {
                    appDetail = CLIOutput.sanitize(reply.error?.message ?? "unexpected reply")
                }
            } catch let e as ControlClientError {
                switch e {
                case .appNotRunning: appDetail = "Sennsei is not running"
                case .timedOut: appDetail = "timed out"
                case .protocolError(let d): appDetail = CLIOutput.sanitize(d)
                }
            } catch {
                appDetail = CLIOutput.sanitize("\(error)")
            }
        }
        line("app", status != nil, status != nil ? "responding" : appDetail)
        line("version", status != nil, "app \(status.map { CLIOutput.sanitize($0.appVersion) } ?? "unknown"), cli \(CLIVersion.current)")
        line("headset", status?.connected == true, status?.connected == true ? "connected" : "not connected")
        let battery = status?.battery
        line("battery", battery != nil, battery.map { "\($0)%" } ?? "unknown")
        return (lines.joined(separator: "\n") + "\n", failed ? 1 : 0)
    }
}
