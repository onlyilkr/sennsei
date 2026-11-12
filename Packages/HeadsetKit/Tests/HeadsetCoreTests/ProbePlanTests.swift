import Testing
import Foundation
import GaiaProtocol
@testable import HeadsetCore

@Test func initialPlanReadsFirmwareThenModel() {
    #expect(ProbePlan.initial().map(\.command) == [0x1201, 0x1206])
}

@Test func oldFirmwareGetsNoEqCommands() {
    let ids = ProbePlan.afterFirmware(FirmwareVersion(3, 16, 3)).map(\.command)
    #expect(!ids.contains { $0 & 0xFF00 == 0x1000 })
}

@Test func newFirmwareReadsFiveBands() {
    let frames = ProbePlan.afterFirmware(FirmwareVersion(3, 34, 0))
    #expect(frames.filter { $0.command == 0x100B }.map { $0.payload.first } == [0, 1, 2, 3, 4])
    #expect(frames.filter { $0.command == 0x1002 }.count == 5)
}

@Test func pairedEntriesAreCappedAtEight() {
    #expect(ProbePlan.pairedEntries(count: 40).count == 16)
    #expect(ProbePlan.pairedEntries(count: 0).isEmpty)
}

private actor FakeTransport: HeadsetTransport {
    private(set) var sent: [Data] = []
    private(set) var closed = false
    private let replies: [Data: Data]
    private let failAfter: Int?
    private let garbage: Data?
    private let continuation: AsyncStream<Data>.Continuation
    nonisolated let incoming: AsyncStream<Data>
    init(replies: [Data: Data], failAfter: Int? = nil, garbage: Data? = nil) {
        self.replies = replies
        self.failAfter = failAfter
        self.garbage = garbage
        (incoming, continuation) = AsyncStream<Data>.makeStream()
    }
    func open() async throws {}
    func close() async { closed = true }
    func send(_ data: Data) async throws {
        if let failAfter, sent.count >= failAfter { throw TransportError.writeFailed(-1) }
        sent.append(data)
        if let garbage { continuation.yield(garbage) }
        if let r = replies[data] { continuation.yield(r) }
    }
}

private func hex(_ s: String) -> Data { Data(s.split(separator: " ").map { UInt8($0, radix: 16)! }) }

@Test func stopsAndClosesWhenFirstReadGetsNoReply() async {
    let t = FakeTransport(replies: [:])
    let runner = ProbeRunner(transport: t, replyTimeout: .milliseconds(50), gap: .zero)
    await #expect(throws: ProbeError.noReplyOnControlChannel) { _ = try await runner.run() }
    #expect(await t.sent == [hex("FF 03 00 00 04 95 12 01")])
    #expect(await t.closed)
}

@Test func recordsTimeoutAndContinuesAfterFirmwareIsKnown() async throws {
    let t = FakeTransport(replies: [
        hex("FF 03 00 00 04 95 12 01"): hex("FF 03 00 06 04 95 13 01 00 02 00 0C 00 00"),
        hex("FF 03 00 00 04 95 06 03"): hex("FF 03 00 01 04 95 07 03 50"),
    ])
    let result = try await ProbeRunner(transport: t, replyTimeout: .milliseconds(50), gap: .zero).run()
    #expect(result.firmware == FirmwareVersion(2, 12, 0))
    #expect(result.records.first { $0.note == "batteryLevel" }?.rx == ["ff0300010495070350"])
    #expect(result.records.contains { $0.note == "modelID timeout" })
    #expect(await t.closed)
}

@Test(arguments: [FirmwareVersion(2, 12, 0), FirmwareVersion(3, 12, 0), FirmwareVersion(3, 34, 0)])
func everyProbeFrameIsAReadTheCatalogAccepts(fw: FirmwareVersion) throws {
    let all = ProbePlan.initial() + ProbePlan.afterFirmware(fw) + ProbePlan.pairedEntries(count: 8)
    for f in all {
        try CommandCatalog.standard.validate(f, firmware: fw, mode: .readOnly)
        #expect(f.vendor == GaiaVendor.sennheiser)
    }
}

@Test func pairedDeviceRepliesAreRedactedInRecords() async throws {
    let t = FakeTransport(replies: [
        hex("FF 03 00 00 04 95 12 01"): hex("FF 03 00 06 04 95 13 01 00 02 00 0C 00 00"),
        hex("FF 03 00 00 04 95 14 00"): hex("FF 03 00 02 04 95 15 00 00 01"),
        hex("FF 03 00 01 04 95 14 01 00"): hex("FF 03 00 09 04 95 15 01 00 01 02 AA BB CC DD EE FF"),
        hex("FF 03 00 00 04 95 06 03"): hex("FF 03 00 01 04 95 07 03 50"),
    ])
    let result = try await ProbeRunner(transport: t, replyTimeout: .milliseconds(50), gap: .zero).run()
    let paired = try #require(result.records.first { $0.note == "pairedEntry" })
    #expect(paired.rx == ["ff03000904951501000102" + String(repeating: "**", count: 6)])
    #expect(paired.rx[0].count == 2 * 17)
    #expect(!paired.rx[0].contains("aabbccddeeff"))
    #expect(result.records.first { $0.note == "batteryLevel" }?.rx == ["ff0300010495070350"])
}

@Test func midRunTransportFailureKeepsCollectedRecords() async throws {
    let t = FakeTransport(replies: [
        hex("FF 03 00 00 04 95 12 01"): hex("FF 03 00 06 04 95 13 01 00 02 00 0C 00 00"),
        hex("FF 03 00 00 04 95 06 03"): hex("FF 03 00 01 04 95 07 03 50"),
    ], failAfter: 3)
    let result = try await ProbeRunner(transport: t, replyTimeout: .milliseconds(50), gap: .zero).run()
    #expect(result.firmware == FirmwareVersion(2, 12, 0))
    #expect(result.records.count == 4)
    let last = try #require(result.records.last)
    #expect(last.tx == "" && last.rx.isEmpty && last.ms == 0)
    #expect(last.note.hasPrefix("aborted: "))
    #expect(await t.sent.count == 3)
    #expect(await t.closed)
}

@Test func garbageBytesAreCountedButNotParsed() async {
    let t = FakeTransport(replies: [:], garbage: Data([0x01, 0x02, 0x03, 0x04]))
    let runner = ProbeRunner(transport: t, replyTimeout: .milliseconds(50), gap: .zero)
    await #expect(throws: ProbeError.noReplyOnControlChannel) { _ = try await runner.run() }
    #expect(await runner.receivedByteCount() == 4)
}

@Test func silentTransportCountsZeroBytes() async {
    let t = FakeTransport(replies: [:])
    let runner = ProbeRunner(transport: t, replyTimeout: .milliseconds(50), gap: .zero)
    await #expect(throws: ProbeError.noReplyOnControlChannel) { _ = try await runner.run() }
    #expect(await runner.receivedByteCount() == 0)
}
