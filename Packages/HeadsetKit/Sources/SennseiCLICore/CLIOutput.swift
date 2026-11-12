import Foundation
import RemoteProtocol
import SennseiControl

public enum CLIOutput {
    public typealias Result = (stdout: String, stderr: String, exitCode: Int32)

    /// Replaces terminal control characters (C0, DEL, C1) with "?" so app-supplied text cannot
    /// rewrite the terminal. Applied to every human-readable string; never to the JSON path.
    public static func sanitize(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map {
            $0.value < 0x20 || (0x7F...0x9F).contains($0.value) ? "?" : $0
        }))
    }

    public static func render(
        _ response: RemoteResponse, for request: RemoteRequest, style: CLIStyle = .normal
    ) -> Result {
        let warning = response.warning.map { "warning: \(sanitize($0))\n" } ?? ""
        guard response.ok else {
            let message = sanitize(response.error?.message ?? "command failed")
            return ("", "error: \(message)\n", 1)
        }
        switch style {
        case .json:
            let line = String(decoding: RemoteWire.encode(response), as: UTF8.self)
            return (line, warning, 0)
        case .battery:
            let value = response.status?.battery.map(String.init) ?? "unknown"
            return (value + "\n", warning, 0)
        case .normal:
            guard request.cmd == "status" else { return ("ok\n", warning, 0) }
            guard let s = response.status else { return ("", "error: reply had no status\n", 1) }
            return (statusLines(s), warning, 0)
        }
    }

    public static func render(error: ControlClientError) -> Result {
        switch error {
        case .appNotRunning:
            return ("", "error: Sennsei is not running. Open the Sennsei app and try again.\n", 3)
        case .timedOut:
            return ("", "error: timed out waiting for Sennsei to answer\n", 4)
        case .protocolError(let detail):
            return ("", "error: \(sanitize(detail))\n", 1)
        }
    }

    static func statusLines(_ s: RemoteStatus) -> String {
        func t(_ v: String?) -> String? { v.map(sanitize) }
        func onOff(_ b: Bool?) -> String { b.map { $0 ? "on" : "off" } ?? "unknown" }
        return [
            "Headset: \(s.connected ? "connected" : "not connected")",
            "Battery: \(s.battery.map { "\($0)%" } ?? "unknown")",
            "Noise control: \(t(s.noise) ?? "unknown")",
            "Pause in Transparency: \(onOff(s.pauseInTransparency))",
            "Equalizer: \(t(s.eqPreset) ?? "unknown")",
            "Scene: \(t(s.activeScene) ?? "none")",
            "Automatic scenes: \(onOff(s.automaticScenes))",
            "App version: \(sanitize(s.appVersion))",
        ].joined(separator: "\n") + "\n"
    }
}
