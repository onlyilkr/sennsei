import Foundation
import HeadsetCore
import Observation

public enum ConnectionPhase: Equatable, Sendable { case idle, connecting, connected, failed(UserMessage) }

/// A message for the UI. `key` is a String Catalog key; no text is produced here.
public struct UserMessage: Equatable, Sendable {
    public let key: String
    public let argument: String?
    /// Every error key the model can produce (single source; `Strings.allKeys` and the tests use it).
    public enum ErrorKey {
        public static let notConnected = "error.notConnected"
        public static let timeout = "error.timeout"
        public static let readBack = "error.readBack"
        public static let readOnly = "error.readOnly"
        public static let unsupported = "error.unsupported"
        public static let bluetooth = "error.bluetooth"
        public static let connect = "error.connect"
        public static let link = "error.link"
        public static let other = "error.other"
        public static let all = [notConnected, timeout, readBack, readOnly, unsupported, bluetooth, connect, link, other]
    }
    public init(key: String, argument: String? = nil) {
        self.key = key
        self.argument = argument
    }
}

/// Why a remote action was refused after the headset was re-read (no write happened).
enum ActionRefusal: Error, Equatable { case stateUnknown, eqUnavailable(EQAvailability) }

/// The outcome of one action, captured inside the same hold of the action lock that ran it, so a
/// concurrent action can neither clear nor inject it.
struct ActionResult: Equatable {
    var error: UserMessage?
    var refusal: ActionRefusal?
    var connectionLost = false
    var progress: UserMessage?
    var succeeded: Bool { error == nil && refusal == nil && !connectionLost }
}

public enum EQAvailability: Equatable, Sendable {
    case available
    case needsFirmwareUpdate(minimum: String)
    case audioModeNotEqualizer
    case readOnlyModel
    case unsupportedGeneration
}

/// The UI-free application core: one headset session, its published state and the explicit user actions.
///
/// Rules: no optimistic updates (state comes only from the session); writes happen only from explicit
/// user actions (`start`, polling and reconnect never write); after a failure the state is re-taken
/// from the session.
@MainActor @Observable
public final class AppModel {
    public private(set) var phase: ConnectionPhase = .idle
    public private(set) var state: HeadsetState?
    public private(set) var busy = false
    public private(set) var lastError: UserMessage?

    /// Derived from the device-read gains on every read: a preset is "selected" only while the
    /// headset's gains match it within 0.11 dB, so it can never claim a preset the device lacks.
    public var selectedPreset: String? {
        guard let gains = state?.eq?.gains else { return nil }
        return EQPresetCatalog.presets.first { preset in
            preset.gains.count == gains.count
                && zip(preset.gains, gains).allSatisfy { abs($0 - $1) <= 0.11 + 1e-9 }
        }?.name
    }

    @ObservationIgnored private let makeTransport: @Sendable () -> any HeadsetTransport
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let replyTimeout: Duration
    @ObservationIgnored private var session: HeadsetSession?
    // Bumped by every start()/stop(); an in-flight start that sees a different value yields.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    // Actions run one at a time, in call order.
    @ObservationIgnored private var pendingActions = 0
    @ObservationIgnored private var actionWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var actionRunning = false

    // MARK: Scenes

    /// Replaced only by scene editing; an auto scene that disappears from here is forgotten.
    public internal(set) var scenes: [Scene]
    /// Why the last scene application was partial (for example the equalizer was skipped).
    public private(set) var sceneProgress: UserMessage?
    public private(set) var automaticScenesEnabled: Bool
    private var autoState = AutoSceneState()
    /// The scene most recently applied (by hand or by a trigger) and not yet restored.
    public var activeSceneID: String? { autoState.activeID }
    @ObservationIgnored private var frontApp: String?
    @ObservationIgnored private let sceneStore: SceneStore?
    @ObservationIgnored private let frontAppMonitor: (any FrontAppMonitor)?
    @ObservationIgnored private let sceneDebounce: Duration
    @ObservationIgnored private let settings: UserDefaults
    // Bumped by every manual action the moment it is requested; an automatic decision made before
    // that must neither finish its bookkeeping nor (if still queued) write anything.
    @ObservationIgnored private var manualEpoch = 0
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    private static let automaticScenesKey = "sennsei.automaticScenes"

