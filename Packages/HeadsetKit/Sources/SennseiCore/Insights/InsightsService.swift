import Foundation
import HeadsetCore
import Observation
import os

/// What the insights feature may know about the headset. Read-only: it is built from `AppModel.phase`
/// and `AppModel.state`, and nothing here (or in the service) ever writes to the headphones.
public struct HeadsetInsightsSnapshot: Sendable, Equatable {
    public var connected: Bool
    public var noiseMode: NoiseMode?
    public var battery: Int?
    public var charging: Bool?

    public init(connected: Bool, noiseMode: NoiseMode?, battery: Int?, charging: Bool?) {
        self.connected = connected
        self.noiseMode = noiseMode
        self.battery = battery
        self.charging = charging
    }
}

/// The sampling loop behind Insights: every `tick` it reads the audio activity and the headset snapshot,
/// feeds the pure `InsightsRecorder` and appends what the recorder closes to the `InsightsStore`.
///
/// Rules: while recording is off the loop is not running, the source is never read and the store is never
/// touched. A store failure only sets `degraded`/`lastError`; the loop keeps going and the unwritten output
/// stays in memory (bounded) to be written with the next append.
@MainActor @Observable
public final class InsightsService {
    public static let recordingKey = "sennsei.insights.recording"
    public static let excludedKey = "sennsei.insights.excluded"
    /// At most this many unwritten intervals/readings are kept per kind while the store keeps failing.
    static let pendingCap = 1000

    public private(set) var isRecording: Bool
    public private(set) var degraded = false
    public private(set) var lastError: String?
    /// True after a delete failed; only a later successful delete clears it.
    public private(set) var deleteFailed = false
    public var excludedApps: [String] {
        didSet {
            let clean = Self.sanitized(excludedApps)
            if clean != excludedApps { excludedApps = clean; return }   // re-enters once with clean data
            guard excludedApps != oldValue else { return }
            settings.set(excludedApps, forKey: Self.excludedKey)
            recorder.excluded = Set(excludedApps)
        }
    }

    @ObservationIgnored private let store: InsightsStore
    @ObservationIgnored private let source: any AudioActivitySource
    @ObservationIgnored private let headset: @MainActor () -> HeadsetInsightsSnapshot
    @ObservationIgnored private let settings: UserDefaults
    @ObservationIgnored private let tickDuration: Duration
    @ObservationIgnored private let sleepFor: @Sendable (Duration) async -> Void
    @ObservationIgnored private let now: @Sendable () -> Date

    @ObservationIgnored private var recorder: InsightsRecorder
    @ObservationIgnored private var pending = RecorderOutput()
    /// Bumped by every delete so a failed in-flight append cannot put dropped output back.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    @ObservationIgnored private var lastPruneDay: Date?
    @ObservationIgnored private var failures: [String: String] = [:]
    @ObservationIgnored private var failureOrder: [String] = []
    @ObservationIgnored private(set) var pruneCount = 0
    /// Test seam: awaited right before every store append.
    @ObservationIgnored var beforeAppend: (@Sendable () async -> Void)?

    public init(
        store: InsightsStore,
        source: any AudioActivitySource,
        headset: @escaping @MainActor () -> HeadsetInsightsSnapshot,
        settings: UserDefaults = .standard,
        tick: Duration = .seconds(5),
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in _ = try? await Pause.sleep(duration) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.source = source
        self.headset = headset
        self.settings = settings
        self.tickDuration = tick
        self.sleepFor = sleep
        self.now = now
        self.isRecording = settings.object(forKey: Self.recordingKey) as? Bool ?? true
        let excluded = Self.sanitized(settings.stringArray(forKey: Self.excludedKey) ?? [])
        self.excludedApps = excluded
        let seconds = Double(tick.components.seconds) + Double(tick.components.attoseconds) / 1e18
        self.recorder = InsightsRecorder(tick: seconds, mergeGap: 2 * seconds, excluded: Set(excluded))
    }

    // MARK: - Settings

    public func setRecording(_ on: Bool) {
        guard on != isRecording else { return }
        isRecording = on
        settings.set(on, forKey: Self.recordingKey)
        if on {
            if started { startLoop() }
        } else {
            beginShutdown()
        }
    }

    public func addExcluded(_ bundleID: String) {
        guard !bundleID.isEmpty, !excludedApps.contains(bundleID) else { return }
        excludedApps.append(bundleID)
    }

    public func removeExcluded(_ bundleID: String) {
        excludedApps.removeAll { $0 == bundleID }
    }

    // MARK: - Lifecycle

    /// Starts the single sampling loop when recording is on. Safe to call twice.
    public func start() {
        started = true
        if isRecording { startLoop() }
    }

    /// Flushes the recorder, writes it, cancels the loop and waits for it to end.
    public func stop() async {
        started = false
        beginShutdown()
        await shutdownTask?.value
    }

