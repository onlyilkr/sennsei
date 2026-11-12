import Foundation

/// Localized texts from the String Catalog, resolved for an explicit `Locale` (no SwiftUI).
public enum Strings {
    /// SwiftPM-generated name of this target's resource bundle; the app build script must copy
    /// `*_SennseiCore.bundle` (glob; really `HeadsetKit_SennseiCore.bundle`) into `Contents/Resources`
    /// (Tools/app/build_app.sh), because `Bundle.module` only finds build-machine paths.
    static let resourceBundleName = "HeadsetKit_SennseiCore"

    /// Looks for the resource bundle in `Contents/Resources`, then next to the app bundle. This function
    /// itself never touches `Bundle.module`; the caller's `?? Bundle.module` fallback does (its generated
    /// accessor fatalErrors outside the build machine).
    static func findBundle(in app: Bundle) -> Bundle? {
        let file = resourceBundleName + ".bundle"
        let candidates = [app.resourceURL, app.bundleURL].compactMap { $0?.appending(path: file) }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }

    private static let supported = ["en", "tr"]

    private static let sharedCatalog = Catalog(bundle: findBundle(in: .main) ?? Bundle.module) // module: development/tests only

    /// Parsed `Localizable.xcstrings` (SwiftPM copies it uncompiled, so the JSON is read directly).
    struct Catalog: Sendable {
        let strings: [String: [String: String]]
        init(bundle: Bundle) {
            guard let url = bundle.url(forResource: "Localizable", withExtension: "xcstrings"),
                  let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = root["strings"] as? [String: Any] else { strings = [:]; return }
            var result: [String: [String: String]] = [:]
            for (key, entry) in raw {
                guard let loc = (entry as? [String: Any])?["localizations"] as? [String: Any] else { continue }
                var per: [String: String] = [:]
                for (language, body) in loc {
                    if let unit = (body as? [String: Any])?["stringUnit"] as? [String: Any],
                       let value = unit["value"] as? String { per[language] = value }
                }
                result[key] = per
            }
            strings = result
        }
        func text(_ key: String, locale: Locale) -> String {
            let requested = locale.language.languageCode?.identifier ?? "en"
            let language = Strings.supported.contains(requested) ? requested : "en"
            return strings[key]?[language] ?? strings[key]?["en"] ?? key
        }
    }

    /// Resolves `key` for a single `locale` (not a preference list); unsupported languages fall back to English.
    public static func text(_ key: String, locale: Locale) -> String {
        sharedCatalog.text(key, locale: locale)
    }

    // By design `message` ignores `UserMessage.argument` and `needsFirmwareUpdate` ignores `minimum`.
    public static func message(_ m: UserMessage, locale: Locale) -> String {
        text(m.key, locale: locale)
    }

    public static func eqAvailability(_ a: EQAvailability, locale: Locale) -> String {
        switch a {
        case .available: return ""
        case .needsFirmwareUpdate: return text("eq.unavailable.firmware", locale: locale)
        case .audioModeNotEqualizer: return text("eq.unavailable.audioMode", locale: locale)
        case .readOnlyModel: return text("eq.unavailable.readOnly", locale: locale)
        case .unsupportedGeneration: return text("eq.unavailable.generation", locale: locale)
        }
    }

    /// Built-in scenes are titled from `scene.<id>`; user scenes show their own `name`.
    public static func sceneTitle(_ scene: Scene, locale: Locale) -> String {
        Scene.defaults.contains { $0.id == scene.id } ? text("scene.\(scene.id)", locale: locale) : scene.name
    }

    /// A short summary of what a scene sets, for example "ANC · Flat" or "Transparency · pause off".
    public static func sceneSubtitle(_ scene: Scene, locale: Locale) -> String {
        var parts: [String] = []
        if let mode = scene.noiseMode {
            switch mode {
            case .anc: parts.append(text("noise.anc", locale: locale))
            case .transparency: parts.append(text("noise.transparency", locale: locale))
            case .off: parts.append(text("noise.off", locale: locale))
            }
        }
        if let pause = scene.pauseInTransparency { parts.append(text(pause ? "scene.pause.on" : "scene.pause.off", locale: locale)) }
        if let preset = scene.eqPreset { parts.append(text("eq.preset.\(preset)", locale: locale)) }
        return parts.joined(separator: " · ")
    }

    public static let allKeys: [String] = UserMessage.ErrorKey.all + [
        "app.name",
        "status.connected",
        "status.connecting",
        "status.notConnected",
        "status.battery",
        "noise.title",
        "noise.anc",
        "noise.transparency",
        "noise.off",
        "noise.pauseInTransparency",
        "eq.title",
        "eq.edit",
        "eq.preset.Flat",
        "eq.preset.Rock",
        "eq.preset.Pop",
        "eq.preset.Dance",
        "eq.preset.Hip-Hop",
        "eq.preset.Classical",
        "eq.preset.Movie",
        "eq.preset.Jazz",
        "eq.bass",
        "eq.unavailable.firmware",
        "eq.unavailable.audioMode",
        "eq.unavailable.readOnly",
        "eq.unavailable.generation",
        "action.reconnect",
        "action.quit",
        "firmware.update.hint",
        "scene.title",
        "scene.focus",
        "scene.meeting",
        "scene.travel",
        "scene.automatic",
        "scene.automatic.hint",
        "scene.eqSkipped",
        "scene.failed",
        "scene.pause.on",
        "scene.pause.off",
        "hotkey.title",
        "hotkey.noiseCycle",
        "hotkey.eqNext",
        "hotkey.hint",
        "panel.shortcuts",
        "insights.title",
        "insights.range.today",
        "insights.range.week",
        "insights.range.month",
        "insights.listening",
        "insights.calls",
        "insights.perApp",
        "insights.other",
        "insights.noiseShare",
        "insights.dailyHours",
        "insights.battery",
        "insights.recording",
        "insights.recording.hint",
        "insights.exclude",
        "insights.excluded",
        "insights.remove",
        "insights.deleteHistory",
        "insights.deleteConfirm",
        "insights.deleteFailed",
        "insights.cancel",
        "insights.export",
        "insights.exportFailed",
        "insights.empty",
        "insights.unsupported",
        "insights.degraded",
        "panel.insights",
        "insights.app.webkit",
        "insights.app.systemSounds",
        "insights.unit.minute",
        "insights.unit.hour",
        "insights.day",
        "insights.time",
        "insights.recording.toggle",
        "insights.a11y.daily",
        "insights.a11y.battery",
        "intent.applyScene.title",
        "intent.applyScene.description",
        "intent.scene.parameter",
        "intent.scene.parameter.description",
        "intent.noiseControl.title",
        "intent.noiseControl.description",
        "intent.noise.parameter",
        "intent.noise.type",
        "intent.noise.anc",
        "intent.noise.transparency",
        "intent.noise.off",
        "intent.equalizer.title",
        "intent.equalizer.description",
        "intent.preset.parameter",
        "intent.preset.parameter.description",
        "intent.battery.title",
        "intent.battery.description",
        "intent.error.notReady",
        "intent.error.batteryUnknown",
    ]
}
