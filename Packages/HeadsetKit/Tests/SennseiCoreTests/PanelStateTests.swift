import Foundation
import HeadsetCore
import HeadsetSimulator
import Testing

@testable import SennseiCore

@MainActor private func connected(_ st: SimulatedState = .accentumProbed) async -> AppModel {
    let m = AppModel(makeTransport: { SimulatedHeadset(state: st) }, pollInterval: .seconds(3600), replyTimeout: .milliseconds(80))
    await m.start(); return m
}

@MainActor @Test func connectedPanelShowsStateAndEnablesControls() async {
    let m = await connected(); let p = PanelViewState(model: m, locale: Locale(identifier: "en"))
    #expect(p.batteryText == "20%"); #expect(p.noiseSelection == .anc); #expect(p.noiseEnabled); #expect(p.eqEnabled)
    #expect(p.eqNote == nil); #expect(p.errorText == nil); #expect(p.showReconnect == false)
    #expect(p.presets.contains("Rock")); await m.stop()
}

@MainActor @Test func notConnectedPanelDisablesEverythingAndOffersReconnect() async {
    let sim = SimulatedHeadset(); await sim.failSends(after: 0)
    let m = AppModel(makeTransport: { sim }, pollInterval: .seconds(3600), replyTimeout: .milliseconds(80)); await m.start()
    let p = PanelViewState(model: m, locale: Locale(identifier: "en"))
    #expect(p.noiseEnabled == false); #expect(p.eqEnabled == false); #expect(p.showReconnect); #expect(p.errorText != nil)
    #expect(MenuBarLabelState(model: m).connected == false)
}

@MainActor @Test func disconnectedPanelHasNoEqNoteAndNoBattery() async {
    let m = AppModel(makeTransport: { SimulatedHeadset() }, pollInterval: .seconds(3600), replyTimeout: .milliseconds(80))
    let p = PanelViewState(model: m, locale: Locale(identifier: "en"))   // idle: never started
    #expect(p.eqNote == nil); #expect(p.eqEnabled == false); #expect(p.noiseEnabled == false)
    #expect(p.batteryText == nil); #expect(p.subtitle == "Not connected"); #expect(p.showReconnect == false)
    let failing = SimulatedHeadset(); await failing.failSends(after: 0)
    let f = AppModel(makeTransport: { failing }, pollInterval: .seconds(3600), replyTimeout: .milliseconds(80)); await f.start()
    #expect(PanelViewState(model: f, locale: Locale(identifier: "en")).eqNote == nil)
}

@MainActor @Test func eqNoteExplainsWhyEqIsOff() async {
    var g2 = SimulatedState.accentumProbed; g2.firmware = FirmwareVersion(3, 34, 0)
    let m = await connected(g2); let p = PanelViewState(model: m, locale: Locale(identifier: "en"))
    #expect(p.eqEnabled == false); #expect(p.eqNote?.isEmpty == false); await m.stop()
}

@MainActor @Test func readOnlyModelDisablesNoiseAndEq() async {
    var m4 = SimulatedState.accentumProbed; m4.modelID = "M4AEBT Denim"
    let m = await connected(m4); let p = PanelViewState(model: m, locale: Locale(identifier: "tr"))
    #expect(p.noiseEnabled == false); #expect(p.eqEnabled == false); #expect(p.eqNote?.isEmpty == false); await m.stop()
}

@MainActor @Test func menuBarLabelShowsBatteryOnlyWhenKnown() async {
    let m = await connected(); #expect(MenuBarLabelState(model: m) == .init(batteryPercent: 20, connected: true)); await m.stop()
}

@MainActor @Test func busyDisablesEqAndQuitButNotWhenIdleOrFailed() async throws {
    let sim = SimulatedHeadset()
    let m = AppModel(makeTransport: { sim }, pollInterval: .seconds(3600), replyTimeout: .milliseconds(80))
    await m.start()
    let en = Locale(identifier: "en")
    #expect(PanelViewState(model: m, locale: en).quitEnabled); #expect(PanelViewState(model: m, locale: en).eqEnabled)
    await sim.setSilent([0x0603])   // the refresh takes ~160 ms, keeping the model busy
    let action = Task { await m.setNoiseMode(.transparency) }
    try await Task.sleep(for: .milliseconds(40))
    #expect(m.busy)
    let p = PanelViewState(model: m, locale: en)
    #expect(p.eqEnabled == false); #expect(p.noiseEnabled == false); #expect(p.quitEnabled == false)
    await action.value
    #expect(PanelViewState(model: m, locale: en).quitEnabled)
    await m.stop()
    #expect(PanelViewState(model: m, locale: en).quitEnabled)   // idle
}

