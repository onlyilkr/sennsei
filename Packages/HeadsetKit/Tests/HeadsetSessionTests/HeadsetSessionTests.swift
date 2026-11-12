import Testing
import Foundation
import GaiaProtocol
import HeadsetCore
import HeadsetSimulator

private func session(_ sim: SimulatedHeadset, unverified: Bool = true) -> HeadsetSession {
    HeadsetSession(transport: sim, replyTimeout: .milliseconds(80), allowUnverifiedWrites: unverified)
}

@Test func connectReadsStateAndWritesNothing() async throws {
    let sim = SimulatedHeadset()
    let s = try await session(sim).connect()
    #expect(s.profile.model == .accentum); #expect(s.profile.eq == .gen1)
    #expect(s.battery == 20); #expect(s.ancEnabled == true); #expect(s.transparencyEnabled == false); #expect(s.audioMode == 1)
    let sent = await sim.sent.map(\.command)
    #expect(sent == [0x1201, 0x1206, 0x0603, 0x1A05, 0x1805, 0x0804])
}

@Test func readEQReturnsTheFlatSnapshot() async throws {
    let sim = SimulatedHeadset(); let sess = session(sim); _ = try await sess.connect()
    let snap = try await sess.readEQ()
    #expect(snap.isUnconfigured == false); #expect(snap.bassBoost == false)
    #expect(snap.gains == [0, 0, 0, 0, 0]); #expect(snap.firmware == "3.12.14")
}

