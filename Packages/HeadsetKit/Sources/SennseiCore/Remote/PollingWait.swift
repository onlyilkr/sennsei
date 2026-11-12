import Foundation

/// Polls `condition` until it is true or `timeout` passes, suspending (never blocking) between checks.
/// Returns whether the condition held. `sleep` is injectable so tests need no real time.
@MainActor
public func waitUntil(
    timeout: Duration, interval: Duration = .milliseconds(100),
    sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) },
    condition: () -> Bool
) async -> Bool {
    var remaining = timeout
    while !condition() {
        if Task.isCancelled { return false }
        if remaining <= .zero { return false }
        await sleep(interval)
        remaining -= interval
    }
    return true
}