    /// `stop()` bounded by `timeout`, for quitting: returns true when the flush finished in time and false
    /// when the store was too slow (the stop keeps running in the background; the caller must not wait).
    /// `sleep` is the timeout clock (injectable); a cancelled sleep ends early.
    public func stop(
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in _ = try? await Pause.sleep(duration) }
    ) async -> Bool {
        let before = pendingCounts
        Self.quitLog.notice("insights stop: begin (recording=\(self.isRecording, privacy: .public), pending activity=\(before.activity, privacy: .public) noise=\(before.noise, privacy: .public) battery=\(before.battery, privacy: .public))")
        let finished: Bool = await withCheckedContinuation { cont in
            let once = ResumeOnce(cont)
            let timer = Task { await sleep(timeout); guard !Task.isCancelled else { return }; once.resume(false) }
            Task { @MainActor in
                await self.stop()
                timer.cancel()
                once.resume(true)
            }
        }
        let after = pendingCounts
        Self.quitLog.notice("insights stop: \(finished ? "finished" : "TIMED OUT", privacy: .public) (still unwritten activity=\(after.activity, privacy: .public) noise=\(after.noise, privacy: .public) battery=\(after.battery, privacy: .public), degraded=\(self.degraded, privacy: .public))")
        return finished
    }

    private static let quitLog = Logger(subsystem: AppInfo.bundleIdentifier, category: "quit")

    var isLoopRunning: Bool { loopTask != nil }
    var pendingCounts: (activity: Int, noise: Int, battery: Int) {
        (pending.activity.count, pending.noise.count, pending.battery.count)
    }
    func waitForIdle() async { await shutdownTask?.value }

    private func startLoop() {
        guard loopTask == nil else { return }
        let previous = shutdownTask
        let sleep = sleepFor
        let duration = tickDuration
        loopTask = Task { [weak self] in
            await previous?.value
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                if Task.isCancelled { return }
                await sleep(duration)
            }
        }
    }

    /// Cancels the loop, then (after it ended) flushes the recorder and writes everything that is open.
    private func beginShutdown() {
        let loop = loopTask
        loopTask = nil
        loop?.cancel()
        let previous = shutdownTask
        shutdownTask = Task { [weak self] in
            await previous?.value
            await loop?.value
            await self?.flushAndWrite()
        }
    }

    private func flushAndWrite() async {
        let out = recorder.flush()
        Self.quitLog.notice("insights flush: closed activity=\(out.activity.count, privacy: .public) noise=\(out.noise.count, privacy: .public) battery=\(out.battery.count, privacy: .public)")
        await persist(out)
    }

    // MARK: - One tick

    func tick() async {
        guard isRecording, !Task.isCancelled else { return }
        let processes = await source.snapshot()
        // Switched off while the source was being read: drop this sample, the shutdown flush owns the
        // recorder from here on.
        guard isRecording, !Task.isCancelled else { return }
        let h = headset()
        let sample = InsightsSample(
            time: now(), processes: processes, connected: h.connected,
            noiseMode: h.noiseMode, battery: h.battery, charging: h.charging)
        let out = recorder.ingest(sample)
        await persist(out)
        // Switched off (or cancelled) while the append was in flight: the shutdown flush is the only store
        // write that may follow, so no prune (it could also be the first contact and create the file).
        guard isRecording, !Task.isCancelled else { return }
        await pruneIfDue(at: sample.time)
    }

    // MARK: - Store access

    private func persist(_ new: RecorderOutput) async {
        append(new, to: &pending)
        guard !pending.isEmpty else { return }
        let batch = pending
        pending = RecorderOutput()
        let startEpoch = epoch
        do {
            await beforeAppend?()
            try await store.append(batch)
            succeeded("append")
        } catch {
            if epoch == startEpoch {
                var restored = batch
                append(pending, to: &restored)
                pending = restored
                Self.cap(&pending)
            }
            failed("append", error)
        }
    }

    private func pruneIfDue(at time: Date) async {
        let day = Calendar.current.startOfDay(for: time)
        guard lastPruneDay != day else { return }
        do {
            try await store.prune(now: time)
            lastPruneDay = day
            pruneCount += 1
            succeeded("prune")
        } catch {
            failed("prune", error)
        }
    }

    @discardableResult
    public func deleteHistory() async -> Bool {
        epoch += 1
        _ = recorder.flush()
        pending = RecorderOutput()
        do {
            try await store.deleteAll()
            deleteFailed = false
            return true
        } catch {
            NSLog("Sennsei insights: delete failed: \(error)")
            deleteFailed = true
            return false
        }
    }

    @discardableResult
    public func deleteApp(_ bundleID: String) async -> Bool {
        epoch += 1
        // Close everything the recorder has open, drop this app's part and keep the rest for the next write.
        append(recorder.flush(), to: &pending)
        pending.activity.removeAll { $0.app == bundleID }
        do {
            try await store.delete(app: bundleID)
            deleteFailed = false
            return true
        } catch {
            NSLog("Sennsei insights: delete failed: \(error)")
            deleteFailed = true
            return false
        }
    }

    // MARK: - Helpers

    private func append(_ extra: RecorderOutput, to target: inout RecorderOutput) {
        target.activity += extra.activity
        target.noise += extra.noise
        target.battery += extra.battery
        Self.cap(&target)
    }

    private static func cap(_ out: inout RecorderOutput) {
        if out.activity.count > pendingCap { out.activity.removeFirst(out.activity.count - pendingCap) }
        if out.noise.count > pendingCap { out.noise.removeFirst(out.noise.count - pendingCap) }
        if out.battery.count > pendingCap { out.battery.removeFirst(out.battery.count - pendingCap) }
    }

    private static func sanitized(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap { raw in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty || !seen.insert(id).inserted ? nil : id
        }
    }

    /// `lastError` is user-facing text; the raw error (it can contain file paths) only goes to the log.
    private func failed(_ key: String, _ error: Error) {
        NSLog("Sennsei insights: \(key) failed: \(error)")
        failures[key] = "Could not write usage data"
        failureOrder.removeAll { $0 == key }
        failureOrder.append(key)
        refreshStatus()
    }

    private func succeeded(_ key: String) {
        failures[key] = nil
        failureOrder.removeAll { failures[$0] == nil }
        refreshStatus()
    }

    private func refreshStatus() {
        degraded = !failures.isEmpty
        lastError = failureOrder.last.flatMap { failures[$0] }
    }
}

/// Resumes a continuation at most once, from any thread.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ c: CheckedContinuation<Bool, Never>) { continuation = c }
    func resume(_ value: Bool) {
        let c = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: value)
    }
}
