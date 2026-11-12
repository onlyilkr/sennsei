import Foundation
import Testing
import HeadsetCore
import HeadsetSimulator
@testable import SennseiCore

// MARK: - Fakes

private final class FakeSource: AudioActivitySource, @unchecked Sendable {
    private let lock = NSLock()
    private var _processes: [ProcessActivity] = []
    private var _calls = 0
    var processes: [ProcessActivity] {
        get { lock.withLock { _processes } }
        set { lock.withLock { _processes = newValue } }
    }
    var callCount: Int { lock.withLock { _calls } }
    func snapshot() async -> [ProcessActivity] { lock.withLock { _calls += 1; return _processes } }
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { _now } }
    func advance(_ s: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(s) } }
    func set(_ d: Date) { lock.withLock { _now = d } }
}

/// A sleep that suspends until the test releases it (and returns early when cancelled). Releases made while
/// nobody sleeps are banked and consumed by the next sleep.
private final class SleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _sleeps = 0
    private var banked = 0
    private var waiters: [(id: Int, cont: CheckedContinuation<Void, Never>)] = []
    private var nextID = 0
    var sleeps: Int { lock.withLock { _sleeps } }
    func release() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty { banked += 1; return nil }
            return waiters.removeFirst().cont
        }
        waiter?.resume()
    }
    func sleep() async {
        let id: Int = lock.withLock { _sleeps += 1; nextID += 1; return nextID }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    if Task.isCancelled { return true }   // cancelled before registering: the handler saw no waiter
                    if banked > 0 { banked -= 1; return true }
                    waiters.append((id, c)); return false
                }
                if resumeNow { c.resume() }
            }
        } onCancel: {
            let c: CheckedContinuation<Void, Never>? = lock.withLock {
                guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: idx).cont
            }
            c?.resume()
        }
    }
}

private final class BlockingSource: AudioActivitySource, @unchecked Sendable {
    let inSource: Box<Bool>, gate: SleepGate
    init(inSource: Box<Bool>, gate: SleepGate) { self.inSource = inSource; self.gate = gate }
    func snapshot() async -> [ProcessActivity] { inSource.set(true); await gate.sleep(); return [] }
}

private final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.withLock { value } }
    func set(_ v: T) { lock.withLock { value = v } }
}

private func activity(_ id: String, name: String? = nil, call: Bool = false) -> ProcessActivity {
    ProcessActivity(bundleID: id, appName: name, outputRunning: true, inputRunning: call, route: .bluetooth)
}

