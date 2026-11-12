import Foundation

/// The only way our modules suspend for a while.
///
/// Do not call `Task.sleep(for:)`, `Clock.sleep(for:)` or `sleep(until:)` from this package. They are generic
/// over the clock, so the compiler specializes them inside every module that calls them and emits the result
/// as a weak, coalesced symbol (for `ContinuousClock`:
/// `$ss5ClockPsE5sleep3for9tolerancey8DurationQz_AGSgtYaKFs010ContinuousA0V_Tg5` and its async function
/// pointer `...Tg5Tu`). The linker keeps one copy of the body and one copy of the pointer record, independently
/// of each other. A dependency compiled with different language features (KeyboardShortcuts 3.1.0 uses
/// swift-tools 6.2, `defaultIsolation(MainActor)` and `NonisolatedNonsendingByDefault`) emits an incompatible
/// copy: its async context is 112 bytes, ours is 128. The release build then ran our 128-byte body with a
/// record that said 112, callers allocated 16 bytes too little and the task allocator aborted
/// (`swift_task_dealloc`).
///
/// `Task.sleep(nanoseconds:)` is not generic. It is an ordinary entry point of the runtime and nothing of it is
/// emitted into client modules. `scripts/check-async-odr.py` (run by `make check`) fails the build when any
/// shared async specialization has diverging sizes; a test fails when a banned call appears in the sources.
public enum Pause {
    /// Suspends for `duration`. Throws `CancellationError` when the task is cancelled; returns at once for a
    /// zero or negative duration.
    public static func sleep(_ duration: Duration) async throws {
        try await Task.sleep(nanoseconds: nanoseconds(duration))
    }

    /// `duration` in whole nanoseconds, rounded down: negative durations become 0, durations beyond what a
    /// `UInt64` holds saturate at `UInt64.max`.
    static func nanoseconds(_ duration: Duration) -> UInt64 {
        guard duration > .zero else { return 0 }
        let (seconds, attoseconds) = duration.components // both non-negative here
        let (scaled, overflow) = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
        if overflow { return .max }
        let (total, overflow2) = scaled.addingReportingOverflow(UInt64(attoseconds / 1_000_000_000))
        return overflow2 ? .max : total
    }
}
