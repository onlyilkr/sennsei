import AppIntents
import Foundation
import RemoteProtocol
import SennseiCore

/// Hands the one `AppModel` to App Intents. Intents are created by the system, so they cannot take
/// the model as an initializer argument; `SennseiApp.init` sets this once, on the main actor.
@MainActor
enum IntentModelProvider {
    static var model: AppModel?

    /// The single path every intent uses: `AppModel.run` through a `RemoteCommand`.
    /// From a cold launch the model exists before Bluetooth has connected, so wait (suspended, main
    /// actor free) up to 8 s for `.connected`; if it never does, `run` answers notConnected and nothing is sent.
    static func run(_ command: RemoteCommand) async throws -> RemoteResponse {
        _ = await waitUntil(timeout: .seconds(5)) { model != nil }
        guard let model else { throw IntentError.appNotReady }
        _ = await waitUntil(timeout: .seconds(8)) { model.phase == .connected }
        try Task.checkCancellation()
        try Task.checkCancellation()
        let response = await model.run(command)
        guard response.ok else { throw IntentError.failed(response.error?.message ?? "Request failed") }
        return response
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case batteryUnknown
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady: return "intent.error.notReady"
        case .batteryUnknown: return "intent.error.batteryUnknown"
        case .failed(let message): return "\(message)"
        }
    }
}

enum NoiseControlOption: String, AppEnum {
    case anc, transparency, off

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "intent.noise.type")
    static let caseDisplayRepresentations: [NoiseControlOption: DisplayRepresentation] = [
        .anc: "intent.noise.anc",
        .transparency: "intent.noise.transparency",
        .off: "intent.noise.off",
    ]
}

struct ApplySceneIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.applyScene.title"
    static let description = IntentDescription("intent.applyScene.description")
    static let openAppWhenRun = true

    @Parameter(title: "intent.scene.parameter", description: "intent.scene.parameter.description")
    var scene: String


    /// Returns the model's warning (for example "equalizer skipped"), or an empty string.
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let response = try await IntentModelProvider.run(.scene(scene))
        return .result(value: response.warning ?? "")
    }
}

struct SetNoiseControlIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.noiseControl.title"
    static let description = IntentDescription("intent.noiseControl.description")
    static let openAppWhenRun = true

    @Parameter(title: "intent.noise.parameter")
    var mode: NoiseControlOption


    @MainActor func perform() async throws -> some IntentResult {
        _ = try await IntentModelProvider.run(.noise(.mode(mode.rawValue)))
        return .result()
    }
}

struct SetEqualizerPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.equalizer.title"
    static let description = IntentDescription("intent.equalizer.description")
    static let openAppWhenRun = true

    @Parameter(title: "intent.preset.parameter", description: "intent.preset.parameter.description")
    var preset: String


    @MainActor func perform() async throws -> some IntentResult {
        _ = try await IntentModelProvider.run(.eq(.preset(preset)))
        return .result()
    }
}

struct GetBatteryLevelIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.battery.title"
    static let description = IntentDescription("intent.battery.description")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let response = try await IntentModelProvider.run(.status)
        guard let battery = response.status?.battery else { throw IntentError.batteryUnknown }
        return .result(value: battery)
    }
}
