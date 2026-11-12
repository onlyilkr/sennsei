import Foundation
import KeyboardShortcuts
import SennseiCore

/// Registers the global shortcuts and forwards each press to `AppModel.run`, the same entry point
/// the command line client uses. No shortcut is assigned by default; the user records them in the
/// Shortcuts window. Carbon based, so no accessibility permission is needed.
@MainActor
final class HotkeyCenter {
    private let model: AppModel
    private var registeredScenes: Set<String> = []
    /// Set synchronously in `fire`, because `model.busy` only flips once the run Task has started.
    private var inFlight = false

    init(model: AppModel) {
        self.model = model
        register(.cycleNoise)
        register(.nextEQ)
        syncSceneHandlers()
    }

    static func name(for action: HotkeyAction) -> KeyboardShortcuts.Name {
        switch action {
        case .cycleNoise: KeyboardShortcuts.Name("sennsei.noiseCycle")
        case .nextEQ: KeyboardShortcuts.Name("sennsei.eqNext")
        case .scene(let id): KeyboardShortcuts.Name("sennsei.scene.\(id)")
        }
    }

    private func register(_ action: HotkeyAction) {
        KeyboardShortcuts.onKeyDown(for: Self.name(for: action)) { [weak self] in
            Task { @MainActor in self?.fire(action) }
        }
    }

    /// A press while an action is running is dropped, never queued: a held or repeated key must
    /// not stack up headset writes.
    private func fire(_ action: HotkeyAction) {
        guard !inFlight, !model.busy else { return }
        if case .scene(let id) = action, !model.scenes.contains(where: { $0.id == id }) { return }
        let command = action.command
        let model = model
        inFlight = true
        Task { [weak self] in
            _ = await model.run(command)
            self?.inFlight = false
        }
    }

    /// Scenes are user editable, so handlers follow `model.scenes`; the observation re-arms itself.
    private func syncSceneHandlers() {
        let ids = withObservationTracking {
            model.scenes.map(\.id)
        } onChange: { [weak self] in
            Task { @MainActor in self?.syncSceneHandlers() }
        }
        for id in ids where !registeredScenes.contains(id) {
            registeredScenes.insert(id)
            register(.scene(id))
        }
    }
}