@MainActor @Test func quitStaysEnabledWhenFailed() async {
    let sim = SimulatedHeadset(); await sim.failSends(after: 0)
    let m = AppModel(makeTransport: { sim }, pollInterval: .seconds(3600), replyTimeout: .milliseconds(80)); await m.start()
    #expect(PanelViewState(model: m, locale: Locale(identifier: "en")).quitEnabled)
}

@MainActor @Test func pauseToggleShowsTheValueAndIsEnabledWhenConnectedWritableAndKnown() async {
    var st = SimulatedState.accentumProbed; st.pauseInTransparency = false
    let m = await connected(st); let p = PanelViewState(model: m, locale: Locale(identifier: "en"))
    #expect(p.pauseInTransparency == false); #expect(p.pauseEnabled)
    await m.stop()
    let on = await connected(); let q = PanelViewState(model: on, locale: Locale(identifier: "en"))
    #expect(q.pauseInTransparency == true); #expect(q.pauseEnabled)
    await on.stop()
}

@MainActor @Test func pauseToggleIsDisabledWhenDisconnected() async {
    let idle = AppModel(makeTransport: { SimulatedHeadset() }, pollInterval: .seconds(3600), replyTimeout: .milliseconds(80))
    let p = PanelViewState(model: idle, locale: Locale(identifier: "en"))
    #expect(p.pauseEnabled == false); #expect(p.pauseInTransparency == nil)
    let sim = SimulatedHeadset(); await sim.failSends(after: 0)
    let f = AppModel(makeTransport: { sim }, pollInterval: .seconds(3600), replyTimeout: .milliseconds(80)); await f.start()
    let q = PanelViewState(model: f, locale: Locale(identifier: "en"))
    #expect(q.pauseEnabled == false); #expect(q.pauseInTransparency == nil)
}

@MainActor @Test func pauseToggleIsDisabledForAReadOnlyModel() async {
    var m4 = SimulatedState.accentumProbed; m4.modelID = "M4AEBT Denim"
    let m = await connected(m4); let p = PanelViewState(model: m, locale: Locale(identifier: "en"))
    #expect(p.pauseEnabled == false); await m.stop()
}

@MainActor @Test func pauseToggleIsDisabledWhileBusy() async throws {
    let sim = SimulatedHeadset()
    let m = AppModel(makeTransport: { sim }, pollInterval: .seconds(3600), replyTimeout: .milliseconds(80))
    await m.start()
    #expect(PanelViewState(model: m, locale: Locale(identifier: "en")).pauseEnabled)
    await sim.setSilent([0x0603])
    let action = Task { await m.setPauseInTransparency(false) }
    try await Task.sleep(for: .milliseconds(40))
    #expect(m.busy); #expect(PanelViewState(model: m, locale: Locale(identifier: "en")).pauseEnabled == false)
    await action.value
    await m.stop()
}

@MainActor @Test func pauseToggleIsDisabledWhenTheValueIsUnknown() async {
    let sim = SimulatedHeadset(); await sim.setSilent([0x1801])
    let m = AppModel(makeTransport: { sim }, pollInterval: .seconds(3600), replyTimeout: .milliseconds(80)); await m.start()
    let p = PanelViewState(model: m, locale: Locale(identifier: "en"))
    #expect(p.pauseInTransparency == nil); #expect(p.pauseEnabled == false)
    #expect(p.noiseEnabled)   // other controls are unaffected
    await m.stop()
}

// MARK: Scenes

@MainActor private func sceneModel(_ st: SimulatedState = .accentumProbed) -> AppModel {
    let suite = "sennsei-panel-\(UUID().uuidString)"
    return AppModel(
        makeTransport: { SimulatedHeadset(state: st) }, pollInterval: .seconds(3600), replyTimeout: .milliseconds(80),
        settings: UserDefaults(suiteName: suite)!)
}

