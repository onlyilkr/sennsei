import Testing
import Foundation
import GaiaProtocol
import HeadsetCore
import HeadsetSimulator

private func session(_ sim: SimulatedHeadset) -> HeadsetSession {
    HeadsetSession(transport: sim, replyTimeout: .milliseconds(80))
}

@Test func pauseStateIsUnknownUntilARefreshReadsIt() async throws {
    let sim = SimulatedHeadset(); let sess = session(sim)
    let connected = try await sess.connect()
    #expect(connected.pauseInTransparency == nil)          // connect does not read 1801
    let fresh = try await sess.refreshStatus()
    #expect(fresh.pauseInTransparency == true)             // the probed ACCENTUM pauses the music
    #expect(HeadsetState(profile: connected.profile).pauseInTransparency == nil)
}

@Test func writingPauseOffSendsExactlyTheWriteThenTheReadBack() async throws {
    let sim = SimulatedHeadset(); let sess = session(sim)
    _ = try await sess.connect(); _ = try await sess.refreshStatus()
    let before = await sim.sent.count
    try await sess.setPauseInTransparency(false)
    let frames = await sim.sent.dropFirst(before)
    #expect(frames.map(\.command) == [0x1800, 0x1801])
    #expect(frames.first?.payload == Data([0x00])); #expect(frames.last?.payload == Data())
    #expect(await sim.state.pauseInTransparency == false)
    #expect(await sess.state?.pauseInTransparency == false)
}

@Test func writingPauseOnSendsOne() async throws {
    var st = SimulatedState.accentumProbed; st.pauseInTransparency = false
    let sim = SimulatedHeadset(state: st); let sess = session(sim)
    _ = try await sess.connect()
    let before = await sim.sent.count
    try await sess.setPauseInTransparency(true)
    let frames = await sim.sent.dropFirst(before)
    #expect(frames.first?.command == 0x1800); #expect(frames.first?.payload == Data([0x01]))
    #expect(await sess.state?.pauseInTransparency == true)
}

@Test func sameValueIsStillWritten() async throws {
    let sim = SimulatedHeadset(); let sess = session(sim)     // device already pauses (true)
    _ = try await sess.connect(); _ = try await sess.refreshStatus()
    let before = await sim.sent.count
    try await sess.setPauseInTransparency(true)
    #expect(await sim.sent.dropFirst(before).map(\.command) == [0x1800, 0x1801])
}

@Test func ignoredPauseWriteIsAReadBackMismatchWithTheDeviceValue() async throws {
    let sim = SimulatedHeadset(); await sim.setIgnoreWrites([0x1800]); let sess = session(sim)
    _ = try await sess.connect(); _ = try await sess.refreshStatus()
    await #expect(throws: SessionError.readBackMismatch("pause in transparency")) {
        try await sess.setPauseInTransparency(false)
    }
    #expect(await sess.state?.pauseInTransparency == true)   // device value, not the request
}

@Test func failureAfterTheWriteMakesThePauseStateUnknown() async throws {
    let sim = SimulatedHeadset(); let sess = session(sim)
    _ = try await sess.connect(); _ = try await sess.refreshStatus()
    await sim.setSilent([0x1801])                            // write goes out, read-back never answers
    await #expect(throws: SessionError.timeout("pauseInTransparency")) {
        try await sess.setPauseInTransparency(false)
    }
    #expect(await sim.sent.map(\.command).contains(0x1800))
    #expect(await sess.state?.pauseInTransparency == nil)
    #expect(await sess.state?.battery == 20)                 // other fields untouched
}

@Test func pauseOnAReadOnlyModelIsRefusedAndNothingIsSent() async throws {
    var st = SimulatedState.accentumProbed; st.modelID = "M4AEBT Denim"
    let sim = SimulatedHeadset(state: st); let sess = session(sim)
    _ = try await sess.connect(); let sent = await sim.sent.count
    await #expect(throws: SessionError.unsupported("read-only model")) { try await sess.setPauseInTransparency(false) }
    #expect(await sim.sent.count == sent)
}

@Test func pauseWithoutConnectionIsNotConnectedAndSendsNothing() async {
    let sim = SimulatedHeadset(); let sess = session(sim)
    await #expect(throws: SessionError.notConnected) { try await sess.setPauseInTransparency(false) }
    #expect(await sim.sent.isEmpty)
}
