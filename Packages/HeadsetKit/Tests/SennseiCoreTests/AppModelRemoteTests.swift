import Foundation
import HeadsetCore
import HeadsetSimulator
import RemoteProtocol
import Testing

@testable import SennseiCore

private let writeCommands: Set<UInt16> = [0x1804, 0x1A04, 0x1800, 0x0803, 0x1002, 0x1006, 0x1004]

private func freshSettings() -> UserDefaults {
    let name = "sennsei.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor private func model(_ sim: SimulatedHeadset) -> AppModel {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sennsei-\(UUID().uuidString).json")
    let store = SceneStore(url: url)
    try? store.save([Scene(id: "c", name: "C", noiseMode: .transparency, pauseInTransparency: false, eqPreset: "Rock")])
    return AppModel(
        makeTransport: { sim }, pollInterval: .seconds(3600), replyTimeout: .milliseconds(80),
        sceneStore: store, frontAppMonitor: nil, sceneDebounce: .milliseconds(30), settings: freshSettings())
}

private func writes(_ sim: SimulatedHeadset, after count: Int = 0) async -> [UInt16] {
    await sim.sent.dropFirst(count).map(\.command).filter { writeCommands.contains($0) }
}

@MainActor @Test func notConnectedRefusesWritesButStatusWorks() async {
    let sim = SimulatedHeadset(); let m = model(sim)
    let r = await m.run(.noise(.mode("anc")))
    #expect(r.ok == false); #expect(r.error?.code == .notConnected)
    #expect(await sim.sent.isEmpty)
    let s = await m.run(.status)
    #expect(s.ok); #expect(s.status?.connected == false)
    #expect(await m.run(.ping).ok)
    #expect(await sim.sent.isEmpty)
}

@MainActor @Test func readOnlyModelRefusesWrites() async {
    var st = SimulatedState.accentumProbed; st.modelID = "M4AEBT Denim"
    let sim = SimulatedHeadset(state: st); let m = model(sim)
    await m.start()
    let before = await sim.sent.count
    let r = await m.run(.noise(.mode("off")))
    #expect(r.error?.code == .readOnly)
    #expect(await sim.sent.count == before)
    #expect(await m.run(.status).status?.connected == true)
    await m.stop()
}

@MainActor @Test func noiseNextCyclesFromAncToTransparency() async {
    let sim = SimulatedHeadset(); let m = model(sim)
    await m.start()
    let before = await sim.sent.count
    let r = await m.run(.noise(.next))
    #expect(r.ok); #expect(r.status?.noise == "transparency")
    #expect(await writes(sim, after: before) == [0x1804])
    let r2 = await m.run(.noise(.next))
    #expect(r2.status?.noise == "off")
    #expect(await writes(sim, after: before) == [0x1804, 0x1804, 0x1A04])
    let r3 = await m.run(.noise(.next))
    #expect(r3.status?.noise == "anc")
    #expect(await writes(sim, after: before) == [0x1804, 0x1804, 0x1A04, 0x1A04])
    await m.stop()
}

@MainActor @Test func noiseNextWithUnknownModeIsStateUnknown() async {
    let sim = SimulatedHeadset(); await sim.setSilent([0x1A05])   // the ANC switch never answers
    let m = model(sim)
    await m.start()
    #expect(m.state?.noiseMode == nil)
    let before = await sim.sent.count
    let r = await m.run(.noise(.next))
    #expect(r.error?.code == .stateUnknown)
    #expect(await writes(sim, after: before).isEmpty)   // only the read-only refresh went out
    await m.stop()
}

@MainActor @Test func eqNextFromACustomEqualizerWritesTheFirstPreset() async {
    var st = SimulatedState.accentumProbed
    // Not a catalog preset: nudge one band parameter away from flat.
    let key = st.eq1Params.keys.sorted().first!
    st.eq1Params[key] = (st.eq1Params[key] ?? 0) &+ 400
    let sim = SimulatedHeadset(state: st); let m = model(sim)
    await m.start()
    #expect(m.selectedPreset == nil)
    let before = await sim.sent.count
    let r = await m.run(.eq(.next))
    #expect(r.ok, "\(String(describing: r.error))")
    #expect(r.status?.eqPreset == "Rock")
    #expect(await writes(sim, after: before) == [0x1002, 0x1006, 0x1004])
    // Fresh status (7 reads), fresh equalizer read (4 reads), the three writes, then the read-back.
    let all = await sim.sent.dropFirst(before).map(\.command)
    #expect(all == [
        0x603, 0x602, 0x800, 0x1a05, 0x1805, 0x804, 0x1801, 0x1007, 0x1005, 0x1003, 0x1003,
        0x1002, 0x1006, 0x1004, 0x1007, 0x1005, 0x1003, 0x1003,
    ])
    let r2 = await m.run(.eq(.next))
    #expect(r2.status?.eqPreset == "Pop")
    await m.stop()
}

