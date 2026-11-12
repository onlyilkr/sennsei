import Foundation
import RemoteProtocol
import SennseiControl

public enum CLIStyle: Equatable, Sendable { case normal, battery, json }

public struct CLIUsageError: Error, Equatable, Sendable {
    public let message: String
    public var exitCode: Int32 { 2 }
    public init(_ message: String) { self.message = message }
}

public enum CLICommand: Equatable, Sendable {
    case send(RemoteRequest, style: CLIStyle = .normal)
    case doctor, help, version

    public static let usage = """
        Usage: sennsei <command>

        Commands:
          noise <anc|transparency|off|next>   Set or cycle the noise control mode
          anc <on|off>                        Shortcut: on = noise anc, off = noise off
          pause <on|off>                      Pause playback in Transparency mode
          eq <preset|next>                    Select an equalizer preset (quote names with spaces)
          scene <id>                          Activate a scene
          auto <on|off>                       Turn automatic scenes on or off
          status [--json]                     Show the headset state (--json prints the raw reply)
          battery                             Print the battery percentage, or "unknown"
          doctor                              Check the connection to the Sennsei app
          --help                              Show this help
          --version                           Show the version

        Exit codes:
          0  success
          1  the command failed
          2  usage error
          3  Sennsei is not running
          4  timed out
        """

    public static func parse(_ args: [String]) -> Result<CLICommand, CLIUsageError> {
        func fail(_ m: String) -> Result<CLICommand, CLIUsageError> { .failure(CLIUsageError(m)) }
        guard let name = args.first else { return fail("missing command") }
        let rest = Array(args.dropFirst())
        func exactlyOne(_ allowed: [String]?, _ what: String) -> String? {
            guard rest.count == 1 else { return nil }
            let value = rest[0]
            if let allowed, !allowed.contains(value.lowercased()) { return nil }
            return value
        }
        switch name {
        case "--help", "-h", "help":
            return rest.isEmpty ? .success(.help) : fail("\(name) takes no arguments")
        case "--version":
            return rest.isEmpty ? .success(.version) : fail("--version takes no arguments")
        case "doctor":
            return rest.isEmpty ? .success(.doctor) : fail("doctor takes no arguments")
        case "status":
            if rest.isEmpty { return .success(.send(RemoteRequest(cmd: "status"))) }
            if rest == ["--json"] { return .success(.send(RemoteRequest(cmd: "status"), style: .json)) }
            return fail("usage: sennsei status [--json]")
        case "battery":
            return rest.isEmpty
                ? .success(.send(RemoteRequest(cmd: "status"), style: .battery)) : fail("battery takes no arguments")
        case "noise":
            guard let v = exactlyOne(["anc", "transparency", "off", "next"], "mode") else {
                return fail("usage: sennsei noise <anc|transparency|off|next>")
            }
            return .success(.send(RemoteRequest(cmd: "noise", arg: v.lowercased())))
        case "anc":
            guard let v = exactlyOne(["on", "off"], "state") else { return fail("usage: sennsei anc <on|off>") }
            return .success(.send(RemoteRequest(cmd: "noise", arg: v.lowercased() == "on" ? "anc" : "off")))
        case "pause", "auto":
            guard let v = exactlyOne(["on", "off"], "state") else { return fail("usage: sennsei \(name) <on|off>") }
            return .success(.send(RemoteRequest(cmd: name, arg: v.lowercased())))
        case "eq":
            guard let v = exactlyOne(nil, "preset"), !v.trimmingCharacters(in: .whitespaces).isEmpty else {
                return fail("usage: sennsei eq <preset|next>")
            }
            return .success(.send(RemoteRequest(cmd: "eq", arg: v)))
        case "scene":
            guard let v = exactlyOne(nil, "id"), !v.trimmingCharacters(in: .whitespaces).isEmpty else {
                return fail("usage: sennsei scene <id>")
            }
            return .success(.send(RemoteRequest(cmd: "scene", arg: v)))
        default:
            return fail("unknown command: \(CLIOutput.sanitize(name))")
        }
    }
}
