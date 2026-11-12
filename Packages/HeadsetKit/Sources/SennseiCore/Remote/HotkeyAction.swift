import Foundation
import RemoteProtocol

/// What a global keyboard shortcut can trigger. Each maps onto an existing remote command, so a
/// shortcut takes exactly the same path (and the same checks) as the command line client.
public enum HotkeyAction: Equatable, Sendable {
    case cycleNoise
    case nextEQ
    case scene(String)
}

public extension HotkeyAction {
    var command: RemoteCommand {
        switch self {
        case .cycleNoise: .noise(.next)
        case .nextEQ: .eq(.next)
        case .scene(let id): .scene(id)
        }
    }

    /// The localization key naming this action. For a scene it is `scene.<id>`, which only exists
    /// for the built-in scenes; use `displayName(scenes:locale:)` to get text that always resolves.
    var nameKey: String {
        switch self {
        case .cycleNoise: "hotkey.noiseCycle"
        case .nextEQ: "hotkey.eqNext"
        case .scene(let id): "scene.\(id)"
        }
    }

    /// Built-in scenes use their localized title, user scenes their own `name`, and an id that is
    /// no longer in `scenes` is shown as is.
    func displayName(scenes: [Scene], locale: Locale) -> String {
        guard case .scene(let id) = self else { return Strings.text(nameKey, locale: locale) }
        if Scene.defaults.contains(where: { $0.id == id }) { return Strings.text(nameKey, locale: locale) }
        return scenes.first { $0.id == id }?.name ?? id
    }
}
