import Testing
import HeadsetCore
@testable import SennseiCore

private func scene(_ id: String, noise: NoiseMode? = nil, pause: Bool? = nil, eq: String? = nil, app: String? = nil) -> Scene {
    Scene(id: id, name: id, noiseMode: noise, pauseInTransparency: pause, eqPreset: eq,
          triggers: app.map { [.frontApp(bundleID: $0)] } ?? [])
}

@Test func stepsFollowTheFixedOrderAndSkipNils() {
    #expect(SceneEngine.steps(for: scene("a", noise: .transparency, pause: false, eq: "Rock"))
            == [.pauseInTransparency(false), .noiseMode(.transparency), .eqPreset("Rock")])
    #expect(SceneEngine.steps(for: scene("b", noise: .anc)) == [.noiseMode(.anc)])
    #expect(SceneEngine.steps(for: scene("c")) == [])
}
@Test func matchPicksTheFirstSceneWithThatApp() {
    let scenes = [scene("one", app: "com.a"), scene("two", app: "com.b"), scene("three", app: "com.b")]
    #expect(SceneEngine.match(frontApp: "com.b", in: scenes)?.id == "two")
    #expect(SceneEngine.match(frontApp: "com.zzz", in: scenes) == nil)
    #expect(SceneEngine.match(frontApp: nil, in: scenes) == nil)
}
@Test func disabledNeverDecidesAnything() {
    let s = [scene("one", noise: .anc, app: "com.a")]
    #expect(SceneEngine.decide(state: .init(), frontApp: "com.a", scenes: s, enabled: false,
                               current: .init(noiseMode: .off)) == .nothing)
}
@Test func matchingAppAppliesOnceAndRemembersTheSnapshot() {
    let s = [scene("one", noise: .anc, app: "com.a")]
    let cur = SceneSnapshot(noiseMode: .off, pauseInTransparency: true, eqPreset: "Flat")
    let d = SceneEngine.decide(state: .init(), frontApp: "com.a", scenes: s, enabled: true, current: cur)
    #expect(d == .apply(s[0], snapshot: cur))
    var st = AutoSceneState(); st.activeID = "one"; st.snapshot = cur
    #expect(SceneEngine.decide(state: st, frontApp: "com.a", scenes: s, enabled: true, current: cur) == .nothing)
}
@Test func leavingTheAppRestoresOnlyWhatTheSceneTouched() {
    let applied = scene("one", noise: .anc, app: "com.a")
    let snap = SceneSnapshot(noiseMode: .off, pauseInTransparency: true, eqPreset: "Jazz")
    #expect(SceneEngine.restoreSteps(snapshot: snap, applied: applied) == [.noiseMode(.off)])
    var st = AutoSceneState(); st.activeID = "one"; st.snapshot = snap
    #expect(SceneEngine.decide(state: st, frontApp: "com.other", scenes: [applied], enabled: true,
                               current: .init(noiseMode: .anc)) == .restore(snap, applied: applied))
}
@Test func unknownSnapshotValuesProduceNoRestoreSteps() {
    let applied = scene("one", noise: .anc, pause: false, eq: "Rock", app: "com.a")
    #expect(SceneEngine.restoreSteps(snapshot: .init(), applied: applied) == [])
}
@Test func manualOverrideSuppressesAutoUntilTheAppChanges() {
    let s = [scene("one", noise: .anc, app: "com.a")]
    var st = AutoSceneState(); st.manualOverrideApp = "com.a"
    #expect(SceneEngine.decide(state: st, frontApp: "com.a", scenes: s, enabled: true, current: .init()) == .nothing)
    #expect(SceneEngine.decide(state: st, frontApp: "com.b", scenes: s, enabled: true, current: .init()) == .nothing)
}
