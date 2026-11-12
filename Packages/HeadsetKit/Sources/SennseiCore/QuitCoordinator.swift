import Foundation
import os

/// Runs the quit-time work once: stop the control socket, flush Insights (bounded), stop the headset model
/// (best effort), then reply to AppKit. The flush comes before the model stop because a hung RFCOMM close must
/// not cost the history; the flush needs only the recorder state, never the headset.
///
/// AppKit's `applicationShouldTerminate` answers `.terminateLater` and calls `begin`; a second quit request
/// while this runs is ignored.
///
/// RULE: never call `NSApp.terminate` from inside a MainActor task (or after an await in one). `.terminateLater`
/// makes AppKit spin a nested run loop inside the caller, and if the caller is a main-actor job the main-actor
/// executor is occupied by it, so this coordinator's tasks could never run (deadlock). Call `terminate`
/// synchronously from an event handler (button action, Cmd+Q, Dock).
///
/// The overall deadline is a run-loop `Timer` in the common modes: timers are serviced even inside AppKit's
/// nested terminate-later loop, so quitting cannot hang whatever the main-actor tasks do. When it fires the
/// reply is sent directly (exactly once).
@MainActor
public final class QuitCoordinator {
    /// Schedules `fire` after `delay`; returns a cancel closure.
    public typealias Scheduler = @MainActor (Duration, @escaping @MainActor @Sendable () -> Void) -> (@MainActor () -> Void)

    public static let runLoopTimer: Scheduler = { delay, fire in
        let timer = Timer(timeInterval: seconds(delay), repeats: false) { _ in MainActor.assumeIsolated { fire() } }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    static func seconds(_ d: Duration) -> TimeInterval {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    private static let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "quit")
    private enum Phase: String { case idle, stopControl, flush, modelStop }
    private var phase = Phase.idle

    private let insights: InsightsService?
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private let schedule: Scheduler
    private let stopControl: @MainActor () -> Void
    private let stopModel: @MainActor () async -> Void
    private var reply: (@MainActor () -> Void)?
    private var cancelTimer: (@MainActor () -> Void)?
    public private(set) var started = false
    public private(set) var replied = false
    public private(set) var flushFinished: Bool?

    public init(
        insights: InsightsService?, timeout: Duration = .seconds(3),
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in _ = try? await Task.sleep(for: duration) },
        schedule: @escaping Scheduler = QuitCoordinator.runLoopTimer,
        stopControl: @escaping @MainActor () -> Void,
        stopModel: @escaping @MainActor () async -> Void = {}
    ) {
        self.insights = insights
        self.timeout = timeout
        self.sleep = sleep
        self.schedule = schedule
        self.stopControl = stopControl
        self.stopModel = stopModel
    }

    /// Returns false when a quit is already in progress (the caller just answers `.terminateLater` again).
    @discardableResult
    public func begin(reply: @escaping @MainActor () -> Void) -> Bool {
        guard !started else { return false }
        started = true
        self.reply = reply
        cancelTimer = schedule(timeout) { [weak self] in self?.deadlineHit() }
        Task { @MainActor in
            // Control socket first: no remote command may arrive while the rest runs.
            phase = .stopControl
            stopControl()
            if let insights, !replied {
                phase = .flush
                let done = await insights.stop(timeout: timeout, sleep: sleep)
                if !replied { flushFinished = done }
            }
            if !replied {
                phase = .modelStop
                await stopModel()
            }
            finish()
        }
        return true
    }

    private func deadlineHit() {
        Self.log.error("quit deadline hit while in phase \(self.phase.rawValue, privacy: .public)")
        if insights != nil, flushFinished == nil { flushFinished = false }
        finish()
    }

    private func finish() {
        guard !replied else { return }
        replied = true
        cancelTimer?()
        cancelTimer = nil
        reply?()
        reply = nil
    }
}