    public init(
        makeTransport: @escaping @Sendable () -> any HeadsetTransport,
        pollInterval: Duration = .seconds(60),
        replyTimeout: Duration = .milliseconds(1500),
        sceneStore: SceneStore? = nil,
        frontAppMonitor: (any FrontAppMonitor)? = nil,
        sceneDebounce: Duration = .milliseconds(1500),
        settings: UserDefaults = .standard
    ) {
        self.makeTransport = makeTransport
        self.pollInterval = pollInterval
        self.replyTimeout = replyTimeout
        self.sceneStore = sceneStore
        self.frontAppMonitor = frontAppMonitor
        self.sceneDebounce = sceneDebounce
        self.settings = settings
        self.scenes = sceneStore?.load().scenes ?? Scene.defaults
        self.automaticScenesEnabled = settings.bool(forKey: Self.automaticScenesKey)   // absent = false
    }

    /// Read-only view for the Insights sampler: connection, noise mode, battery. Never writes to the headset.
    public func insightsSnapshot() -> HeadsetInsightsSnapshot {
        HeadsetInsightsSnapshot(
            connected: phase == .connected, noiseMode: state?.noiseMode,
            battery: state?.battery.map(Int.init), charging: state?.charging)
    }

    // MARK: Availability

    /// Why the equalizer can or cannot be written right now. Without a connection nothing can be
    /// written, which is reported as `.readOnlyModel`.
    public var eqAvailability: EQAvailability {
        guard let profile = state?.profile else { return .readOnlyModel }
        if !profile.isWritable { return .readOnlyModel }
        switch profile.eq {
        case .gen2: return .unsupportedGeneration
        case .none:
            if case .accentum = profile.model { return .needsFirmwareUpdate(minimum: "2.12.0") }
            return .unsupportedGeneration
        case .gen1:
            return state?.audioMode == 1 ? .available : .audioModeNotEqualizer
        }
    }

    // MARK: Lifecycle

    public func start() async {
        switch phase {
        case .connecting, .connected: return
        case .idle, .failed: break
        }
        generation += 1
        let gen = generation
        phase = .connecting
        lastError = nil
        startMonitoring()
        await teardown()   // never leave an earlier session or poll task behind
        guard gen == generation else { return }
        let session = HeadsetSession(transport: makeTransport(), replyTimeout: replyTimeout, allowUnverifiedWrites: false)
        self.session = session
        do {
            let connected = try await session.connect()
            guard gen == generation else { return }   // stop()/reconnect() won; it disconnects the session
            state = connected
            if connected.profile.eq == .gen1, connected.profile.isWritable {
                _ = try? await session.readEQ()   // a failed EQ read leaves eq = nil
                guard gen == generation else { return }
            }
            // The pause-in-Transparency switch is shown from its first open; a failed read leaves it unknown.
            _ = try? await session.refreshStatus()
            guard gen == generation else { return }
            state = await session.state
            guard gen == generation else { return }
            phase = .connected
            startPolling(session, gen: gen)
        } catch {
            guard gen == generation else { return }
            let message = Self.userMessage(for: error)
            lastError = message
            state = nil
            self.session = nil
            await session.disconnect()
            guard gen == generation else { return }
            phase = .failed(message)
        }
    }

    public func stop() async {
        generation += 1
        await stopMonitoring()
        await teardown()
        state = nil
        phase = .idle
    }

    public func reconnect() async {
        await stop()
        await start()
    }

    private func teardown() async {
        let task = pollTask
        pollTask = nil
        task?.cancel()
        await task?.value
        let session = self.session
        self.session = nil
        await session?.disconnect()
    }