@MainActor @Test func eqIsUnavailableOutsideTheEqualizerAudioMode() async {
    var st = SimulatedState.accentumProbed; st.audioMode = 3
    let sim = SimulatedHeadset(state: st); let m = model(sim)
    await m.start()
    let before = await sim.sent.count
    let r = await m.run(.eq(.next))
    #expect(r.error?.code == .eqUnavailable)
    #expect(await writes(sim, after: before).isEmpty)
    await m.stop()
}

@MainActor @Test func unknownPresetAndSceneWriteNothing() async {
    let sim = SimulatedHeadset(); let m = model(sim)
    await m.start()
    let before = await sim.sent.count
    #expect(await m.run(.eq(.preset("Nope"))).error?.code == .unknownPreset)
    #expect(await m.run(.scene("nope")).error?.code == .unknownScene)
    #expect(await sim.sent.count == before)
    await m.stop()
}

@MainActor @Test func namedPresetIsCaseInsensitiveAndReturnsCatalogSpelling() async {
    let sim = SimulatedHeadset(); let m = model(sim)
    await m.start()
    let r = await m.run(.eq(.preset("hip-hop")))
    #expect(r.ok); #expect(r.status?.eqPreset == "Hip-Hop")
    await m.stop()
}

@MainActor @Test func sceneWithSkippedEqualizerWarns() async {
    var st = SimulatedState.accentumProbed; st.audioMode = 3
    let sim = SimulatedHeadset(state: st); let m = model(sim)
    await m.start()
    let r = await m.run(.scene("c"))
    #expect(r.ok); #expect(r.warning != nil); #expect(r.status?.activeScene == "c")
    #expect(r.status?.noise == "transparency")
    // Pause (1800) then the noise switch (1804); the equalizer step is skipped (no 1002/1006/1004).
    #expect(await writes(sim) == [0x1800, 0x1804])
    await m.stop()
}

@MainActor @Test func failedActionReportsFailed() async {
    let sim = SimulatedHeadset(); await sim.setIgnoreWrites([0x1804])
    let m = model(sim); await m.start()
    let r = await m.run(.noise(.mode("transparency")))
    #expect(r.ok == false); #expect(r.error?.code == .failed); #expect(r.error?.message.isEmpty == false)
    await m.stop()
}

@MainActor @Test func pauseAndAutoRouteToExistingActions() async {
    let sim = SimulatedHeadset(); let m = model(sim)
    await m.start()
    let before = await sim.sent.count
    let r = await m.run(.pause(false))
    #expect(r.ok); #expect(r.status?.pauseInTransparency == false)
    #expect(await writes(sim, after: before) == [0x1800])
    let a = await m.run(.automaticScenes(true))
    #expect(a.ok); #expect(a.status?.automaticScenes == true)
    await m.stop()
}

@MainActor @Test func remoteStatusMatchesState() async {
    let sim = SimulatedHeadset(); let m = model(sim)
    await m.start()
    let s = m.remoteStatus()
    #expect(s.connected); #expect(s.battery == m.state?.battery.map(Int.init))
    #expect(s.noise == m.state?.noiseMode?.rawValue)
    #expect(s.pauseInTransparency == m.state?.pauseInTransparency)
    #expect(s.eqPreset == m.selectedPreset); #expect(s.activeScene == m.activeSceneID)
    #expect(s.automaticScenes == m.automaticScenesEnabled)
    await m.stop()
}

@MainActor @Test func noiseNextUsesTheHeadsetsFreshModeNotThePolledOne() async {
    let sim = SimulatedHeadset(); let m = model(sim)
    await m.start()
    #expect(m.state?.noiseMode == .anc)
    // The user presses the headphone button: transparency, behind the app's back.
    await sim.update { $0.ancEnabled = false; $0.transparencyEnabled = true }
    let before = await sim.sent.count
    let r = await m.run(.noise(.next))
    #expect(r.ok); #expect(r.status?.noise == "off")
    #expect(await sim.state.ancEnabled == false); #expect(await sim.state.transparencyEnabled == false)
    #expect(await writes(sim, after: before) == [0x1804])
    await m.stop()
}

@MainActor @Test func eqNextUsesTheHeadsetsFreshEqualizer() async {
    let sim = SimulatedHeadset(); let m = model(sim)
    await m.start()
    _ = await m.run(.eq(.preset("Pop")))
    #expect(m.selectedPreset == "Pop")
    // Changed behind the app's back (Jazz); the app still thinks Pop.
    let jazz = try! EQGen1.encode(.accentum, gains: EQPresetCatalog.presets.first { $0.name == "Jazz" }!.gains, bassBoost: false)
    await sim.update { st in
        let w = jazz.params
        st.eq1Params = [:]
        for i in 0..<Int(w[0]) { st.eq1Params[w[1 + 2 * i]] = w[2 + 2 * i] }
        st.eq1LevelShiftX10 = jazz.levelShiftX10
        st.eq1KnobY = jazz.knobY
    }
    let r = await m.run(.eq(.next))
    #expect(r.ok, "\(String(describing: r.error))")
    #expect(r.status?.eqPreset == "Flat")   // the successor of Jazz, not of Pop
    await m.stop()
}

