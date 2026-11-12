import Testing
@testable import SennseiCore

@MainActor @Suite struct PollingWaitTests {
    @Test func alreadyTrueDoesNotSleep() async {
        var sleeps = 0
        let ok = await waitUntil(timeout: .seconds(8), sleep: { _ in sleeps += 1 }, condition: { true })
        #expect(ok); #expect(sleeps == 0)
    }

    @Test func becomesTrueInTimeReturnsRightAfter() async {
        var sleeps = 0
        let ok = await waitUntil(timeout: .seconds(8), sleep: { _ in sleeps += 1 }, condition: { sleeps >= 3 })
        #expect(ok); #expect(sleeps == 3)
    }

    @Test func neverTrueReturnsFalseAfterTheTimeout() async {
        var slept = Duration.zero
        let ok = await waitUntil(timeout: .seconds(8), interval: .milliseconds(100), sleep: { slept += $0 }, condition: { false })
        #expect(!ok); #expect(slept == .seconds(8))
    }

    @Test func cancelledTaskReturnsFalseWithoutLooping() async {
        let task = Task { @MainActor () -> (Bool, Int) in
            var sleeps = 0
            // Cancel before the first poll; the injectable sleep does not itself observe cancellation.
            withUnsafeCurrentTask { $0?.cancel() }
            let ok = await waitUntil(timeout: .seconds(8), sleep: { _ in sleeps += 1 }, condition: { false })
            return (ok, sleeps)
        }
        let (ok, sleeps) = await task.value
        #expect(!ok); #expect(sleeps == 0)
    }
}