    /// The link is gone (the session reports no state): stop polling, drop the session, show the failure.
    private func linkLost(_ lost: HeadsetSession, gen: Int) async {
        guard gen == generation, session === lost else { return }
        pollTask?.cancel()
        pollTask = nil
        session = nil
        state = nil
        autoState = AutoSceneState()   // nothing applied before the drop can be restored after it
        phase = .failed(UserMessage(key: UserMessage.ErrorKey.link))
        await lost.disconnect()
    }

    // MARK: Actions

    public func setNoiseMode(_ mode: NoiseMode) async { _ = await setNoiseModeOutcome(mode) }
    public func setPauseInTransparency(_ pause: Bool) async { _ = await setPauseOutcome(pause) }
    public func applyPreset(_ name: String) async { _ = await applyPresetOutcome(name) }

    func setNoiseModeOutcome(_ mode: NoiseMode) async -> ActionResult {
        noteManualAction()
        return await performOutcome { [self] session in try await noiseBody(session, mode) }
    }

    func setPauseOutcome(_ pause: Bool) async -> ActionResult {
        noteManualAction()
        return await performOutcome { [self] session in try await pauseBody(session, pause) }
    }

    func applyPresetOutcome(_ name: String) async -> ActionResult {
        noteManualAction()
        return await performOutcome { [self] session in
            state = try await session.refreshStatus()   // fresh audio mode
            guard eqAvailability == .available else { throw ActionRefusal.eqUnavailable(eqAvailability) }
            try await writePreset(session, name)
        }
    }

    /// anc → transparency → off → anc, from the headset's own fresh state (read and write in one lock hold).
    func cycleNoiseMode() async -> ActionResult {
        return await performOutcome { [self] session in
            let fresh = try await session.refreshStatus()
            state = fresh
            guard let current = fresh.noiseMode else { throw ActionRefusal.stateUnknown }
            noteManualAction()   // only a cycle that will write counts as a manual action
            let next: NoiseMode
            switch current {
            case .anc: next = .transparency
            case .transparency: next = .off
            case .off: next = .anc
            }
            try await noiseBody(session, next)
        }
    }

    /// The preset after the selected one (the first when none matches), from a fresh read of the headset.
    func cycleEQPreset() async -> ActionResult {
        return await performOutcome { [self] session in
            state = try await session.refreshStatus()   // fresh audio mode
            guard eqAvailability == .available else { throw ActionRefusal.eqUnavailable(eqAvailability) }
            do { _ = try await session.readEQ() } catch { throw EQStateUnknown() }
            state = await session.state
            let presets = EQPresetCatalog.presets
            guard !presets.isEmpty else { throw SessionError.unsupported("equalizer") }
            let next: String
            if let current = selectedPreset, let i = presets.firstIndex(where: { $0.name == current }) {
                next = presets[(i + 1) % presets.count].name
            } else {
                next = presets[0].name
            }
            noteManualAction()   // only a cycle that will write counts as a manual action
            try await writePreset(session, next)
        }
    }

    private func noiseBody(_ session: HeadsetSession, _ mode: NoiseMode) async throws {
        // Read-only refresh first: the headset can be changed with its own button.
        let fresh = try await session.refreshStatus()
        if fresh.noiseMode == mode { return }   // already active: nothing to write
        try await session.setNoiseMode(mode)
    }

    private func pauseBody(_ session: HeadsetSession, _ pause: Bool) async throws {
        // Read-only refresh first: the headset can be changed with its own app or button.
        let fresh = try await session.refreshStatus()
        if fresh.pauseInTransparency == pause { return }   // already so: nothing to write
        try await session.setPauseInTransparency(pause)
    }

