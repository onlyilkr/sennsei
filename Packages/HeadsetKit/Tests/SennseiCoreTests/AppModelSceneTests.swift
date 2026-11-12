import Foundation
import GaiaProtocol
import HeadsetCore
import HeadsetSimulator
import Testing

@testable import SennseiCore

/// Every access to `changes` returns a fresh stream (the protocol contract); `yield` reaches all of them.
private final class FakeMonitor: FrontAppMonitor, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<String?>.Continuation] = []
    var changes: AsyncStream<String?> {
        let (stream, continuation) = AsyncStream<String?>.makeStream()
        lock.lock(); continuations.append(continuation); lock.unlock()
        return stream
    }
    func yield(_ app: String?) {
        lock.lock(); let all = continuations; lock.unlock()
        for c in all { c.yield(app) }
    }
}

/// Forwards to a simulator but delays every send, to hold an action in flight.
private struct SlowSend: HeadsetTransport {
    let inner: SimulatedHeadset
    var incoming: AsyncStream<Data> { inner.incoming }
    func open() async throws { try await inner.open() }
    func close() async { await inner.close() }
    func send(_ data: Data) async throws { try await Task.sleep(for: .milliseconds(25)); try await inner.send(data) }
}

private let writeCommands: Set<UInt16> = [0x1804, 0x1A04, 0x1800, 0x0803, 0x1002, 0x1006, 0x1004]

private let sceneA = Scene(id: "a", name: "A", noiseMode: .transparency, triggers: [.frontApp(bundleID: "com.a")])
private let sceneB = Scene(id: "b", name: "B", noiseMode: .off, triggers: [.frontApp(bundleID: "com.b")])
private let sceneC = Scene(id: "c", name: "C", noiseMode: .transparency, pauseInTransparency: false, eqPreset: "Rock")

private func freshSettings() -> UserDefaults {
    let name = "sennsei.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor private func model(
    _ sim: SimulatedHeadset, monitor: FakeMonitor, scenes: [Scene], settings: UserDefaults = freshSettings()
) -> AppModel {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sennsei-\(UUID().uuidString).json")
    let store = SceneStore(url: url)
    try? store.save(scenes)
    return AppModel(
        makeTransport: { sim }, pollInterval: .seconds(3600), replyTimeout: .milliseconds(80),
        sceneStore: store, frontAppMonitor: monitor, sceneDebounce: .milliseconds(30), settings: settings)
}

@MainActor private func linkDropModel(_ sim: SimulatedHeadset, monitor: FakeMonitor, scenes: [Scene]) -> AppModel {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sennsei-\(UUID().uuidString).json")
    let store = SceneStore(url: url); try? store.save(scenes)
    return AppModel(
        makeTransport: { DropAfterFirstWrite(inner: sim) }, pollInterval: .seconds(3600),
        replyTimeout: .milliseconds(60), sceneStore: store, frontAppMonitor: monitor,
        sceneDebounce: .milliseconds(30), settings: freshSettings())
}

private func writes(_ sim: SimulatedHeadset, after count: Int = 0) async -> [UInt16] {
    await sim.sent.dropFirst(count).map(\.command).filter { writeCommands.contains($0) }
}

