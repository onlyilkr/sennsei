import Foundation

/// The only things a remote client may ask for. There is deliberately no raw-command case.
public enum RemoteCommand: Equatable, Sendable {
    case noise(NoiseTarget)
    case pause(Bool)
    case eq(EQTarget)
    case scene(String)
    case automaticScenes(Bool)
    case status
    case ping
}

public enum NoiseTarget: Equatable, Sendable {
    /// "anc", "transparency" or "off" (lowercased).
    case mode(String)
    case next
}

public enum EQTarget: Equatable, Sendable {
    case preset(String)
    case next
}

public enum RemoteErrorCode: String, Codable, Sendable {
    case notConnected, readOnly, unknownScene, unknownPreset, stateUnknown, eqUnavailable, failed, badRequest
}

public struct RemoteError: Error, Codable, Equatable, Sendable {
    public var code: RemoteErrorCode
    public var message: String
    public init(code: RemoteErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public struct RemoteStatus: Codable, Equatable, Sendable {
    public var connected: Bool
    public var battery: Int?
    public var noise: String?
    public var pauseInTransparency: Bool?
    public var eqPreset: String?
    public var activeScene: String?
    public var automaticScenes: Bool
    public var appVersion: String
    public init(
        connected: Bool, battery: Int? = nil, noise: String? = nil, pauseInTransparency: Bool? = nil,
        eqPreset: String? = nil, activeScene: String? = nil, automaticScenes: Bool, appVersion: String
    ) {
        self.connected = connected
        self.battery = battery
        self.noise = noise
        self.pauseInTransparency = pauseInTransparency
        self.eqPreset = eqPreset
        self.activeScene = activeScene
        self.automaticScenes = automaticScenes
        self.appVersion = appVersion
    }
}

public struct RemoteResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var status: RemoteStatus?
    public var error: RemoteError?
    public var warning: String?
    public init(ok: Bool, status: RemoteStatus? = nil, error: RemoteError? = nil, warning: String? = nil) {
        self.ok = ok
        self.status = status
        self.error = error
        self.warning = warning
    }
}

public struct RemoteRequest: Codable, Equatable, Sendable {
    public var cmd: String
    public var arg: String?
    public init(cmd: String, arg: String? = nil) {
        self.cmd = cmd
        self.arg = arg
    }

    public var parsed: Result<RemoteCommand, RemoteError> { Self.parse(self) }

    public static func parse(_ request: RemoteRequest) -> Result<RemoteCommand, RemoteError> {
        func bad(_ message: String) -> Result<RemoteCommand, RemoteError> {
            .failure(RemoteError(code: .badRequest, message: message))
        }
        let arg = request.arg?.trimmingCharacters(in: .whitespaces)
        let lower = arg?.lowercased()
        func toggle(_ build: (Bool) -> RemoteCommand) -> Result<RemoteCommand, RemoteError> {
            switch lower {
            case "on": return .success(build(true))
            case "off": return .success(build(false))
            default: return bad("expected on or off")
            }
        }
        switch request.cmd.lowercased() {
        case "noise":
            guard let lower else { return bad("noise needs anc, transparency, off or next") }
            if lower == "next" { return .success(.noise(.next)) }
            guard ["anc", "transparency", "off"].contains(lower) else { return bad("unknown noise mode") }
            return .success(.noise(.mode(lower)))
        case "pause": return toggle { .pause($0) }
        case "auto": return toggle { .automaticScenes($0) }
        case "eq":
            guard let arg, !arg.isEmpty else { return bad("eq needs a preset name or next") }
            return .success(.eq(lower == "next" ? .next : .preset(arg)))
        case "scene":
            guard let arg, !arg.isEmpty else { return bad("scene needs an id") }
            return .success(.scene(arg))
        case "status": return .success(.status)
        case "ping": return .success(.ping)
        default: return bad("unknown command")
        }
    }
}