    private func writePreset(_ session: HeadsetSession, _ name: String) async throws {
        guard eqAvailability == .available,
            let preset = EQPresetCatalog.presets.first(where: { $0.name == name })
        else { throw SessionError.unsupported("equalizer") }
        try await readEQIfUnknown(session)
        // The bass flag comes from a known equalizer only (an unconfigured one has none: off).
        guard let eq = state?.eq, let bass = eq.bassBoost ?? (eq.isUnconfigured ? false : nil)
        else { throw EQStateUnknown() }
        _ = try await session.writeEQ(gains: preset.gains, bassBoost: bass)
    }

    public func setBassBoost(_ on: Bool) async {
        noteManualAction()
        await perform { [self] session in
            state = try await session.refreshStatus()   // fresh audio mode
            guard eqAvailability == .available else { throw SessionError.unsupported("equalizer") }
            try await readEQIfUnknown(session)
            // Gains come from a known equalizer only; flat is allowed only when it is unconfigured.
            guard let eq = state?.eq, let gains = eq.gains ?? (eq.isUnconfigured ? [0, 0, 0, 0, 0] : nil)
            else { throw EQStateUnknown() }
            _ = try await session.writeEQ(gains: gains, bassBoost: on)
        }
    }

    private struct EQStateUnknown: Error {}

    /// An unknown equalizer (nil) is re-read (read-only) before a write; a failed re-read refuses the write.
    private func readEQIfUnknown(_ session: HeadsetSession) async throws {
        guard state?.eq == nil else { return }
        do { _ = try await session.readEQ() } catch { throw EQStateUnknown() }
        state = await session.state
    }

    /// Runs one user action in call order; `busy` stays true until the last queued action is done.
    @discardableResult
    private func perform(_ body: (HeadsetSession) async throws -> Void) async -> Bool {
        await performOutcome(body).succeeded
    }

    private func performOutcome(_ body: (HeadsetSession) async throws -> Void) async -> ActionResult {
        pendingActions += 1
        busy = true
        await acquireActionLock()
        defer {
            releaseActionLock()
            pendingActions -= 1
            busy = pendingActions > 0
        }
        lastError = nil
        guard let session else {
            let message = UserMessage(key: UserMessage.ErrorKey.notConnected)
            lastError = message
            return ActionResult(error: message)
        }
        let gen = generation
        var result = ActionResult()
        do {
            try await body(session)
        } catch let refusal as ActionRefusal {
            if case .eqUnavailable = refusal {
                lastError = UserMessage(key: UserMessage.ErrorKey.unsupported, argument: "equalizer")
            } else {
                lastError = UserMessage(key: UserMessage.ErrorKey.other)
            }
            result.refusal = refusal
        } catch {
            let message = Self.userMessage(for: error)
            lastError = message
            result.error = message
        }
        result.progress = sceneProgress
        // The state always comes from the session; no state at all means the link is gone.
        if let fresh = await session.state {
            state = fresh
        } else {
            await linkLost(session, gen: gen)
            result.connectionLost = true   // a dead link never counts as an applied scene
        }
        return result
    }

    private func acquireActionLock() async {
        if !actionRunning { actionRunning = true; return }
        await withCheckedContinuation { actionWaiters.append($0) }
    }

    private func releaseActionLock() {
        if actionWaiters.isEmpty { actionRunning = false } else { actionWaiters.removeFirst().resume() }
    }

    // MARK: Scenes

    /// Every manual change wins over automation for the current front app: no snapshot to restore, no
    /// active scene to mistake for "already applied", and the app's trigger stays quiet until it changes.
    private func noteManualAction() {
        manualEpoch += 1
        autoState.snapshot = nil
        autoState.activeID = nil
        autoState.manualOverrideApp = frontApp
    }

    public func setAutomaticScenes(_ on: Bool) {
        manualEpoch += 1   // an in-flight or queued decision must not outlive the switch
        automaticScenesEnabled = on
        if !on { autoState = AutoSceneState() }
        settings.set(on, forKey: Self.automaticScenesKey)
    }

    /// Manual application. Drops the auto snapshot (leaving an app must not undo a manual choice) and
    /// pins the current front app so its trigger does not re-apply an auto scene over this choice.
    public func applyScene(_ id: String) async { _ = await applySceneOutcome(id) }