@MainActor @Test func eqUnavailableIsDetectedFromAFreshAudioMode() async {
    let sim = SimulatedHeadset(); let m = model(sim)
    await m.start()
    await sim.update { $0.audioMode = 3 }   // changed behind the app's back
    let before = await sim.sent.count
    #expect(await m.run(.eq(.preset("Rock"))).error?.code == .eqUnavailable)
    #expect(await m.run(.eq(.next)).error?.code == .eqUnavailable)
    #expect(await writes(sim, after: before).isEmpty)
    await m.stop()
}

@MainActor @Test func automaticScenesIgnoreAnEarlierFailure() async {
    let sim = SimulatedHeadset(); await sim.setIgnoreWrites([0x1804])
    let m = model(sim); await m.start()
    #expect(await m.run(.noise(.mode("transparency"))).ok == false)
    #expect(m.lastError != nil)
    let a = await m.run(.automaticScenes(true))
    #expect(a.ok); #expect(a.error == nil)
    await m.stop()
}

@MainActor @Test func concurrentRunsEachReportTheirOwnOutcome() async {
    let sim = SimulatedHeadset(); await sim.setIgnoreWrites([0x1800])   // pause writes are never confirmed
    let m = model(sim); await m.start()
    async let failing = m.run(.pause(false))
    async let succeeding = m.run(.noise(.mode("transparency")))
    let (f, s) = await (failing, succeeding)
    #expect(f.ok == false); #expect(f.error?.code == .failed)
    #expect(s.ok); #expect(s.error == nil); #expect(s.status?.noise == "transparency")
    await m.stop()
}

/// After the first write the headset goes silent on the status reads, so the session's link-dead rule fires.
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

@MainActor @Test func aLinkLostDuringAnActionIsANotConnectedFailure() async {
    let sim = SimulatedHeadset()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sennsei-\(UUID().uuidString).json")
    let m = AppModel(
        makeTransport: { DropAfterFirstWrite(inner: sim) }, pollInterval: .seconds(3600),
        replyTimeout: .milliseconds(60), sceneStore: SceneStore(url: url), frontAppMonitor: nil,
        sceneDebounce: .milliseconds(30), settings: freshSettings())
    await m.start()
    #expect(await m.run(.noise(.mode("transparency"))).ok)   // the write itself goes through; the link then goes silent
    let r = await m.run(.noise(.mode("off")))   // its status read finds the link dead
    #expect(r.ok == false)
    #expect(r.error?.code == .notConnected)
    #expect(r.status?.connected == false)
    await m.stop()
}

private final class OneShotMonitor: FrontAppMonitor, @unchecked Sendable {
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

@MainActor @Test func aRefusedCycleChangesNothingAboutTheAutoScene() async throws {
    let sim = SimulatedHeadset(); let monitor = OneShotMonitor()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sennsei-\(UUID().uuidString).json")
    let store = SceneStore(url: url)
    try? store.save([Scene(id: "a", name: "A", noiseMode: .transparency, triggers: [.frontApp(bundleID: "com.a")])])
    let m = AppModel(
        makeTransport: { sim }, pollInterval: .seconds(3600), replyTimeout: .milliseconds(80),
        sceneStore: store, frontAppMonitor: monitor, sceneDebounce: .milliseconds(30), settings: freshSettings())
    await m.start()
    m.setAutomaticScenes(true)
    monitor.yield("com.a")
    for _ in 0..<300 where m.activeSceneID != "a" { try await Task.sleep(for: .milliseconds(10)) }
    #expect(m.activeSceneID == "a")
    await sim.update { $0.audioMode = 3 }   // the equalizer is no longer available
    let before = await sim.sent.count
    #expect(await m.run(.eq(.next)).error?.code == .eqUnavailable)
    #expect(await writes(sim, after: before).isEmpty)
    #expect(m.activeSceneID == "a")   // untouched
    // The snapshot survived too: leaving the app restores the ANC the headset had before.
    monitor.yield("com.other")
    for _ in 0..<300 where m.activeSceneID != nil { try await Task.sleep(for: .milliseconds(10)) }
    try await Task.sleep(for: .milliseconds(100))
    #expect(m.activeSceneID == nil); #expect(m.state?.noiseMode == .anc)
    await m.stop()
}
