import Foundation
import HeadsetCore
import RemoteProtocol

extension AppModel {
    /// Routes a remote command to the existing user actions; there is no separate write path.
    public func run(_ command: RemoteCommand) async -> RemoteResponse {
        switch command {
        case .status, .ping:
            return RemoteResponse(ok: true, status: remoteStatus())
        default:
            break
        }
        guard phase == .connected, state != nil else { return fail(.notConnected, UserMessage.ErrorKey.notConnected) }
        guard state?.profile.isWritable == true else { return fail(.readOnly, UserMessage.ErrorKey.readOnly) }

        switch command {
        case .noise(let target):
            switch target {
            case .mode(let name):
                guard let mode = NoiseMode(rawValue: name.lowercased()) else { return badRequest("unknown noise mode") }
                return finished(await setNoiseModeOutcome(mode))
            case .next:
                return finished(await cycleNoiseMode())
            }
        case .pause(let pause):
            return finished(await setPauseOutcome(pause))
        case .eq(let target):
            switch target {
            case .preset(let requested):
                guard let preset = EQPresetCatalog.presets.first(where: { $0.name.lowercased() == requested.lowercased() })
                else { return plain(.unknownPreset, "Unknown equalizer preset") }
                return finished(await applyPresetOutcome(preset.name))
            case .next:
                return finished(await cycleEQPreset())
            }
        case .scene(let id):
            guard let scene = scenes.first(where: { $0.id.lowercased() == id.lowercased() }) else {
                return plain(.unknownScene, "Unknown scene")
            }
            return finished(await applySceneOutcome(scene.id), sceneWarning: true)
        case .automaticScenes(let on):
            setAutomaticScenes(on)   // synchronous and cannot fail; independent of any earlier error
            return RemoteResponse(ok: true, status: remoteStatus())
        case .status, .ping:
            return RemoteResponse(ok: true, status: remoteStatus())
        }
    }

    public func remoteStatus() -> RemoteStatus {
        let connected = phase == .connected && state != nil
        return RemoteStatus(
            connected: connected,
            battery: state?.battery.map(Int.init),
            noise: state?.noiseMode?.rawValue,
            pauseInTransparency: state?.pauseInTransparency,
            eqPreset: selectedPreset,
            activeScene: activeSceneID,
            automaticScenes: automaticScenesEnabled,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
    }

    private func finished(_ result: ActionResult, sceneWarning: Bool = false) -> RemoteResponse {
        let status = remoteStatus()
        let en = Locale(identifier: "en")
        func failure(_ code: RemoteErrorCode, _ message: String) -> RemoteResponse {
            RemoteResponse(ok: false, status: status, error: RemoteError(code: code, message: message))
        }
        switch result.refusal {
        case .stateUnknown?: return failure(.stateUnknown, "The current noise mode is not known yet")
        case .eqUnavailable(let availability)?: return failure(.eqUnavailable, Strings.eqAvailability(availability, locale: en))
        case nil: break
        }
        if result.connectionLost || !status.connected {
            return failure(.notConnected, Strings.text(UserMessage.ErrorKey.notConnected, locale: en))
        }
        if let error = result.error { return failure(.failed, Strings.message(error, locale: en)) }
        let warning = sceneWarning ? result.progress.map { Strings.message($0, locale: en) } : nil
        return RemoteResponse(ok: true, status: status, warning: warning)
    }

    private func fail(_ code: RemoteErrorCode, _ key: String) -> RemoteResponse {
        RemoteResponse(
            ok: false, status: remoteStatus(),
            error: RemoteError(code: code, message: Strings.text(key, locale: Locale(identifier: "en"))))
    }

    private func plain(_ code: RemoteErrorCode, _ message: String) -> RemoteResponse {
        RemoteResponse(ok: false, status: remoteStatus(), error: RemoteError(code: code, message: message))
    }

    private func badRequest(_ message: String) -> RemoteResponse {
        RemoteResponse(ok: false, status: remoteStatus(), error: RemoteError(code: .badRequest, message: message))
    }
}