    func applySceneOutcome(_ id: String) async -> ActionResult {
        func refuse(_ key: String) -> ActionResult {
            let message = UserMessage(key: key)
            lastError = message
            return ActionResult(error: message)
        }
        guard let scene = scenes.first(where: { $0.id == id }) else { return refuse(UserMessage.ErrorKey.other) }
        // Refuse before touching any auto bookkeeping: a failed attempt must change nothing.
        guard session != nil, phase == .connected else { return refuse(UserMessage.ErrorKey.notConnected) }
        guard state?.profile.isWritable == true else { return refuse(UserMessage.ErrorKey.readOnly) }
        manualEpoch += 1
        autoState.snapshot = nil
        autoState.manualOverrideApp = frontApp
        let result = await executeOutcome(SceneEngine.steps(for: scene))
        if result.succeeded { autoState.activeID = scene.id }
        return result
    }

    private var currentSnapshot: SceneSnapshot {
        SceneSnapshot(noiseMode: state?.noiseMode, pauseInTransparency: state?.pauseInTransparency, eqPreset: selectedPreset)
    }

    /// The single write path for scenes (manual, automatic and restore): one action under the action
    /// lock; the first failing step aborts the rest. An unavailable equalizer skips only its own step.
    private func executeOutcome(_ steps: [SceneStep]) async -> ActionResult {
        await performOutcome { [self] session in
            sceneProgress = nil
            try await runSteps(steps, session)
        }
    }

    private func runSteps(_ steps: [SceneStep], _ session: HeadsetSession) async throws {
        guard state?.profile.isWritable == true else { throw SessionError.unsupported("read-only model") }
        for step in steps {
            switch step {
            case .pauseInTransparency(let pause): try await pauseBody(session, pause)
            case .noiseMode(let mode): try await noiseBody(session, mode)
            case .eqPreset(let name):
                state = try await session.refreshStatus()   // fresh audio mode
                if eqAvailability == .available {
                    try await writePreset(session, name)
                } else {
                    sceneProgress = UserMessage(key: "scene.eqSkipped")
                }
            }
        }
    }

    private func startMonitoring() {
        guard monitorTask == nil, let monitor = frontAppMonitor else { return }
        let stream = monitor.changes
        monitorTask = Task { [weak self] in
            for await app in stream {
                if Task.isCancelled { return }
                self?.frontAppChanged(app)
            }
        }
    }

    private func stopMonitoring() async {
        let monitor = monitorTask, pending = debounceTask
        monitorTask = nil
        debounceTask = nil
        monitor?.cancel()
        pending?.cancel()
        await monitor?.value
        await pending?.value
        frontApp = nil
        autoState = AutoSceneState()
    }

    private func frontAppChanged(_ app: String?) {
        if app != frontApp {
            frontApp = app
            autoState.manualOverrideApp = nil
        }
        // Restart the debounce; a decision already applying finishes before the next one starts.
        let previous = debounceTask
        previous?.cancel()
        let delay = sceneDebounce
        let epoch = manualEpoch   // a manual action during the debounce window wins over this change
        debounceTask = Task { [weak self] in
            await previous?.value
            guard (try? await Task.sleep(for: delay)) != nil, !Task.isCancelled else { return }
            await self?.decideAutomatically(frontApp: app, epoch: epoch)
        }
    }

