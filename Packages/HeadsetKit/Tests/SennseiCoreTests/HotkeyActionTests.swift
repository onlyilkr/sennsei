import Foundation
import RemoteProtocol
import Testing
@testable import SennseiCore

@Suite struct HotkeyActionTests {
    private static let en = Locale(identifier: "en"), tr = Locale(identifier: "tr")

    @Test func commandMapping() {
        let table: [(HotkeyAction, RemoteCommand)] = [
            (.cycleNoise, .noise(.next)),
            (.nextEQ, .eq(.next)),
            (.scene("focus"), .scene("focus")),
            (.scene("my-scene"), .scene("my-scene")),
        ]
        for (action, command) in table { #expect(action.command == command) }
    }

    @Test func nameKeys() {
        #expect(HotkeyAction.cycleNoise.nameKey == "hotkey.noiseCycle")
        #expect(HotkeyAction.nextEQ.nameKey == "hotkey.eqNext")
        #expect(HotkeyAction.scene("focus").nameKey == "scene.focus")
    }

    @Test func builtInSceneUsesLocalizedTitle() {
        #expect(HotkeyAction.scene("focus").displayName(scenes: Scene.defaults, locale: Self.tr) == "Odak")
        #expect(HotkeyAction.scene("focus").displayName(scenes: [], locale: Self.en) == "Focus")
    }

    @Test func userSceneUsesItsNameAndUnknownFallsBackToId() {
        let mine = Scene(id: "u1", name: "Gym")
        #expect(HotkeyAction.scene("u1").displayName(scenes: Scene.defaults + [mine], locale: Self.en) == "Gym")
        #expect(HotkeyAction.scene("u2").displayName(scenes: Scene.defaults + [mine], locale: Self.en) == "u2")
        // A user scene whose id collides with a non-scene catalog key still shows its own name.
        let clash = Scene(id: "title", name: "Mine")
        #expect(HotkeyAction.scene("title").displayName(scenes: [clash], locale: Self.en) == "Mine")
    }

    @Test func fixedActionsAreLocalized() {
        #expect(HotkeyAction.cycleNoise.displayName(scenes: [], locale: Self.en) != "hotkey.noiseCycle")
        #expect(HotkeyAction.nextEQ.displayName(scenes: [], locale: Self.tr) != HotkeyAction.nextEQ.displayName(scenes: [], locale: Self.en))
    }

    @Test func newStringsAreRegistered() {
        for key in ["hotkey.title", "hotkey.noiseCycle", "hotkey.eqNext", "hotkey.hint", "panel.shortcuts"] {
            #expect(Strings.allKeys.contains(key), "\(key)")
            #expect(Strings.text(key, locale: Self.tr) != Strings.text(key, locale: Self.en), "\(key)")
        }
        #expect(Strings.text("hotkey.hint", locale: Self.en) == "Global shortcuts work in any app. No shortcut is set by default.")
        #expect(Strings.text("panel.shortcuts", locale: Self.en) == "Shortcuts…")
    }
}