@MainActor @Test func connectedPanelShowsThreeEnabledSceneBoxes() async {
    let m = sceneModel(); await m.start()
    let p = PanelViewState(model: m, locale: Locale(identifier: "en"))
    #expect(p.scenes.map(\.id) == ["focus", "meeting", "travel"])
    #expect(p.scenes.map(\.title) == ["Focus", "Meeting", "Travel"])
    #expect(p.scenes.map(\.subtitle) == ["ANC · Flat", "Transparency · pause off", "ANC · Rock"])
    #expect(p.scenes.allSatisfy { $0.enabled }); #expect(p.scenes.allSatisfy { !$0.selected })
    #expect(p.automaticScenes == false); #expect(p.automaticScenesEnabled); #expect(p.sceneNote == nil)
    await m.stop()
}

@MainActor @Test func appliedSceneIsSelected() async {
    let m = sceneModel(); await m.start()
    await m.applyScene("meeting")
    let p = PanelViewState(model: m, locale: Locale(identifier: "en"))
    #expect(p.scenes.first(where: \.selected)?.id == "meeting")
    #expect(p.scenes.filter(\.selected).count == 1)
    await m.stop()
}

@MainActor @Test func notConnectedPanelDisablesScenes() {
    let m = sceneModel()   // idle
    let p = PanelViewState(model: m, locale: Locale(identifier: "en"))
    #expect(p.scenes.count == 3); #expect(p.scenes.allSatisfy { !$0.enabled && !$0.selected })
    #expect(p.automaticScenesEnabled == false); #expect(p.sceneNote == nil)
}

@MainActor @Test func automaticSwitchReflectsTheModel() async {
    let m = sceneModel(); await m.start()
    m.setAutomaticScenes(true)
    #expect(PanelViewState(model: m, locale: Locale(identifier: "en")).automaticScenes)
    m.setAutomaticScenes(false)
    #expect(PanelViewState(model: m, locale: Locale(identifier: "en")).automaticScenes == false)
    await m.stop()
}

@MainActor @Test func readOnlyModelDisablesScenesAndExplains() async {
    var m4 = SimulatedState.accentumProbed; m4.modelID = "M4AEBT Denim"
    let m = sceneModel(m4); await m.start()
    let p = PanelViewState(model: m, locale: Locale(identifier: "en"))
    #expect(p.scenes.allSatisfy { !$0.enabled }); #expect(p.automaticScenesEnabled == false)
    #expect(p.sceneNote == Strings.text("error.readOnly", locale: Locale(identifier: "en")))
    await m.stop()
}

@MainActor @Test func busyDisablesScenes() async throws {
    let sim = SimulatedHeadset()
    let m = AppModel(
        makeTransport: { sim }, pollInterval: .seconds(3600), replyTimeout: .milliseconds(80),
        settings: UserDefaults(suiteName: "sennsei-panel-\(UUID().uuidString)")!)
    await m.start()
    await sim.setSilent([0x0603])
    let action = Task { await m.setNoiseMode(.transparency) }
    try await Task.sleep(for: .milliseconds(40))
    let p = PanelViewState(model: m, locale: Locale(identifier: "en"))
    #expect(p.scenes.allSatisfy { !$0.enabled }); #expect(p.automaticScenesEnabled == false)
    await action.value
    await m.stop()
}

@MainActor @Test func skippedEqualizerIsExplainedInTheRightLanguage() async {
    var g2 = SimulatedState.accentumProbed; g2.firmware = FirmwareVersion(3, 34, 0)
    let m = sceneModel(g2); await m.start()
    await m.applyScene("focus")   // sets ANC, then skips the unavailable equalizer
    #expect(m.sceneProgress?.key == "scene.eqSkipped")
    #expect(PanelViewState(model: m, locale: Locale(identifier: "en")).sceneNote == Strings.text("scene.eqSkipped", locale: Locale(identifier: "en")))
    #expect(PanelViewState(model: m, locale: Locale(identifier: "tr")).sceneNote == "Ekolayzır atlandı: şu an kullanılamıyor")
    await m.stop()
}

@MainActor @Test func sceneTitlesAreTurkishAndUserScenesKeepTheirName() {
    let tr = Locale(identifier: "tr"), en = Locale(identifier: "en")
    for scene in Scene.defaults { #expect(Strings.sceneTitle(scene, locale: tr) != Strings.sceneTitle(scene, locale: en)) }
    #expect(Strings.sceneTitle(Scene.meeting, locale: tr) == "Toplantı")
    let custom = Scene(id: "u1", name: "Gym", noiseMode: .off)
    #expect(Strings.sceneTitle(custom, locale: tr) == "Gym")
    #expect(Strings.sceneSubtitle(Scene.meeting, locale: tr) == "Şeffaf mod · duraklat kapalı")
}