    /// Refresh, decision and writes happen under ONE hold of the action lock, so no manual action can
    /// slip in between them. A manual action requested after this decision started (epoch changed) wins:
    /// it skips the writes if still queued, and skips the bookkeeping if it arrived mid-apply.
    private func decideAutomatically(frontApp app: String?, epoch: Int) async {
        guard automaticScenesEnabled, phase == .connected, manualEpoch == epoch else { return }
        if let id = autoState.activeID, !scenes.contains(where: { $0.id == id }) {
            autoState.activeID = nil
            autoState.snapshot = nil
        }
        // Nothing matches and nothing is active: no work at all, not even a read.
        if SceneEngine.match(frontApp: app, in: scenes) == nil, autoState.activeID == nil { return }
        var decision = AutoDecision.nothing
        let ok = await perform { [self] session in
            guard automaticScenesEnabled, manualEpoch == epoch else { return }
            // Read-only refresh first so the snapshot reflects the headset, not a stale poll.
            state = try await session.refreshStatus()
            guard automaticScenesEnabled, manualEpoch == epoch else { return }   // a manual action landed during the read
            decision = SceneEngine.decide(
                state: autoState, frontApp: app, scenes: scenes, enabled: automaticScenesEnabled,
                current: currentSnapshot)
            switch decision {
            case .nothing: break
            case .apply(let scene, _):
                sceneProgress = nil
                try await runSteps(SceneEngine.steps(for: scene), session)
            case .restore(let snapshot, let applied):
                sceneProgress = nil
                try await runSteps(SceneEngine.restoreSteps(snapshot: snapshot, applied: applied), session)
            }
        }
        guard ok, automaticScenesEnabled, manualEpoch == epoch else { return }
        switch decision {
        case .nothing:
            break
        case .apply(let scene, let snapshot):
            // A -> B keeps the snapshot taken before A, not A's own values.
            if autoState.snapshot == nil { autoState.snapshot = snapshot }
            autoState.activeID = scene.id
        case .restore:
            autoState.activeID = nil
            autoState.snapshot = nil
        }
    }

    // MARK: Polling (reads only)

    private func startPolling(_ session: HeadsetSession, gen: Int) {
        pollTask?.cancel()
        let interval = pollInterval
        pollTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                do {
                    let refreshed = try await session.refreshStatus()
                    if Task.isCancelled { return }
                    self?.state = refreshed
                    failures = 0
                } catch {
                    if Task.isCancelled { return }
                    failures += 1
                    if failures >= 2 {
                        await self?.linkLost(session, gen: gen)
                        return
                    }
                }
            }
        }
    }

    // MARK: Error mapping

    nonisolated static func userMessage(for error: Error) -> UserMessage {
        switch error {
        case let e as SessionError:
            switch e {
            case .notConnected: return UserMessage(key: UserMessage.ErrorKey.notConnected)
            case .timeout(let what): return UserMessage(key: UserMessage.ErrorKey.timeout, argument: what)
            case .readBackMismatch(let what): return UserMessage(key: UserMessage.ErrorKey.readBack, argument: what)
            case .rejected(let c): return userMessage(for: c)
            case .unsupported(let what):
                return UserMessage(key: what == "read-only model" ? UserMessage.ErrorKey.readOnly : UserMessage.ErrorKey.unsupported, argument: what)
            case .linkDead: return UserMessage(key: UserMessage.ErrorKey.link)
            case .transport(let t): return userMessage(for: t)
            case .device(let command, _): return UserMessage(key: UserMessage.ErrorKey.other, argument: command)
            }
        case let e as TransportError: return userMessage(for: e)
        case let e as CatalogError: return userMessage(for: e)
        default: return UserMessage(key: UserMessage.ErrorKey.other)
        }
    }

    private nonisolated static func userMessage(for error: TransportError) -> UserMessage {
        switch error {
        case .bluetoothUnavailable, .deviceNotFound, .deviceNotConnected: return UserMessage(key: UserMessage.ErrorKey.bluetooth)
        case .gaiaServiceNotFound, .openFailed, .openTimedOut: return UserMessage(key: UserMessage.ErrorKey.connect)
        case .notOpen, .writeFailed: return UserMessage(key: UserMessage.ErrorKey.link)
        }
    }

    private nonisolated static func userMessage(for error: CatalogError) -> UserMessage {
        switch error {
        case .writeNotAllowed: return UserMessage(key: UserMessage.ErrorKey.readOnly)
        default: return UserMessage(key: UserMessage.ErrorKey.unsupported)
        }
    }
}
