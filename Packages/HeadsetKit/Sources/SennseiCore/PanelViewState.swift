import Foundation
import HeadsetCore

/// One scene box in the panel.
public struct PanelScene: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let selected: Bool
    public let enabled: Bool
}

/// Everything the menu bar panel shows, derived from `AppModel` (no SwiftUI, so it is unit-tested).
public struct PanelViewState: Equatable, Sendable {
    public let title: String
    public let subtitle: String
    public let batteryText: String?
    public let noiseSelection: NoiseMode?
    public let noiseEnabled: Bool
    public let pauseInTransparency: Bool?
    public let pauseEnabled: Bool
    public let eqEnabled: Bool
    public let eqNote: String?
    public let presets: [String]
    public let selectedPreset: String?
    public let errorText: String?
    public let showReconnect: Bool
    public let quitEnabled: Bool
    public let scenes: [PanelScene]
    public let automaticScenes: Bool
    /// Whether the scene boxes and the automatic switch can be used: connected, writable and not busy.
    public let automaticScenesEnabled: Bool
    public let sceneNote: String?

    @MainActor
    public init(model: AppModel, locale: Locale) {
        let connected = model.phase == .connected
        title = AppInfo.name
        presets = EQPresetCatalog.presets.map(\.name)

        switch model.phase {
        case .connected: subtitle = Strings.text("status.connected", locale: locale)
        case .connecting: subtitle = Strings.text("status.connecting", locale: locale)
        case .idle, .failed: subtitle = Strings.text("status.notConnected", locale: locale)
        }

        var failure: UserMessage?
        var reconnect = false
        if case .failed(let message) = model.phase { failure = message; reconnect = true }
        errorText = (failure ?? model.lastError).map { Strings.message($0, locale: locale) }
        showReconnect = reconnect

        // Without a connection nothing is shown and nothing can be written.
        batteryText = connected ? model.state?.battery.map { "\($0)%" } : nil
        noiseSelection = connected ? model.state?.noiseMode : nil
        noiseEnabled = connected && (model.state?.profile.isWritable ?? false) && !model.busy
        pauseInTransparency = connected ? model.state?.pauseInTransparency : nil
        pauseEnabled = noiseEnabled && pauseInTransparency != nil
        eqEnabled = connected && model.eqAvailability == .available && !model.busy
        quitEnabled = !model.busy
        selectedPreset = connected ? model.selectedPreset : nil
        let note = connected ? Strings.eqAvailability(model.eqAvailability, locale: locale) : ""
        eqNote = note.isEmpty ? nil : note

        let writable = connected && (model.state?.profile.isWritable ?? false)
        let scenesUsable = writable && !model.busy
        scenes = model.scenes.map { scene in
            PanelScene(
                id: scene.id,
                title: Strings.sceneTitle(scene, locale: locale),
                subtitle: Strings.sceneSubtitle(scene, locale: locale),
                selected: connected && model.activeSceneID == scene.id,
                enabled: scenesUsable)
        }
        automaticScenes = model.automaticScenesEnabled
        automaticScenesEnabled = scenesUsable
        if connected && !writable {
            sceneNote = Strings.message(UserMessage(key: UserMessage.ErrorKey.readOnly), locale: locale)
        } else if connected, let progress = model.sceneProgress {
            sceneNote = Strings.message(progress, locale: locale)
        } else {
            sceneNote = nil
        }
    }
}

/// What the menu bar item shows: the battery percentage when known, and whether the link is up.
public struct MenuBarLabelState: Equatable, Sendable {
    public let batteryPercent: Int?
    public let connected: Bool

    public init(batteryPercent: Int?, connected: Bool) {
        self.batteryPercent = batteryPercent
        self.connected = connected
    }

    @MainActor
    public init(model: AppModel) {
        let connected = model.phase == .connected
        self.init(batteryPercent: connected ? model.state?.battery.map(Int.init) : nil, connected: connected)
    }
}
