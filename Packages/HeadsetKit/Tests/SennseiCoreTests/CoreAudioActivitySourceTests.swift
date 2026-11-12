import Testing
@testable import SennseiCore

@Suite struct CoreAudioActivitySourceTests {
    /// Real CoreAudio, read only. Asserts only device-state-independent well-formedness; it cannot verify real
    /// routing without headphones playing (that is checked manually on device).
    @Test func snapshotIsReadOnlyAndWellFormed() async {
        guard #available(macOS 14.2, *) else { return }
        let source = CoreAudioActivitySource(headphoneName: "ACCENTUM")
        let result: [ProcessActivity] = await source.snapshot()
        #expect(result.allSatisfy { !$0.bundleID.isEmpty })
        #expect(Set(result.map(\.bundleID)).count == result.count)
        #expect(result.allSatisfy { $0.route == .bluetooth || $0.route == .usb })
    }

    @Test func unavailableSourceIsEmptyAndUnsupported() async {
        let source = UnavailableAudioActivitySource()
        #expect(source.isSupported == false)
        #expect(await source.snapshot().isEmpty)
    }
}
