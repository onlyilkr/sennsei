import Testing
import Foundation
@testable import HeadsetCore

@Test(arguments: [
    (Duration.seconds(1.5), UInt64(1_500_000_000)),
    (Duration.milliseconds(10), UInt64(10_000_000)),
    (Duration.seconds(10), UInt64(10_000_000_000)),
    (Duration.nanoseconds(1), UInt64(1)),
    (Duration.zero, UInt64(0)),
    (Duration.seconds(-3), UInt64(0)),
    (Duration.milliseconds(-1), UInt64(0)),
    (Duration.seconds(Int64.max), UInt64.max),
    (Duration.seconds(30_000_000_000), UInt64.max),
    (Duration.seconds(18_446_744_073), UInt64(18_446_744_073_000_000_000)),
])
func pauseConvertsDurationsToNanoseconds(duration: Duration, expected: UInt64) {
    #expect(Pause.nanoseconds(duration) == expected)
}

@Test func pauseWaitsRoughlyTheDuration() async throws {
    let clock = ContinuousClock()
    let start = clock.now
    try await Pause.sleep(.milliseconds(30))
    #expect(clock.now - start >= .milliseconds(25))
    #expect(clock.now - start < .seconds(5))
}

@Test func pauseReturnsImmediatelyForNonPositiveDurations() async throws {
    try await Pause.sleep(.zero)
    try await Pause.sleep(.seconds(-1))
}

@Test func pauseThrowsCancellationErrorWhenCancelled() async {
    let task = Task { try await Pause.sleep(.seconds(30)) }
    task.cancel()
    do {
        try await task.value
        Issue.record("Pause.sleep returned instead of throwing")
    } catch is CancellationError {
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

/// `Task.sleep(for:)` and `Clock.sleep` are generic: every module that calls them emits its own copy of the
/// specialization and the linker keeps one. See `Pause`. This keeps them out of our sources.
@Test func sourcesNeverCallTheGenericSleep() throws {
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")
    let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
    let banned = ["Task.sleep(for:", ".sleep(for:", "sleep(until:"]
    var offences: [String] = []
    var scanned = 0
    for case let file as URL in enumerator where file.pathExtension == "swift" {
        scanned += 1
        let isPause = file.lastPathComponent == "Pause.swift"
        let text = try String(contentsOf: file, encoding: .utf8)
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isPause && trimmed.hasPrefix("///") { continue } // the doc comment names the banned calls
            for call in banned where line.contains(call) {
                offences.append("\(file.lastPathComponent):\(index + 1): \(trimmed)")
            }
        }
    }
    #expect(scanned > 20, "found only \(scanned) source files under \(sources.path)")
    #expect(offences.isEmpty, """
        Task.sleep(for:), Clock.sleep(for:) and sleep(until:) are generic and must not be called from our \
        modules; use Pause.sleep (HeadsetCore/Pause.swift), which explains why. Found:
        \(offences.joined(separator: "\n"))
        """)
}