@Test func writeEQSendsThreeWritesThenVerifies() async throws {
    let sim = SimulatedHeadset(); let sess = session(sim); _ = try await sess.connect()
    let snap = try await sess.writeEQ(gains: [2, -3, -3, 1, 1], bassBoost: false)
    let sent = await sim.sent.map(\.command).dropFirst(6)
    #expect(Array(sent) == [0x1002, 0x1006, 0x1004, 0x1007, 0x1005, 0x1003, 0x1003])
    let gains = try #require(snap.gains)
    for (a, b) in zip(gains, [2.0, -3, -3, 1, 1]) { #expect(abs(a - b) < 0.11) }
    #expect(await sess.state?.eq == snap)
}

@Test func writeEQSwitchesToUserEqModeWhenNeeded() async throws {
    var st = SimulatedState.accentumProbed; st.audioMode = 3
    let sim = SimulatedHeadset(state: st); let sess = session(sim); _ = try await sess.connect()
    _ = try await sess.writeEQ(gains: [0, 0, 0, 0, 0], bassBoost: false)
    #expect(await sim.sent.map(\.command).contains(0x0803))
    #expect(await sim.state.audioMode == 1)
}

@Test func unverifiedWritesAreRefusedByDefault() async throws {
    // Gen1 EQ writes are verified now; the user-EQ mode switch (0803) is still unverified. Mode 0 makes
    // writeEQ need it, and the gate refuses the whole operation before anything is sent.
    var st = SimulatedState.accentumProbed; st.audioMode = 0
    let sim = SimulatedHeadset(state: st); let sess = session(sim, unverified: false); _ = try await sess.connect()
    await #expect(throws: SessionError.rejected(.unverifiedWrite("setAudioMode"))) { _ = try await sess.writeEQ(gains: [0, 0, 0, 0, 0], bassBoost: false) }
    #expect(await sim.sent.count == 6)
    try await sess.setANC(false)                      // verified command: no flag required
    #expect(await sim.state.ancEnabled == false)
}

@Test func readBackMismatchIsReportedAndStateFollowsTheDevice() async throws {
    let sim = SimulatedHeadset(); await sim.setIgnoreWrites([0x1002, 0x1006, 0x1004])
    let sess = session(sim); _ = try await sess.connect()
    await #expect(throws: SessionError.readBackMismatch("equalizer")) { _ = try await sess.writeEQ(gains: [3, 0, 0, 0, 0], bassBoost: false) }
    #expect(await sess.state?.eq?.gains == [0, 0, 0, 0, 0])
}

@Test func aTimeoutMidSequenceStopsTheRemainingWrites() async throws {
    let sim = SimulatedHeadset(); await sim.setSilent([0x1006])
    let sess = session(sim); _ = try await sess.connect()
    await #expect(throws: SessionError.timeout("eq1SetLevelShift")) { _ = try await sess.writeEQ(gains: [1, 0, 0, 0, 0], bassBoost: false) }
    #expect(await sim.sent.map(\.command).contains(0x1004) == false)
}

@Test func threeTimeoutsKillTheLink() async throws {
    let sim = SimulatedHeadset(); await sim.setSilent([0x1A04])
    let sess = session(sim); _ = try await sess.connect()
    for _ in 0..<2 { await #expect(throws: SessionError.timeout("setAncEnabled")) { try await sess.setANC(false) } }
    await #expect(throws: SessionError.linkDead) { try await sess.setANC(false) }
    await #expect(throws: SessionError.notConnected) { try await sess.setANC(false) }
}

@Test func gen2FirmwareHasNoGen1EQ() async throws {
    var st = SimulatedState.accentumProbed; st.firmware = FirmwareVersion(3, 34, 0)
    let sess = session(SimulatedHeadset(state: st)); _ = try await sess.connect()
    await #expect(throws: SessionError.unsupported("equalizer")) { _ = try await sess.readEQ() }
}

@Test func unknownModelIsReadOnly() async throws {
    var st = SimulatedState.accentumProbed; st.modelID = "ZZZ"
    let sim = SimulatedHeadset(state: st); let sess = session(sim); _ = try await sess.connect()
    await #expect(throws: SessionError.unsupported("read-only model")) { try await sess.setANC(false) }
    #expect(await sim.sent.count == 6)
}

@Test func transportFailuresSurface() async throws {
    var st = SimulatedState.accentumProbed; st.firmware = FirmwareVersion(3, 16, 3)
    let sim = SimulatedHeadset(state: st); let sess = session(sim); _ = try await sess.connect()
    _ = try await sess.readEQ()                       // 3.16.3 is still gen1
    await sim.failSends(after: 0)
    await #expect(throws: SessionError.transport(.notOpen)) { try await sess.setANC(false) }
}

/// Transport whose replies the test controls by hand.
private actor ManualTransport: HeadsetTransport {
    nonisolated let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var deframer = GaiaDeframer()
    private(set) var sent: [GaiaFrame] = []
    private(set) var closed = false
    var held: Set<UInt16> = []
    var errors: [UInt16: UInt8] = [:]
    var onSend: [UInt16: [GaiaFrame]] = [:]

    init() { (incoming, continuation) = AsyncStream.makeStream(of: Data.self) }
    func open() async throws {}
    func close() async { closed = true; continuation.finish() }
    func hold(_ c: Set<UInt16>) { held = c }
    func failWith(_ c: UInt16, code: UInt8) { errors[c] = code }
    func count(_ c: UInt16) -> Int { sent.filter { $0.command == c }.count }
    func deliver(_ f: GaiaFrame) { if let b = try? f.encoded() { continuation.yield(b) } }

    func send(_ data: Data) async throws {
        for f in deframer.append(data) {
            sent.append(f)
            guard !held.contains(f.command) else { continue }
            if let code = errors[f.command] {
                deliver(GaiaFrame(vendor: f.vendor, command: f.command | 0x0180, payload: Data([code])))
                continue
            }
            let payload: [UInt8]
            switch f.command {
            case 0x1201: payload = [0, 3, 0, 12, 0, 14]
            case 0x1206: payload = Array("ACAEBT SE".utf8) + [0]
            default: payload = [1]
            }
            deliver(GaiaFrame(vendor: f.vendor, command: f.command | 0x0100, payload: Data(payload)))
        }
    }
}

@Test func silentFirmwareQueryClosesTheChannel() async throws {
    let t = ManualTransport(); await t.hold([0x1201])
    let sess = HeadsetSession(transport: t, replyTimeout: .milliseconds(60))
    await #expect(throws: SessionError.timeout("firmwareVersion")) { _ = try await sess.connect() }
    #expect(await t.closed)
    #expect(await sess.state == nil)
}

@Test func aStaleReplyDuringTheGraceWindowIsDiscarded() async throws {
    let t = ManualTransport()
    let sess = HeadsetSession(transport: t, replyTimeout: .milliseconds(80))
    _ = try await sess.connect()
    await t.hold([0x1A04])
    let first = Task { () -> SessionError? in
        do throws(SessionError) { try await sess.setANC(true); return nil } catch { return error }
    }
    try await Task.sleep(for: .milliseconds(30))
    let retry = Task { () -> SessionError? in      // queues on the operation lock before the timeout
        do throws(SessionError) { try await sess.setANC(true); return nil } catch { return error }
    }
    try await Task.sleep(for: .milliseconds(70))   // ~100 ms: first timed out at 80, grace window is running
    await t.hold([])
    await t.deliver(GaiaFrame(vendor: GaiaVendor.sennheiser, command: 0x1A04 | 0x0180, payload: Data([9])))
    #expect(await first.value == .timeout("setAncEnabled"))
    #expect(await retry.value == nil)              // its own reply, not the stale error
    #expect(await t.count(0x1A04) == 2)
}

@Test func aLostReplyDoesNotPoisonTheRetry() async throws {
    let t = ManualTransport()
    let sess = HeadsetSession(transport: t, replyTimeout: .milliseconds(40))
    _ = try await sess.connect()
    for _ in 0..<5 {
        await t.hold([0x1A04])
        await #expect(throws: SessionError.timeout("setAncEnabled")) { try await sess.setANC(true) }
        await t.hold([])
        try await sess.setANC(true)                        // the reply was lost, not late: must succeed
    }
    #expect(await sess.state != nil)
}

@Test func readEQWorksAfterATimedOutQuery() async throws {
    let sim = SimulatedHeadset(); let sess = session(sim); _ = try await sess.connect()
    await sim.setSilent([0x1003])
    await #expect(throws: SessionError.timeout("eq1Params")) { _ = try await sess.readEQ() }
    await sim.setSilent([])
    let snap = try await sess.readEQ()
    #expect(snap.gains == [0, 0, 0, 0, 0])
}

@Test func deviceErrorRepliesSurfaceWithNameAndCode() async throws {
    let t = ManualTransport()
    let sess = HeadsetSession(transport: t, replyTimeout: .milliseconds(80))
    _ = try await sess.connect()
    await t.failWith(0x1A04, code: 7)
    await #expect(throws: SessionError.device(command: "setAncEnabled", code: 7)) { try await sess.setANC(false) }
    #expect(await sess.state?.ancEnabled == nil)           // a write may have been applied: unknown
}

@Test func abortAtTheFirstEQWriteSendsNothingMore() async throws {
    let sim = SimulatedHeadset()
    let sess = session(sim); _ = try await sess.connect()
    _ = try await sess.readEQ()
    #expect(await sess.state?.eq != nil)
    await sim.setSilent([0x1002])
    await #expect(throws: SessionError.timeout("eq1SetParams")) { _ = try await sess.writeEQ(gains: [1, 0, 0, 0, 0], bassBoost: false) }
    let sent = await sim.sent.map(\.command)
    #expect(!sent.contains(0x1006)); #expect(!sent.contains(0x1004))
    #expect(await sess.state?.eq == nil)
}

@Test func abortAtTheThirdEQWriteLeavesEQUnknown() async throws {
    let sim = SimulatedHeadset(); await sim.setSilent([0x1004])
    let sess = session(sim); _ = try await sess.connect()
    _ = try await sess.readEQ()
    #expect(await sess.state?.eq != nil)
    await #expect(throws: SessionError.timeout("eq1SetKnob")) { _ = try await sess.writeEQ(gains: [1, 0, 0, 0, 0], bassBoost: false) }
    let sent = await sim.sent.map(\.command)
    #expect(sent.contains(0x1002)); #expect(sent.contains(0x1006))
    #expect(await sess.state?.eq == nil)
}

@Test func anUnconfirmedUserEqModeSwitchIsAMismatch() async throws {
    // "audio mode" is the mismatch name for a 0803 that 0804 does not confirm.
    var st = SimulatedState.accentumProbed; st.audioMode = 3
    let sim = SimulatedHeadset(state: st); await sim.setIgnoreWrites([0x0803])
    let sess = session(sim); _ = try await sess.connect()
    await #expect(throws: SessionError.readBackMismatch("audio mode")) { _ = try await sess.writeEQ(gains: [0, 0, 0, 0, 0], bassBoost: false) }
    #expect(await sess.state?.audioMode == 3)              // follows the device
    #expect(await sess.state?.eq != nil)
}

@Test func writeEQOnAReadOnlyProfileSendsNothing() async throws {
    var st = SimulatedState.accentumProbed; st.modelID = "ACPAEBT SE"
    let sim = SimulatedHeadset(state: st); let sess = session(sim); _ = try await sess.connect()
    await #expect(throws: SessionError.unsupported("read-only model")) { _ = try await sess.writeEQ(gains: [0, 0, 0, 0, 0], bassBoost: false) }
    #expect(await sim.sent.count == 6)
}

@Test func concurrentOperationsDoNotInterleave() async throws {
    let sim = SimulatedHeadset(); let sess = session(sim); _ = try await sess.connect()
    let write = Task { _ = try await sess.writeEQ(gains: [1, 0, 0, 0, 0], bassBoost: false) }
    try await Task.sleep(for: .milliseconds(1))
    let anc = Task { try await sess.setANC(false) }
    try await write.value; try await anc.value
    let sent = Array(await sim.sent.map(\.command).dropFirst(6))
    let eq: [UInt16] = [0x1002, 0x1006, 0x1004, 0x1007, 0x1005, 0x1003, 0x1003]
    let a: [UInt16] = [0x1A04, 0x1A05]
    #expect(sent == eq + a || sent == a + eq)
}

@Test func aSuccessResetsTheTimeoutCounter() async throws {
    let t = ManualTransport()
    let sess = HeadsetSession(transport: t, replyTimeout: .milliseconds(40))
    _ = try await sess.connect()
    await t.hold([0x1A04])
    await #expect(throws: SessionError.timeout("setAncEnabled")) { try await sess.setANC(true) }
    await t.hold([])
    try await sess.setANC(true)
    await t.hold([0x1A04])
    await #expect(throws: SessionError.timeout("setAncEnabled")) { try await sess.setANC(true) }
    await #expect(throws: SessionError.timeout("setAncEnabled")) { try await sess.setANC(true) }
    #expect(await sess.state != nil)                       // 2 in a row since the success: link alive
}