/// Polls until `condition` holds (up to 3 s), then lets in-flight work settle briefly.
@MainActor private func waitUntil(_ condition: @MainActor () async -> Bool) async {
    for _ in 0..<300 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor @Test func manualApplyRunsStepsInOrderAndMarksTheScene() async {
    let sim = SimulatedHeadset(); let m = model(sim, monitor: FakeMonitor(), scenes: [sceneC])
    await m.start()
    let before = await sim.sent.count
    await m.applyScene("c")
    // pause (1800) first, then the noise switch (1804), then the equalizer (1002, 1006, 1004).
    #expect(await writes(sim, after: before) == [0x1800, 0x1804, 0x1002, 0x1006, 0x1004])
    #expect(m.activeSceneID == "c"); #expect(m.lastError == nil); #expect(m.sceneProgress == nil)
    #expect(m.state?.pauseInTransparency == false); #expect(m.state?.noiseMode == .transparency)
    #expect(m.selectedPreset == "Rock")
    await m.stop()
}

@MainActor @Test func manualApplyOnADisconnectedModelSendsNothing() async {
    let sim = SimulatedHeadset(); let m = model(sim, monitor: FakeMonitor(), scenes: [sceneC])
    await m.applyScene("c")
    #expect(m.lastError?.key == "error.notConnected"); #expect(m.activeSceneID == nil)
    #expect(await sim.sent.isEmpty)
}

@MainActor @Test func manualApplyOnAReadOnlyModelSendsNothing() async {
    var st = SimulatedState.accentumProbed; st.modelID = "M4AEBT Denim"
    let sim = SimulatedHeadset(state: st); let m = model(sim, monitor: FakeMonitor(), scenes: [sceneC])
    await m.start()
    let before = await sim.sent.count
    await m.applyScene("c")
    #expect(m.lastError?.key == "error.readOnly"); #expect(m.activeSceneID == nil)
    #expect(await sim.sent.count == before)
    await m.stop()
}

@MainActor @Test func aFailingStepStopsTheRest() async {
    let sim = SimulatedHeadset(); await sim.setIgnoreWrites([0x1804])
    let m = model(sim, monitor: FakeMonitor(), scenes: [sceneC]); await m.start()
    let before = await sim.sent.count
    await m.applyScene("c")
    // The pause write goes out, the noise write is not confirmed (read-back mismatch), EQ is never sent.
    #expect(await writes(sim, after: before) == [0x1800, 0x1804])
    #expect(m.lastError?.key == "error.readBack"); #expect(m.activeSceneID == nil)
    await m.stop()
}

@MainActor @Test func eqStepIsSkippedAndExplainedWhenUnavailable() async {
    var st = SimulatedState.accentumProbed; st.audioMode = 3
    let sim = SimulatedHeadset(state: st); let m = model(sim, monitor: FakeMonitor(), scenes: [sceneC])
    await m.start()
    let before = await sim.sent.count
    await m.applyScene("c")
    #expect(await writes(sim, after: before) == [0x1800, 0x1804])
    #expect(m.sceneProgress == UserMessage(key: "scene.eqSkipped")); #expect(m.lastError == nil)
    #expect(m.activeSceneID == "c"); #expect(m.state?.noiseMode == .transparency)
    await m.stop()
}

@MainActor @Test func automaticScenesAreOffByDefaultAndWriteNothing() async throws {
    let sim = SimulatedHeadset(); let monitor = FakeMonitor()
    let m = model(sim, monitor: monitor, scenes: [sceneA])
    #expect(m.automaticScenesEnabled == false)
    await m.start()
    let before = await sim.sent.count
    monitor.yield("com.a")
    try await Task.sleep(for: .milliseconds(300))
    #expect(await sim.sent.count == before)   // not even a read
    #expect(m.activeSceneID == nil)
    await m.stop()
}

@MainActor @Test func theAutomaticSettingPersists() {
    let settings = freshSettings()
    let m = model(SimulatedHeadset(), monitor: FakeMonitor(), scenes: [sceneA], settings: settings)
    m.setAutomaticScenes(true)
    #expect(model(SimulatedHeadset(), monitor: FakeMonitor(), scenes: [sceneA], settings: settings).automaticScenesEnabled)
    m.setAutomaticScenes(false)
    #expect(!model(SimulatedHeadset(), monitor: FakeMonitor(), scenes: [sceneA], settings: settings).automaticScenesEnabled)
}

@MainActor @Test func enablingAutomaticScenesAppliesTheMatchingSceneOnce() async throws {
    let sim = SimulatedHeadset(); let monitor = FakeMonitor()
    let m = model(sim, monitor: monitor, scenes: [sceneA]); await m.start()
    m.setAutomaticScenes(true)
    let before = await sim.sent.count
    monitor.yield("com.a"); monitor.yield("com.a")
    await waitUntil { m.activeSceneID == "a" }
    try await Task.sleep(for: .milliseconds(200))
    #expect(await writes(sim, after: before) == [0x1804])
    #expect(m.state?.noiseMode == .transparency); #expect(m.activeSceneID == "a")
    await m.stop()
}

@MainActor @Test func leavingTheAppRestoresThePreviousNoiseMode() async throws {
    let sim = SimulatedHeadset(); let monitor = FakeMonitor()
    let m = model(sim, monitor: monitor, scenes: [sceneA]); await m.start()
    m.setAutomaticScenes(true)
    let before = await sim.sent.count
    monitor.yield("com.a")
    await waitUntil { m.state?.noiseMode == .transparency }
    monitor.yield("com.other")
    await waitUntil { m.activeSceneID == nil }
    try await Task.sleep(for: .milliseconds(100))
    // Transparency on (1804), then back to the ANC the headset had before (transparency off: 1804).
    #expect(await writes(sim, after: before) == [0x1804, 0x1804])
    #expect(m.state?.noiseMode == .anc); #expect(m.activeSceneID == nil)
    await m.stop()
}

@MainActor @Test func switchingBetweenAutoScenesKeepsTheOriginalSnapshot() async throws {
    let sim = SimulatedHeadset(); let monitor = FakeMonitor()
    let m = model(sim, monitor: monitor, scenes: [sceneA, sceneB]); await m.start()
    m.setAutomaticScenes(true)
    monitor.yield("com.a")
    await waitUntil { m.activeSceneID == "a" }
    monitor.yield("com.b")
    await waitUntil { m.activeSceneID == "b" }
    #expect(m.state?.noiseMode == .off)
    monitor.yield("com.other")
    await waitUntil { m.activeSceneID == nil }
    try await Task.sleep(for: .milliseconds(100))
    // Back to ANC (the mode before A), not to A's Transparency.
    #expect(m.state?.noiseMode == .anc); #expect(m.activeSceneID == nil)
    await m.stop()
}

@MainActor @Test func aSceneThatDisappearedIsForgottenAndNothingIsRestored() async throws {
    let sim = SimulatedHeadset(); let monitor = FakeMonitor()
    let m = model(sim, monitor: monitor, scenes: [sceneA]); await m.start()
    m.setAutomaticScenes(true)
    monitor.yield("com.a")
    await waitUntil { m.activeSceneID == "a" }
    m.scenes = []
    let before = await sim.sent.count
    monitor.yield("com.other")
    await waitUntil { m.activeSceneID == nil }
    try await Task.sleep(for: .milliseconds(100))
    #expect(m.activeSceneID == nil); #expect(await writes(sim, after: before).isEmpty)
    #expect(m.state?.noiseMode == .transparency)
    await m.stop()
}

@MainActor @Test func manualSelectionOverridesAutoUntilTheAppChanges() async throws {
    let sim = SimulatedHeadset(); let monitor = FakeMonitor()
    let manual = Scene(id: "m", name: "M", noiseMode: .off)
    let m = model(sim, monitor: monitor, scenes: [sceneA, manual]); await m.start()
    m.setAutomaticScenes(true)
    monitor.yield("com.a")
    await waitUntil { m.activeSceneID == "a" }
    await m.applyScene("m")
    #expect(m.activeSceneID == "m"); #expect(m.state?.noiseMode == .off)
    let before = await sim.sent.count
    monitor.yield("com.a")                       // same app again: the manual choice stands
    try await Task.sleep(for: .milliseconds(200))
    #expect(await writes(sim, after: before).isEmpty); #expect(m.state?.noiseMode == .off)
    monitor.yield("com.other")                   // leaving does not restore either (snapshot dropped)
    try await Task.sleep(for: .milliseconds(200))
    #expect(await writes(sim, after: before).isEmpty); #expect(m.state?.noiseMode == .off)
    monitor.yield("com.a")                       // after an app change the trigger works again
    await waitUntil { m.activeSceneID == "a" }
    #expect(m.state?.noiseMode == .transparency)
    await m.stop()
}

@MainActor @Test func aManualNoiseChangeDropsTheAutoSnapshot() async throws {
    let sim = SimulatedHeadset(); let monitor = FakeMonitor()
    let m = model(sim, monitor: monitor, scenes: [sceneA]); await m.start()
    m.setAutomaticScenes(true)
    monitor.yield("com.a")
    await waitUntil { m.activeSceneID == "a" }
    await m.setNoiseMode(.off)
    let before = await sim.sent.count
    monitor.yield("com.other")
    try await Task.sleep(for: .milliseconds(200))
    #expect(await writes(sim, after: before).isEmpty); #expect(m.state?.noiseMode == .off)
    await m.stop()
}

@MainActor @Test func stopCancelsMonitoring() async throws {
    let sim = SimulatedHeadset(); let monitor = FakeMonitor()
    let m = model(sim, monitor: monitor, scenes: [sceneA]); await m.start()
    m.setAutomaticScenes(true)
    await m.stop()
    let before = await sim.sent.count
    monitor.yield("com.a")
    try await Task.sleep(for: .milliseconds(200))
    #expect(await sim.sent.count == before); #expect(m.activeSceneID == nil)
}

/// After the first write the headset goes silent on the status reads: the session's link-dead rule fires.
private struct DropAfterFirstWrite: HeadsetTransport {
    let inner: SimulatedHeadset
    var incoming: AsyncStream<Data> { inner.incoming }
    func open() async throws { try await inner.open() }
    func close() async { await inner.close() }
    func send(_ data: Data) async throws {
        try await inner.send(data)
        if let last = await inner.sent.last?.command, writeCommands.contains(last) {
            await inner.setSilent([0x0603, 0x0602, 0x0800])
        }
    }
}

@MainActor @Test func aManualActionDuringAnAutoApplyLeavesNothingToRestore() async throws {
    let sim = SimulatedHeadset(); let monitor = FakeMonitor()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sennsei-\(UUID().uuidString).json")
    let store = SceneStore(url: url); try store.save([sceneA])
    let m = AppModel(
        makeTransport: { SlowSend(inner: sim) }, pollInterval: .seconds(3600), replyTimeout: .milliseconds(500),
        sceneStore: store, frontAppMonitor: monitor, sceneDebounce: .milliseconds(30), settings: freshSettings())
    await m.start()
    m.setAutomaticScenes(true)
    let before = await sim.sent.count
    monitor.yield("com.a")
    await waitUntil { await writes(sim, after: before) == [0x1804] }   // the scene's write is out, its read-back runs
    await m.setNoiseMode(.off)                           // queued behind it; takes effect afterwards
    try await Task.sleep(for: .milliseconds(100))
    monitor.yield("com.other")
    try await Task.sleep(for: .milliseconds(400))
    // Auto: transparency on (1804). Manual Off: transparency off (1804), ANC off (1A04). Nothing on leaving.
    #expect(await writes(sim, after: before) == [0x1804, 0x1804, 0x1A04])
    #expect(m.state?.noiseMode == .off); #expect(m.activeSceneID == nil)
    await m.stop()
}

@MainActor @Test func aManualActionQueuedBeforeADecisionBeatsIt() async throws {
    let sim = SimulatedHeadset(); let monitor = FakeMonitor()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sennsei-\(UUID().uuidString).json")
    let store = SceneStore(url: url); try store.save([sceneA])
    let m = AppModel(
        makeTransport: { SlowSend(inner: sim) }, pollInterval: .seconds(3600), replyTimeout: .milliseconds(500),
        sceneStore: store, frontAppMonitor: monitor, sceneDebounce: .milliseconds(30), settings: freshSettings())
    await m.start()
    m.setAutomaticScenes(true)
    let before = await sim.sent.count
    // A long manual action holds the lock while the debounced decision fires and queues behind it,
    // then a second manual action is requested after the decision started.
    let first = Task { await m.setPauseInTransparency(false) }
    await Task.yield()
    monitor.yield("com.a")
    try await Task.sleep(for: .milliseconds(60))          // decision fired, waiting for the lock
    let second = Task { await m.setNoiseMode(.off) }
    _ = await (first.value, second.value)
    try await Task.sleep(for: .milliseconds(500))
    #expect(await writes(sim, after: before) == [0x1800, 0x1A04])   // pause off, ANC off; the auto scene wrote nothing
    #expect(m.state?.noiseMode == .off); #expect(m.activeSceneID == nil)
    await m.stop()
}

@MainActor @Test func aLinkDropMidSceneShowsTheErrorAndLeavesNothingBehind() async throws {
    let sim = SimulatedHeadset(); let monitor = FakeMonitor()
    let m = linkDropModel(sim, monitor: monitor, scenes: [sceneA, sceneC])
    await m.start()
    // The link drops right after the first write of the manual scene (the read-back dies).
    m.setAutomaticScenes(true)
    let before = await sim.sent.count
    await m.applyScene("c")
    #expect(m.lastError != nil); #expect(m.state == nil)
    #expect(m.phase == .failed(UserMessage(key: UserMessage.ErrorKey.link)))
    #expect(m.activeSceneID == nil)                      // not "c": a dead link never counts as applied
    #expect(await writes(sim, after: before) == [0x1800])   // only the first step went out
    let after = await sim.sent.count
    monitor.yield("com.other")
    try await Task.sleep(for: .milliseconds(200))
    #expect(await sim.sent.count == after)               // no restore, no retry on the dead link
    #expect(m.activeSceneID == nil)
    await m.stop()
}

@MainActor @Test func aLinkDropDuringAnAutoApplyLeavesNoSnapshot() async throws {
    let sim = SimulatedHeadset(); let monitor = FakeMonitor()
    let m = model(sim, monitor: monitor, scenes: [sceneA]); await m.start()
    m.setAutomaticScenes(true)
    await sim.setSilent([0x0603, 0x0602, 0x0800])        // the link dies before the decision's refresh
    monitor.yield("com.a")
    await waitUntil { m.phase != .connected }
    #expect(m.phase == .failed(UserMessage(key: UserMessage.ErrorKey.link))); #expect(m.state == nil)
    #expect(m.activeSceneID == nil); #expect(m.lastError != nil)
    let after = await sim.sent.count
    monitor.yield("com.other")
    try await Task.sleep(for: .milliseconds(200))
    #expect(await sim.sent.count == after)
    await m.stop()
}

@MainActor @Test func aRefusedManualApplyChangesNoAutoBookkeeping() async throws {
    let sim = SimulatedHeadset(); let monitor = FakeMonitor()
    let m = model(sim, monitor: monitor, scenes: [sceneA, sceneC])
    await m.applyScene("c")                              // not connected: refused
    #expect(m.lastError?.key == "error.notConnected")
    await m.start()
    m.setAutomaticScenes(true)
    monitor.yield("com.a")
    await waitUntil { m.activeSceneID == "a" }
    m.setAutomaticScenes(false)
    #expect(m.activeSceneID == nil)                      // turning auto off forgets the auto state
    await m.stop()
}

private let sceneR = Scene(id: "r", name: "R", eqPreset: "Rock", triggers: [.frontApp(bundleID: "com.r")])

@MainActor private func slowModel(
    _ sim: SimulatedHeadset, monitor: FakeMonitor, scenes: [Scene], debounce: Duration = .milliseconds(30)
) throws -> AppModel {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sennsei-\(UUID().uuidString).json")
    let store = SceneStore(url: url); try store.save(scenes)
    return AppModel(
        makeTransport: { SlowSend(inner: sim) }, pollInterval: .seconds(3600), replyTimeout: .milliseconds(500),
        sceneStore: store, frontAppMonitor: monitor, sceneDebounce: debounce, settings: freshSettings())
}

@MainActor @Test func switchingAutomaticScenesOffMidApplyWritesNoMoreAndKeepsNoState() async throws {
    let sim = SimulatedHeadset(); let monitor = FakeMonitor()
    let m = try slowModel(sim, monitor: monitor, scenes: [sceneA]); await m.start()
    m.setAutomaticScenes(true)
    let before = await sim.sent.count
    monitor.yield("com.a")
    await waitUntil { await writes(sim, after: before) == [0x1804] }   // the write is out, bookkeeping pending
    m.setAutomaticScenes(false)
    try await Task.sleep(for: .milliseconds(500))
    #expect(await writes(sim, after: before) == [0x1804])   // the running step finished, nothing else
    #expect(m.activeSceneID == nil)
    monitor.yield("com.other")                              // no snapshot survived: nothing is restored
    try await Task.sleep(for: .milliseconds(300))
    #expect(await writes(sim, after: before) == [0x1804])
    await m.stop()
}

@MainActor @Test func switchingAutomaticScenesOffWhileADecisionIsQueuedWritesNothing() async throws {
    let sim = SimulatedHeadset(); let monitor = FakeMonitor()
    let m = try slowModel(sim, monitor: monitor, scenes: [sceneA]); await m.start()
    m.setAutomaticScenes(true)
    let before = await sim.sent.count
    let held = Task { await m.setPauseInTransparency(false) }   // holds the action lock
    await Task.yield()
    monitor.yield("com.a")
    try await Task.sleep(for: .milliseconds(60))                // the decision fired and queues behind it
    m.setAutomaticScenes(false)
    await held.value
    try await Task.sleep(for: .milliseconds(300))
    #expect(await writes(sim, after: before) == [0x1800])
    #expect(m.activeSceneID == nil); #expect(m.state?.noiseMode == .anc)
    await m.stop()
}

@MainActor @Test func aManualChangeInTheTriggerAppIsFollowedByAReapplyAfterLeavingAndReturning() async throws {
    let sim = SimulatedHeadset(); let monitor = FakeMonitor()
    let m = model(sim, monitor: monitor, scenes: [sceneR]); await m.start()
    m.setAutomaticScenes(true)
    let eq: [UInt16] = [0x1002, 0x1006, 0x1004]
    let before = await sim.sent.count
    monitor.yield("com.r")
    await waitUntil { m.selectedPreset == "Rock" }
    await m.applyPreset("Flat")                          // manual change inside the trigger app
    #expect(m.selectedPreset == "Flat")
    monitor.yield("com.other")                           // leaving restores nothing (manual choice stands)
    try await Task.sleep(for: .milliseconds(200))
    #expect(await writes(sim, after: before) == eq + eq)
    #expect(m.selectedPreset == "Flat")
    monitor.yield("com.r")                               // returning applies the scene again
    await waitUntil { m.selectedPreset == "Rock" }
    try await Task.sleep(for: .milliseconds(100))
    #expect(await writes(sim, after: before) == eq + eq + eq)   // Rock, Flat (manual), Rock again
    #expect(m.activeSceneID == "r")
    await m.stop()
}

@MainActor @Test func aManualNoiseChangeInTheTriggerAppIsReappliedOnReturn() async throws {
    let sim = SimulatedHeadset(); let monitor = FakeMonitor()
    let m = model(sim, monitor: monitor, scenes: [sceneA]); await m.start()
    m.setAutomaticScenes(true)
    let before = await sim.sent.count
    monitor.yield("com.a")
    await waitUntil { m.state?.noiseMode == .transparency }
    await m.setNoiseMode(.off)
    monitor.yield("com.other")
    try await Task.sleep(for: .milliseconds(200))
    monitor.yield("com.a")
    await waitUntil { m.state?.noiseMode == .transparency }
    try await Task.sleep(for: .milliseconds(100))
    // auto: transparency on; manual Off: transparency off + ANC off; return: transparency on again.
    #expect(await writes(sim, after: before) == [0x1804, 0x1804, 0x1A04, 0x1804])
    await m.stop()
}

@MainActor @Test func aManualChangeDuringTheDebounceWindowWinsOverTheFrontAppChange() async throws {
    let sim = SimulatedHeadset(); let monitor = FakeMonitor()
    let m = try slowModel(sim, monitor: monitor, scenes: [sceneA], debounce: .milliseconds(250)); await m.start()
    m.setAutomaticScenes(true)
    let before = await sim.sent.count
    monitor.yield("com.a")
    try await Task.sleep(for: .milliseconds(60))         // received, still debouncing
    await m.setNoiseMode(.off)                           // manual: ANC off (1A04)
    try await Task.sleep(for: .milliseconds(500))
    #expect(await writes(sim, after: before) == [0x1A04])   // the auto scene wrote nothing
    #expect(m.state?.noiseMode == .off); #expect(m.activeSceneID == nil)
    await m.stop()
}

@MainActor @Test func anAppSwitchWithNoMatchAndNoActiveSceneSendsNothing() async throws {
    let sim = SimulatedHeadset(); let monitor = FakeMonitor()
    let m = model(sim, monitor: monitor, scenes: [sceneA]); await m.start()
    m.setAutomaticScenes(true)
    let before = await sim.sent.count
    monitor.yield("com.nothing"); monitor.yield("com.nothing2")
    try await Task.sleep(for: .milliseconds(300))
    #expect(await sim.sent.count == before)              // not even read frames
    await m.stop()
}