private func waitFor(_ what: String = "condition", timeout: TimeInterval = 5, _ cond: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await cond()) {
        if Date() > deadline { Issue.record("timed out waiting for \(what)"); return }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

private let wide = DateInterval(start: Date(timeIntervalSince1970: 1_700_000_000), end: Date(timeIntervalSince1970: 1_900_000_000))

@MainActor private final class Fixture {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("insights-svc-\(UUID().uuidString)", isDirectory: true)
    var url: URL { dir.appendingPathComponent("db/insights.sqlite") }
    let suite = "insights-svc-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    let source = FakeSource()
    let clock = FakeClock()
    let gate = SleepGate()
    let headset = Box(HeadsetInsightsSnapshot(connected: true, noiseMode: .anc, battery: 80, charging: false))
    let store: InsightsStore

    init() { store = InsightsStore(url: dir.appendingPathComponent("db/insights.sqlite")) }
    deinit {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    func service(store override: InsightsStore? = nil) -> InsightsService {
        let h = headset, c = clock, g = gate
        return InsightsService(
            store: override ?? store, source: source, headset: { h.get() }, settings: defaults,
            tick: .seconds(5), sleep: { _ in await g.sleep() }, now: { c.now })
    }

    /// One manual tick, then advance the fake clock by one tick.
    func tick(_ s: InsightsService, advance: TimeInterval = 5) async { await s.tick(); clock.advance(advance) }
    func reader() -> InsightsStore { InsightsStore(url: url) }
}

// MARK: - Tests

@MainActor @Suite struct InsightsServiceTests {
    @Test func recordingIsOnByDefaultAndPersists() {
        let f = Fixture()
        let a = f.service()
        #expect(a.isRecording)
        a.setRecording(false)
        let b = f.service()
        #expect(!b.isRecording)
        #expect(f.defaults.object(forKey: "sennsei.insights.recording") as? Bool == false)
    }

    @Test func whileRecordingIsOffNothingIsSampledAndNoFileExists() async {
        let f = Fixture()
        f.defaults.set(false, forKey: "sennsei.insights.recording")
        f.source.processes = [activity("a")]
        let s = f.service()
        s.start()
        await s.tick()          // even a stray tick must not sample while off
        await s.stop()
        await s.deleteHistory() // maintenance with no file is a no-op, but must not create one
        #expect(f.source.callCount == 0)
        #expect(f.gate.sleeps == 0)
        #expect(!FileManager.default.fileExists(atPath: f.dir.path))
    }

    @Test func tickProducesIntervalsThatReachTheStore() async throws {
        let f = Fixture()
        let s = f.service()
        f.source.processes = [activity("chrome", name: "Chrome")]
        await f.tick(s); await f.tick(s); await f.tick(s)
        f.source.processes = []
        await f.tick(s)                       // gap not yet over mergeGap
        await f.tick(s); await f.tick(s)      // closes the interval
        let apps = try await f.reader().perApp(wide)
        #expect(apps.count == 1)
        #expect(apps.first?.app == "chrome")
        #expect(apps.first?.listening == 15)
        #expect(!s.degraded)
        #expect(f.source.callCount == 6)
    }

    @Test func turningRecordingOffFlushesOpenIntervals() async throws {
        let f = Fixture()
        let s = f.service()
        s.start()
        await waitFor("first sleep") { f.gate.sleeps == 1 }
        f.source.processes = [activity("music")]
        f.gate.release(); f.clock.advance(5)
        await waitFor("second sleep") { f.gate.sleeps == 2 }
        f.gate.release(); f.clock.advance(5)
        await waitFor("third sleep") { f.gate.sleeps == 3 }
        let calls = f.source.callCount
        s.setRecording(false)
        await s.waitForIdle()
        #expect(!s.isRecording)
        let apps = try await f.reader().perApp(wide)
        #expect(apps.first?.app == "music")
        #expect(apps.first?.listening ?? 0 > 0)
        f.gate.release()
        await s.stop()
        #expect(f.source.callCount == calls)   // never sampled after switching off
    }

    @Test func turningRecordingBackOnRestartsTheLoop() async {
        let f = Fixture()
        f.defaults.set(false, forKey: "sennsei.insights.recording")
        let s = f.service()
        s.start()
        #expect(f.source.callCount == 0)
        s.setRecording(true)
        await waitFor("sampling") { f.source.callCount >= 1 && f.gate.sleeps >= 1 }
        #expect(s.isRecording)
        await s.stop()
    }

    @Test func aFailingStoreMarksDegradedKeepsRunningAndRecovers() async throws {
        let f = Fixture()
        // A regular file where the store wants a directory makes every append fail.
        try FileManager.default.createDirectory(at: f.dir, withIntermediateDirectories: true)
        let blocker = f.dir.appendingPathComponent("db")
        try Data("x".utf8).write(to: blocker)
        let s = f.service()
        f.source.processes = [activity("chrome")]
        await f.tick(s); await f.tick(s)
        f.source.processes = []
        await f.tick(s); await f.tick(s); await f.tick(s)  // closes the interval -> append fails
        #expect(s.degraded)
        #expect(s.lastError != nil)
        let callsWhileFailing = f.source.callCount
        await f.tick(s)
        #expect(f.source.callCount == callsWhileFailing + 1)   // keeps sampling

        try FileManager.default.removeItem(at: blocker)
        await f.tick(s)
        #expect(!s.degraded)
        #expect(s.lastError == nil)
        // The output produced while failing was retried, not lost.
        let apps = try await f.reader().perApp(wide)
        #expect(apps.first?.app == "chrome")
        #expect((apps.first?.listening ?? 0) >= 10)
    }

    @Test func pendingOutputIsBoundedWhenTheStoreKeepsFailing() async throws {
        let f = Fixture()
        try FileManager.default.createDirectory(at: f.dir, withIntermediateDirectories: true)
        let blocker = f.dir.appendingPathComponent("db")
        try Data("x".utf8).write(to: blocker)
        let s = f.service()
        // Battery readings arrive whenever the percent changes: one per tick.
        for i in 0..<1_100 {
            f.headset.set(HeadsetInsightsSnapshot(connected: true, noiseMode: .anc, battery: i % 100, charging: false))
            await f.tick(s, advance: 5)
        }
        #expect(s.degraded)
        #expect(s.pendingCounts.battery == 1000)
        try FileManager.default.removeItem(at: blocker)
        await f.tick(s)
        #expect(!s.degraded)
        #expect(s.pendingCounts.battery == 0)
        let readings = try await f.reader().batteryReadings(wide)
        #expect(readings.count >= 1000)
    }

    @Test func excludedAppsPersistAndApplyToNewSamples() async throws {
        let f = Fixture()
        let s = f.service()
        s.addExcluded("secret"); s.addExcluded("secret")
        #expect(s.excludedApps == ["secret"])
        #expect(f.defaults.stringArray(forKey: "sennsei.insights.excluded") == ["secret"])
        #expect(f.service().excludedApps == ["secret"])

        f.source.processes = [activity("secret"), activity("music")]
        for _ in 0..<3 { await f.tick(s) }
        await s.stop()
        let apps = try await f.reader().perApp(wide).map(\.app)
        #expect(apps == ["music"])

        s.removeExcluded("secret")
        #expect(s.excludedApps.isEmpty)
        #expect(f.defaults.stringArray(forKey: "sennsei.insights.excluded") == [])
    }

    @Test func disconnectedHeadsetClosesIntervals() async throws {
        let f = Fixture()
        let s = f.service()
        f.source.processes = [activity("music")]
        await f.tick(s); await f.tick(s)
        f.headset.set(HeadsetInsightsSnapshot(connected: false, noiseMode: nil, battery: nil, charging: nil))
        await f.tick(s)
        let apps = try await f.reader().perApp(wide)
        #expect(apps.first?.app == "music")
        #expect(apps.first?.listening == 10)
    }

    @Test func deleteHistoryAlsoDropsOpenIntervals() async throws {
        let f = Fixture()
        let s = f.service()
        f.source.processes = [activity("music")]
        await f.tick(s); await f.tick(s)
        await s.tick()   // an interval is open in the recorder now
        await s.deleteHistory()
        f.source.processes = []
        f.clock.advance(5)
        await s.stop()   // flush must not resurrect it
        #expect(try await f.reader().perApp(wide).isEmpty)
        #expect(try await f.reader().totals(wide) == InsightsTotals(listening: 0, call: 0))
    }

    @Test func deleteAppDropsThatAppsOpenAndPendingIntervalsButKeepsOthers() async throws {
        let f = Fixture()
        let s = f.service()
        f.source.processes = [activity("music"), activity("chrome")]
        await f.tick(s); await f.tick(s); await f.tick(s)
        await s.deleteApp("music")
        f.source.processes = []
        await s.stop()
        let apps = try await f.reader().perApp(wide).map(\.app)
        #expect(apps == ["chrome"])
    }

    @Test func deleteHistoryDoesNotRestoreDroppedOutputWhenAnInFlightAppendFails() async throws {
        let f = Fixture()
        try FileManager.default.createDirectory(at: f.dir, withIntermediateDirectories: true)
        let blocker = f.dir.appendingPathComponent("db")
        try Data("x".utf8).write(to: blocker)
        let s = f.service()
        f.headset.set(HeadsetInsightsSnapshot(connected: true, noiseMode: .anc, battery: 50, charging: false))
        await f.tick(s)
        #expect(s.pendingCounts.battery == 1)
        await s.deleteHistory()
        #expect(s.pendingCounts.battery == 0)
    }

    @Test func stopFlushesAndCancelsTheLoopWithoutLeaks() async throws {
        let f = Fixture()
        let s = f.service()
        s.start(); s.start()   // a second start must not add a second loop
        await waitFor("first sleep") { f.gate.sleeps == 1 }
        f.source.processes = [activity("music")]
        f.gate.release(); f.clock.advance(5)
        await waitFor("second sleep") { f.gate.sleeps == 2 }
        #expect(f.source.callCount == 2)
        await s.stop()
        #expect(!s.isLoopRunning)
        let calls = f.source.callCount
        f.gate.release(); f.gate.release()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(f.source.callCount == calls)
        #expect(f.gate.sleeps == 2)
        let apps = try await f.reader().perApp(wide)
        #expect(apps.first?.app == "music")
    }

    @Test func pruneRunsOnTheFirstTickAndThenOncePerLocalDay() async throws {
        let f = Fixture()
        // Seed a very old interval; the first tick prunes it.
        let old = f.clock.now.addingTimeInterval(-400 * 86_400)
        try await f.store.append(RecorderOutput(activity: [
            ActivityInterval(app: "old", appName: nil, kind: .listening, route: .bluetooth, noiseMode: nil, start: old, end: old.addingTimeInterval(60))
        ]))
        let s = f.service()
        await f.tick(s)
        #expect(s.pruneCount == 1)
        #expect(try await f.reader().perApp(wide).isEmpty)
        await f.tick(s); await f.tick(s)
        #expect(s.pruneCount == 1)
        f.clock.advance(2 * 86_400)
        await s.tick()
        #expect(s.pruneCount == 2)
    }

    @Test func switchingOffDuringAnInFlightAppendNeverPrunesAfterTheToggle() async throws {
        let f = Fixture()
        let s = f.service()
        let entered = Box(false)
        let release = SleepGate()
        s.beforeAppend = { entered.set(true); await release.sleep() }
        s.start()
        await waitFor("append in flight") { entered.get() }   // first tick: battery reading is being appended
        s.setRecording(false)
        release.release()
        await s.waitForIdle()
        #expect(s.pruneCount == 0)
        let calls = f.source.callCount
        f.gate.release()
        await s.stop()
        #expect(f.source.callCount == calls)
        #expect(s.pruneCount == 0)
    }

    @Test func aTickCancelledWhileTheSourceIsBusyTouchesNeitherStoreNorRecorder() async {
        let f = Fixture()
        let s = f.service()
        let blocked = SleepGate()
        let inSource = Box(false)
        let src = BlockingSource(inSource: inSource, gate: blocked)
        let h = f.headset, c = f.clock, g = f.gate
        let svc = InsightsService(
            store: f.store, source: src, headset: { h.get() }, settings: f.defaults,
            tick: .seconds(5), sleep: { _ in await g.sleep() }, now: { c.now })
        _ = s
        svc.start()
        await waitFor("source busy") { inSource.get() }
        svc.setRecording(false)
        blocked.release()
        await svc.waitForIdle()
        #expect(svc.pruneCount == 0)
        #expect(svc.pendingCounts.battery == 0)
        await svc.stop()
        #expect(!FileManager.default.fileExists(atPath: f.dir.path))
    }

    @Test func offOnOffOnLeavesExactlyOneLoopAndNoStaleStoreCalls() async {
        let f = Fixture()
        let s = f.service()
        s.start()
        await waitFor("first sleep") { f.gate.sleeps == 1 }
        s.setRecording(false); s.setRecording(true); s.setRecording(false); s.setRecording(true)
        await waitFor("restarted loop sleeping") { f.gate.sleeps >= 2 }
        // The cancelled loops are gone; each release must wake exactly one live loop, so a single release
        // yields a single extra sample.
        let before = f.source.callCount
        let sleepsBefore = f.gate.sleeps
        f.gate.release()
        await waitFor("one more tick") { f.gate.sleeps == sleepsBefore + 1 }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(f.source.callCount == before + 1)   // a second live loop would have sampled again
        #expect(f.gate.sleeps == sleepsBefore + 1)
        await s.stop()
        #expect(!s.isLoopRunning)
    }

    @Test func aFailedDeleteIsObservableAndOnlyClearedByASuccessfulDelete() async throws {
        let f = Fixture()
        try FileManager.default.createDirectory(at: f.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: f.url)
        let s = f.service()
        let ok = await s.deleteHistory()
        #expect(!ok)
        #expect(s.deleteFailed)
        #expect(!s.degraded)
        try FileManager.default.removeItem(at: f.url)
        await f.tick(s)                       // an unrelated successful append
        #expect(s.deleteFailed)
        #expect(await s.deleteHistory())
        #expect(!s.deleteFailed)
    }

    @Test func excludedAppsAreSanitizedOnLoadAndOnSet() {
        let f = Fixture()
        f.defaults.set(["  a ", "", "b", "a", "   "], forKey: "sennsei.insights.excluded")
        let s = f.service()
        #expect(s.excludedApps == ["a", "b"])
        s.excludedApps = [" c", "c ", "", "d"]
        #expect(s.excludedApps == ["c", "d"])
        #expect(f.defaults.stringArray(forKey: "sennsei.insights.excluded") == ["c", "d"])
        s.addExcluded("  ")
        #expect(s.excludedApps == ["c", "d"])
    }

    @Test func lastErrorIsGenericAndLeaksNoPaths() async throws {
        let f = Fixture()
        try FileManager.default.createDirectory(at: f.dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: f.dir.appendingPathComponent("db"))
        let s = f.service()
        await f.tick(s)
        #expect(s.degraded)
        #expect(s.lastError == "Could not write usage data")
        #expect(!(s.lastError ?? "").contains(f.dir.path))
    }

    @Test func stopWithTimeoutFlushesWithinTheTimeout() async throws {
        let f = Fixture()
        let s = f.service()
        f.source.processes = [activity("music")]
        await f.tick(s); await f.tick(s)
        let finished = await s.stop(timeout: .seconds(30), sleep: { _ in await SleepGate().sleep() })
        #expect(finished)
        #expect(try await f.reader().perApp(wide).first?.app == "music")
    }

    @Test func stopWithTimeoutReturnsAfterTheTimeoutWhenTheStoreBlocks() async {
        let f = Fixture()
        let s = f.service()
        let release = SleepGate()
        let entered = Box(false)
        s.beforeAppend = { entered.set(true); await release.sleep() }
        f.source.processes = [activity("music")]
        let tickTask = Task { @MainActor in await s.tick() }   // its battery append blocks in the store
        await waitFor("append blocked") { entered.get() }
        let timeoutClock = SleepGate()
        let result = Box<Bool?>(nil)
        let task = Task { @MainActor in
            result.set(await s.stop(timeout: .seconds(3), sleep: { _ in await timeoutClock.sleep() }))
        }
        await waitFor("stop waiting") { timeoutClock.sleeps == 1 }
        #expect(result.get() == nil)
        timeoutClock.release()               // the timeout elapses
        await task.value
        #expect(result.get() == false)
        release.release(); release.release() // let the blocked appends finish so nothing leaks
        await tickTask.value
        await s.waitForIdle()
    }

    @Test func stopWithTimeoutIsImmediateWhenRecordingIsOffAndSafeTwice() async {
        let f = Fixture()
        f.defaults.set(false, forKey: "sennsei.insights.recording")
        let s = f.service()
        let never = SleepGate()
        #expect(await s.stop(timeout: .seconds(3), sleep: { _ in await never.sleep() }))
        #expect(await s.stop(timeout: .seconds(3), sleep: { _ in await never.sleep() }))
        #expect(f.source.callCount == 0)
        #expect(!FileManager.default.fileExists(atPath: f.dir.path))
    }

    @Test func quitCoordinatorRunsOnceFlushesThenStopsControlThenReplies() async throws {
        let f = Fixture()
        let s = f.service()
        f.source.processes = [activity("music")]
        await f.tick(s); await f.tick(s)
        let stops = Box(0), replies = Box(0)
        let stopsAtFlush = Box(-1)
        s.beforeAppend = { stopsAtFlush.set(stops.get()) }
        let q = QuitCoordinator(insights: s, timeout: .seconds(30), sleep: { _ in await SleepGate().sleep() },
                                stopControl: { stops.set(stops.get() + 1) })
        #expect(q.begin { replies.set(replies.get() + 1) })
        #expect(!q.begin { replies.set(replies.get() + 100) })   // second quit request: ignored
        await waitFor("reply") { replies.get() == 1 }
        #expect(stops.get() == 1)
        #expect(stopsAtFlush.get() == 1)   // control socket stopped before the flush wrote anything
        #expect(q.flushFinished == true)
        #expect(!q.begin { replies.set(replies.get() + 100) })   // after completion: still ignored
        try? await Task.sleep(for: .milliseconds(20))
        #expect(replies.get() == 1); #expect(stops.get() == 1)
        #expect(try await f.reader().perApp(wide).first?.app == "music")
    }

    @Test func quitCoordinatorTimeoutBranchStillStopsControlOnceAndReplies() async {
        let f = Fixture()
        let s = f.service()
        let release = SleepGate(), timeoutClock = SleepGate()
        let entered = Box(false), stops = Box(0), replies = Box(0)
        s.beforeAppend = { entered.set(true); await release.sleep() }
        f.headset.set(HeadsetInsightsSnapshot(connected: true, noiseMode: .anc, battery: 50, charging: false))
        let tickTask = Task { @MainActor in await s.tick() }
        await waitFor("append blocked") { entered.get() }
        let q = QuitCoordinator(insights: s, timeout: .seconds(3), sleep: { _ in await timeoutClock.sleep() },
                                stopControl: { stops.set(stops.get() + 1) })
        q.begin { replies.set(replies.get() + 1) }
        await waitFor("flush waiting") { timeoutClock.sleeps == 1 }
        #expect(stops.get() == 1); #expect(replies.get() == 0)   // socket already stopped, quit still pending
        timeoutClock.release()
        await waitFor("reply") { replies.get() == 1 }
        #expect(q.flushFinished == false)
        #expect(stops.get() == 1)
        #expect(!q.begin { replies.set(replies.get() + 100) })
        release.release(); release.release()
        await tickTask.value
        await s.waitForIdle()
        #expect(replies.get() == 1); #expect(stops.get() == 1)
    }

    @Test func quitCoordinatorWithoutInsightsRepliesAndStopsControlOnce() async {
        let stops = Box(0), replies = Box(0)
        let q = QuitCoordinator(insights: nil, stopControl: { stops.set(stops.get() + 1) })
        #expect(q.begin { replies.set(replies.get() + 1) })
        await waitFor("reply") { replies.get() == 1 }
        #expect(stops.get() == 1)
        #expect(q.flushFinished == nil)
        #expect(!q.begin { replies.set(replies.get() + 100) })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(replies.get() == 1); #expect(stops.get() == 1)
    }

    @Test func quitCoordinatorOrdersControlModelFlushReplyAndRepliesOnce() async throws {
        let f = Fixture()
        let s = f.service()
        f.source.processes = [activity("music")]
        await f.tick(s); await f.tick(s)
        let events = Box([String]())
        let log: @Sendable (String) -> Void = { e in events.set(events.get() + [e]) }
        s.beforeAppend = { log("flush") }
        let q = QuitCoordinator(
            insights: s, timeout: .seconds(30), sleep: { _ in await SleepGate().sleep() },
            schedule: { _, _ in {} }, stopControl: { log("control") }, stopModel: { log("model") })
        q.begin { log("reply") }
        await waitFor("reply") { events.get().contains("reply") }
        #expect(events.get() == ["control", "flush", "model", "reply"])
    }

    @Test func quitCoordinatorHardDeadlineRepliesEvenIfTheModelNeverStops() async {
        let stuck = SleepGate()
        let fire = Box<(@MainActor @Sendable () -> Void)?>(nil)
        let stops = Box(0), replies = Box(0)
        let q = QuitCoordinator(
            insights: nil, schedule: { _, f in fire.set(f); return {} },
            stopControl: { stops.set(stops.get() + 1) }, stopModel: { await stuck.sleep() })
        q.begin { replies.set(replies.get() + 1) }
        await waitFor("stuck in model stop") { stuck.sleeps == 1 }
        #expect(replies.get() == 0)
        fire.get()?()                    // the run-loop timer fires
        #expect(replies.get() == 1)
        #expect(stops.get() == 1)
        stuck.release()                  // late completion must not reply again
        try? await Task.sleep(for: .milliseconds(20))
        #expect(replies.get() == 1)
        fire.get()?()
        #expect(replies.get() == 1)
    }

    @Test func quitCoordinatorHardDeadlineWhileTheFlushIsBlocked() async {
        let f = Fixture()
        let s = f.service()
        let release = SleepGate()
        let entered = Box(false), fire = Box<(@MainActor @Sendable () -> Void)?>(nil)
        let stops = Box(0), replies = Box(0), models = Box(0)
        s.beforeAppend = { entered.set(true); await release.sleep() }
        f.headset.set(HeadsetInsightsSnapshot(connected: true, noiseMode: .anc, battery: 50, charging: false))
        let tickTask = Task { @MainActor in await s.tick() }
        await waitFor("append blocked") { entered.get() }
        let q = QuitCoordinator(
            insights: s, timeout: .seconds(3), sleep: { _ in await SleepGate().sleep() },
            schedule: { _, f in fire.set(f); return {} },
            stopControl: { stops.set(stops.get() + 1) }, stopModel: { models.set(models.get() + 1) })
        q.begin { replies.set(replies.get() + 1) }
        await waitFor("coordinator task started") { fire.get() != nil && stops.get() == 1 }
        fire.get()?()
        #expect(replies.get() == 1)
        #expect(q.flushFinished == false)
        #expect(stops.get() == 1)
        release.release(); release.release()
        await tickTask.value
        await s.waitForIdle()
        #expect(replies.get() == 1)
    }

    @Test func aHungModelStopDoesNotCostTheFlush() async throws {
        let f = Fixture()
        let s = f.service()
        f.source.processes = [activity("music")]
        await f.tick(s); await f.tick(s)
        let stuck = SleepGate()
        let fire = Box<(@MainActor @Sendable () -> Void)?>(nil)
        let replies = Box(0)
        let q = QuitCoordinator(
            insights: s, timeout: .seconds(30), sleep: { _ in await SleepGate().sleep() },
            schedule: { _, fn in fire.set(fn); return {} }, stopControl: {}, stopModel: { await stuck.sleep() })
        q.begin { replies.set(replies.get() + 1) }
        await waitFor("model stop hanging") { stuck.sleeps == 1 }
        fire.get()?()                                   // deadline
        #expect(replies.get() == 1)
        #expect(q.flushFinished == true)
        let apps = try await f.reader().perApp(wide)    // the flush landed before the deadline reply
        #expect(apps.count == 1); #expect(apps.first?.app == "music"); #expect(apps.first?.listening == 10)
        stuck.release()
    }

    @Test func aHungFlushIsCutByTheDeadlineAndTheModelStopIsSkipped() async {
        let f = Fixture()
        let s = f.service()
        let release = SleepGate()
        let entered = Box(false), fire = Box<(@MainActor @Sendable () -> Void)?>(nil)
        let replies = Box(0), models = Box(0)
        s.beforeAppend = { entered.set(true); await release.sleep() }
        f.headset.set(HeadsetInsightsSnapshot(connected: true, noiseMode: .anc, battery: 50, charging: false))
        let tickTask = Task { @MainActor in await s.tick() }
        await waitFor("append blocked") { entered.get() }
        let q = QuitCoordinator(
            insights: s, timeout: .seconds(30), sleep: { _ in await SleepGate().sleep() },
            schedule: { _, fn in fire.set(fn); return {} }, stopControl: {},
            stopModel: { models.set(models.get() + 1) })
        q.begin { replies.set(replies.get() + 1) }
        await waitFor("armed") { fire.get() != nil }
        fire.get()?()
        #expect(replies.get() == 1)
        #expect(q.flushFinished == false)
        #expect(models.get() == 0)
        release.release(); release.release()
        await tickTask.value
        await s.waitForIdle()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(models.get() == 0)      // the deadline already answered AppKit; the model stop is not started late
        #expect(replies.get() == 1)
    }

    @Test func runLoopTimerFiresOnTheMainRunLoopAndConvertsDurations() {
        #expect(QuitCoordinator.seconds(.milliseconds(1500)) == 1.5)
        #expect(QuitCoordinator.seconds(.seconds(3)) == 3)
        #expect(QuitCoordinator.seconds(.milliseconds(10)) == 0.01)
        let fired = Box(false)
        let cancel = QuitCoordinator.runLoopTimer(.milliseconds(10)) { fired.set(true) }
        let deadline = Date().addingTimeInterval(2)
        while !fired.get(), Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        #expect(fired.get())
        cancel()
        let late = Box(false)
        let cancel2 = QuitCoordinator.runLoopTimer(.milliseconds(10)) { late.set(true) }
        cancel2()
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        #expect(!late.get())
    }

    @Test func insightsSnapshotReadsConnectionBatteryAndNoiseModeOnly() async {
        let sim = SimulatedHeadset()
        let m = AppModel(makeTransport: { sim }, pollInterval: .seconds(3600), replyTimeout: .milliseconds(80))
        let before = m.insightsSnapshot()
        #expect(!before.connected); #expect(before.battery == nil)
        await m.start()
        let snap = m.insightsSnapshot()
        #expect(snap.connected)
        #expect(snap.battery == 20)
        #expect(snap.noiseMode == .anc)
        let cmds = await sim.sent.map(\.command)
        let writes = cmds.filter { [0x1A04, 0x1804, 0x1800, 0x0803, 0x1002, 0x1006, 0x1004].contains($0) }
        #expect(writes.isEmpty)
        await m.stop()
    }
}
